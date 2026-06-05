# Reator-04-从epoll到EchoServer回调链

## 1. 这一篇解决什么问题

前面三篇分别讲了：

- `EventLoop` 怎么循环。
- `Channel` 怎么封装事件和回调。
- `Poller / EPollPoller` 怎么接入 epoll。

这一篇把它们串起来，看一条消息如何从 `epoll_wait` 走到 `EchoServer::onMessage()`。

## 2. 用户回调从哪里注册

位置：`src/main.cc:19`

```cpp
server_.setConnectionCallback(
    std::bind(&EchoServer::onConnection, this, std::placeholders::_1));

server_.setMessageCallback(
    std::bind(&EchoServer::onMessage, this,
              std::placeholders::_1,
              std::placeholders::_2,
              std::placeholders::_3));
```

这里注册的是用户层回调：

- `onConnection`：连接建立或断开时调用。
- `onMessage`：连接上有数据可读时调用。

EchoServer 的消息处理非常简单：

位置：`src/main.cc:49`

```cpp
void onMessage(const TcpConnectionPtr &conn, Buffer *buf, Timestamp time)
{
    std::string msg = buf->retrieveAllAsString();
    conn->send(msg);
}
```

它做的事：

```text
从 Buffer 取出全部数据
调用 conn->send(msg) 原样发回去
```

这就是 EchoServer。

## 3. TcpConnection 如何把读事件接到用户回调

位置：`src/TcpConnection.cc:43`

```cpp
channel_->setReadCallback(
    std::bind(&TcpConnection::handleRead, this, std::placeholders::_1));
```

这一步不是直接绑定到 `EchoServer::onMessage()`，而是先绑定到：

```text
TcpConnection::handleRead
```

原因是网络库需要先完成底层读操作：

```cpp
ssize_t n = inputBuffer_.readFd(channel_->fd(), &savedErrno);
```

位置：`src/TcpConnection.cc:186`

读完之后，如果 `n > 0`：

```cpp
messageCallback_(shared_from_this(), &inputBuffer_, receiveTime);
```

位置：`src/TcpConnection.cc:190`

这个 `messageCallback_` 才是用户层注册进来的 `EchoServer::onMessage()`。

所以真实链路是：

```text
Channel::readCallback_
  -> TcpConnection::handleRead()
  -> inputBuffer_.readFd()
  -> messageCallback_
  -> EchoServer::onMessage()
```

## 4. 读事件发生时的完整源码链路

### 第一步：程序进入主循环

位置：`src/main.cc:91`

```cpp
EventLoop loop;
InetAddress addr(8080);
EchoServer server(&loop, addr, "EchoServer");
server.start();
loop.loop();
```

`loop.loop()` 之后，程序进入 Reactor 主循环。

### 第二步：EventLoop 等待事件

位置：`src/EventLoop.cc:87`

```cpp
pollRetureTime_ = poller_->poll(kPollTimeMs, &activeChannels_);
```

这会进入 `EPollPoller::poll()`。

### 第三步：EPollPoller 调用 epoll_wait

位置：`src/EPollPoller.cc:34`

```cpp
int numEvents = ::epoll_wait(epollfd_, &*events_.begin(),
                             static_cast<int>(events_.size()), timeoutMs);
```

如果客户端连接 fd 上有数据，`epoll_wait` 返回 `numEvents > 0`。

### 第四步：把 epoll_event 变成 Channel*

位置：`src/EPollPoller.cc:113`

```cpp
Channel *channel = static_cast<Channel *>(events_[i].data.ptr);
channel->set_revents(events_[i].events);
activeChannels->push_back(channel);
```

这里完成：

```text
Linux epoll_event
  -> 项目里的 Channel*
```

### 第五步：EventLoop 分发 Channel

位置：`src/EventLoop.cc:88`

```cpp
for (Channel *channel : activeChannels_)
{
    channel->handleEvent(pollRetureTime_);
}
```

`EventLoop` 不判断读写，它只让 `Channel` 自己处理。

### 第六步：Channel 判断 revents_

位置：`src/Channel.cc:91`

```cpp
if (revents_ & (EPOLLIN | EPOLLPRI))
{
    if (readCallback_)
    {
        readCallback_(receiveTime);
    }
}
```

如果是读事件，就调用 `readCallback_`。

对 `TcpConnection` 来说，这个回调是：

```text
TcpConnection::handleRead
```

### 第七步：TcpConnection 读取数据

位置：`src/TcpConnection.cc:183`

```cpp
void TcpConnection::handleRead(Timestamp receiveTime)
{
    int savedErrno = 0;
    ssize_t n = inputBuffer_.readFd(channel_->fd(), &savedErrno);
    if (n > 0)
    {
        messageCallback_(shared_from_this(), &inputBuffer_, receiveTime);
    }
    else if (n == 0)
    {
        handleClose();
    }
    else
    {
        handleError();
    }
}
```

它负责：

- 从 fd 读取数据到 `inputBuffer_`。
- 读到数据后调用用户消息回调。
- 读到 0 表示对端关闭。
- 读失败则处理错误。

### 第八步：进入 EchoServer::onMessage

位置：`src/main.cc:49`

```cpp
void onMessage(const TcpConnectionPtr &conn, Buffer *buf, Timestamp time)
{
    std::string msg = buf->retrieveAllAsString();
    conn->send(msg);
}
```

到这里，底层 Reactor 事件已经变成了业务层消息处理。

## 5. 一句话串联

```text
epoll_wait 返回可读 fd，EPollPoller 根据 data.ptr 找回 Channel，EventLoop 调用 Channel::handleEvent，Channel 根据 revents_ 触发 readCallback_，进入 TcpConnection::handleRead 读取数据，最后调用 EchoServer 注册的 onMessage 完成回显。
```

## 6. 为什么要分这么多层

如果没有这些层，代码可能会变成：

```text
epoll_wait 返回 fd
if fd 是监听 fd
  accept
else if fd 是连接 fd
  read
else if fd 是 timerfd
  timer
else if fd 是 eventfd
  wakeup
```

这样 `EventLoop` 会越来越臃肿。

当前设计把职责拆开：

- `EventLoop`：循环和调度。
- `Poller`：等待事件。
- `Channel`：事件到回调的映射。
- `TcpConnection`：连接读写和生命周期。
- `EchoServer`：业务逻辑。

所以后续扩展 HTTP 或 WebSocket 时，理想位置是在业务层或连接消息处理层，而不是直接改 `EventLoop`。

## 7. 掌握标准

学完这一篇，你需要能做到：

1. 能从 `main.cc` 说出 `onMessage` 是什么时候注册的。
2. 能从 `TcpConnection` 构造函数说出 `Channel::readCallback_` 绑定的是谁。
3. 能从 `EPollPoller::poll()` 说出 epoll 返回后如何变成 `Channel*`。
4. 能从 `Channel::handleEventWithGuard()` 说出读事件如何分发。
5. 能从 `TcpConnection::handleRead()` 说出数据如何进入用户回调。
6. 能完整画出从 `epoll_wait` 到 `EchoServer::onMessage` 的调用链。

面试表达模板：

```text
用户在 EchoServer 中注册 onMessage 到 TcpServer，TcpServer 后续把该回调传给 TcpConnection。TcpConnection 创建时会把自己的 handleRead 绑定到 Channel 的 readCallback_。当 epoll_wait 返回连接 fd 可读时，EPollPoller 根据 event.data.ptr 找回 Channel 并设置 revents_，EventLoop 调用 Channel::handleEvent，Channel 发现是 EPOLLIN 后调用 readCallback_，进入 TcpConnection::handleRead，读取数据到 Buffer 后再调用用户注册的 onMessage。
```

## 8. GDB 验证路线

先编译 Debug 版本：

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j$(nproc)
```

启动 GDB：

```bash
gdb ./bin/main
```

建议断点：

```gdb
break main
break EventLoop::loop
break EPollPoller::poll
break EPollPoller::fillActiveChannels
break Channel::handleEventWithGuard
break TcpConnection::handleRead
break EchoServer::onMessage
run
```

另开一个终端：

```bash
nc 127.0.0.1 8080
```

输入：

```text
hello
```

观察问题：

- 第一次连接时，进入的是监听 fd 的事件，还是连接 fd 的事件？
- 发送 `hello` 后，是否进入 `TcpConnection::handleRead`？
- `inputBuffer_` 里是否读到了数据？
- `EchoServer::onMessage` 中的 `msg` 是否是 `hello`？

