# Reator-02-Channel事件封装与回调分发

## 1. Channel 解决什么问题

`Channel` 的职责是：

```text
把一个 fd、它关心的事件、它实际发生的事件、事件发生后的回调函数封装在一起。
```

它不拥有 fd 的生命周期，也不负责真正调用 `epoll_wait`。它更像是：

```text
fd 在 C++ 层的事件代理对象
```

核心文件：

- `include/Channel.h`
- `src/Channel.cc`

## 2. 核心成员变量

位置：`include/Channel.h:67`

```cpp
EventLoop *loop_;
const int fd_;
int events_;
int revents_;
int index_;

std::weak_ptr<void> tie_;
bool tied_;

ReadEventCallback readCallback_;
EventCallback writeCallback_;
EventCallback closeCallback_;
EventCallback errorCallback_;
```

逐个理解：

- `loop_`：这个 Channel 属于哪个 EventLoop。
- `fd_`：被监听的 fd。
- `events_`：当前想监听的事件。
- `revents_`：Poller 返回的实际发生事件。
- `index_`：Channel 在 Poller 中的状态，配合 `kNew / kAdded / kDeleted` 使用。
- `tie_`：弱引用，用来避免 TcpConnection 已销毁但 Channel 还触发回调。
- `readCallback_`：读事件回调。
- `writeCallback_`：写事件回调。
- `closeCallback_`：关闭事件回调。
- `errorCallback_`：错误事件回调。

最重要的区分：

```text
events_：我要监听什么
revents_：这次实际发生了什么
```

例如：

```text
events_ = EPOLLIN
revents_ = EPOLLIN
```

表示“我监听读事件，并且这次确实发生了读事件”。

## 3. Channel 如何注册事件

位置：`include/Channel.h:41`

```cpp
void enableReading() { events_ |= kReadEvent; update(); }
void disableReading() { events_ &= ~kReadEvent; update(); }
void enableWriting() { events_ |= kWriteEvent; update(); }
void disableWriting() { events_ &= ~kWriteEvent; update(); }
void disableAll() { events_ = kNoneEvent; update(); }
```

这些函数本身不直接调用 `epoll_ctl`，而是调用 `update()`。

位置：`src/Channel.cc:42`

```cpp
void Channel::update()
{
    loop_->updateChannel(this);
}
```

之后链路是：

```text
Channel::enableReading()
  -> Channel::update()
  -> EventLoop::updateChannel()
  -> Poller::updateChannel()
  -> EPollPoller::updateChannel()
  -> epoll_ctl()
```

这条链说明：

```text
Channel 只改自己的事件状态。
真正把事件状态同步到 epoll 的动作由 Poller/EPollPoller 完成。
```

## 4. Channel 如何保存回调

位置：`include/Channel.h:28`

```cpp
void setReadCallback(ReadEventCallback cb) { readCallback_ = std::move(cb); }
void setWriteCallback(EventCallback cb) { writeCallback_ = std::move(cb); }
void setCloseCallback(EventCallback cb) { closeCallback_ = std::move(cb); }
void setErrorCallback(EventCallback cb) { errorCallback_ = std::move(cb); }
```

以 `TcpConnection` 为例，它在构造函数中把自己的成员函数绑定给 `Channel`：

位置：`src/TcpConnection.cc:43`

```cpp
channel_->setReadCallback(
    std::bind(&TcpConnection::handleRead, this, std::placeholders::_1));
channel_->setWriteCallback(
    std::bind(&TcpConnection::handleWrite, this));
channel_->setCloseCallback(
    std::bind(&TcpConnection::handleClose, this));
channel_->setErrorCallback(
    std::bind(&TcpConnection::handleError, this));
```

所以当连接 fd 有读事件时：

```text
Channel::readCallback_
  -> TcpConnection::handleRead()
```

再往上：

```text
TcpConnection::handleRead()
  -> messageCallback_
  -> EchoServer::onMessage()
```

## 5. handleEvent 分发逻辑

位置：`src/Channel.cc:54`

```cpp
void Channel::handleEvent(Timestamp receiveTime)
{
    if (tied_)
    {
        std::shared_ptr<void> guard = tie_.lock();
        if (guard)
        {
            handleEventWithGuard(receiveTime);
        }
    }
    else
    {
        handleEventWithGuard(receiveTime);
    }
}
```

如果这个 Channel 被 `tie()` 绑定过，那么它会先尝试从 `weak_ptr` 提升为 `shared_ptr`。提升成功，说明绑定对象仍然活着，才继续执行回调。

位置：`src/Channel.cc:71`

```cpp
void Channel::handleEventWithGuard(Timestamp receiveTime)
{
    if ((revents_ & EPOLLHUP) && !(revents_ & EPOLLIN))
    {
        if (closeCallback_)
        {
            closeCallback_();
        }
    }

    if (revents_ & EPOLLERR)
    {
        if (errorCallback_)
        {
            errorCallback_();
        }
    }

    if (revents_ & (EPOLLIN | EPOLLPRI))
    {
        if (readCallback_)
        {
            readCallback_(receiveTime);
        }
    }

    if (revents_ & EPOLLOUT)
    {
        if (writeCallback_)
        {
            writeCallback_();
        }
    }
}
```

分发规则：

- `EPOLLHUP` 且没有 `EPOLLIN`：认为连接关闭，调用关闭回调。
- `EPOLLERR`：调用错误回调。
- `EPOLLIN | EPOLLPRI`：调用读回调。
- `EPOLLOUT`：调用写回调。

## 6. tie 的生命周期保护

位置：`src/TcpConnection.cc:164`

```cpp
channel_->tie(shared_from_this());
```

`TcpConnection` 继承了：

```cpp
std::enable_shared_from_this<TcpConnection>
```

因此可以生成指向自己的 `shared_ptr`。

为什么需要 `tie()`？

因为 `Channel` 里保存的回调是这样的：

```cpp
std::bind(&TcpConnection::handleRead, this, ...)
```

这里捕获的是裸 `this` 指针。如果 `TcpConnection` 已经销毁，但 `Channel` 还触发了事件，就可能访问悬空指针。

`tie()` 的作用是：

```text
事件触发时，先确认 TcpConnection 还活着。
活着才执行回调。
已经销毁就不再处理。
```

这属于 C++ 网络库里非常重要的生命周期问题。

## 7. Channel 在一次读事件中的完整链路

```text
客户端发送数据
  -> 内核发现连接 fd 可读
  -> epoll_wait 返回
  -> EPollPoller::fillActiveChannels 设置 channel->revents_
  -> EventLoop::loop 调用 channel->handleEvent()
  -> Channel 判断 revents_ 包含 EPOLLIN
  -> 调用 readCallback_(receiveTime)
  -> TcpConnection::handleRead(receiveTime)
  -> inputBuffer_.readFd(...)
  -> messageCallback_(conn, &inputBuffer_, receiveTime)
  -> EchoServer::onMessage(...)
```

## 8. 掌握标准

学完 `Channel`，你需要能做到：

1. 能解释 `Channel` 为什么是 fd 的事件封装。
2. 能准确区分 `events_` 和 `revents_`。
3. 能说清楚 `enableReading()` 为什么最终会走到 `epoll_ctl`。
4. 能说清楚 `handleEventWithGuard()` 如何根据 `revents_` 调用不同回调。
5. 能解释 `tie()` 是为了解决什么生命周期问题。
6. 能从 `TcpConnection` 构造函数说出 `readCallback_` 最终绑定到哪里。

面试表达模板：

```text
Channel 封装了一个 fd 及其事件状态，events_ 表示想监听的事件，revents_ 表示 epoll 返回的实际事件。业务对象把读写关闭错误回调注册到 Channel 中，EventLoop 拿到活跃 Channel 后调用 handleEvent，Channel 再根据 revents_ 分发到具体回调。对于 TcpConnection，Channel 使用 tie 绑定 shared_ptr，避免连接对象销毁后继续执行回调导致悬空指针。
```

## 9. 小练习

用 GDB 验证：

```gdb
break Channel::enableReading
break Channel::update
break Channel::handleEventWithGuard
break TcpConnection::handleRead
run
```

发送消息后观察：

- `fd_` 是多少？
- `events_` 是多少？
- `revents_` 是多少？
- `readCallback_` 调用后进入了哪个函数？

