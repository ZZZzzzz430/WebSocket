# Reator-00-主干总览与学习标准

> 文件名前缀按当前约定使用 `Reator`。本笔记实际内容对应 Reactor 主干。

## 1. 这一阶段要解决什么问题

Reactor 主干要回答一个核心问题：

```text
一个客户端 fd 上发生了读/写/关闭事件之后，项目代码是如何从 epoll_wait 一步步调用到业务回调的？
```

当前项目的主干类是：

- `EventLoop`：事件循环，负责反复等待事件、分发事件、执行跨线程投递过来的任务。
- `Channel`：一个 fd 的事件封装，保存 fd、关注的事件、实际发生的事件、对应回调。
- `Poller`：IO 多路复用抽象层，维护 `fd -> Channel*` 映射。
- `EPollPoller`：`Poller` 的 epoll 实现，调用 `epoll_create1 / epoll_ctl / epoll_wait`。

它们之间的关系可以先记成：

```text
EventLoop 拥有 Poller
EventLoop 拿到 activeChannels
Channel 代表一个 fd
Poller 负责把 Channel 注册到 epoll
EPollPoller 负责真正调用 Linux epoll API
```

## 2. 当前项目中的完整事件链

以客户端发送一条消息为例，主链路是：

```text
main()
  -> EventLoop loop
  -> EchoServer 注册 onMessage
  -> TcpConnection 给 Channel 注册 handleRead
  -> loop.loop()
  -> EPollPoller::poll()
  -> epoll_wait()
  -> EPollPoller::fillActiveChannels()
  -> EventLoop 遍历 activeChannels
  -> Channel::handleEvent()
  -> Channel::handleEventWithGuard()
  -> readCallback_(receiveTime)
  -> TcpConnection::handleRead()
  -> messageCallback_(conn, buffer, time)
  -> EchoServer::onMessage()
```

对应代码位置：

- `src/main.cc:19`：EchoServer 注册连接回调。
- `src/main.cc:23`：EchoServer 注册消息回调。
- `src/main.cc:91`：创建主 `EventLoop`。
- `src/main.cc:97`：进入 `loop.loop()`。
- `src/TcpConnection.cc:43`：`Channel` 的读回调绑定到 `TcpConnection::handleRead`。
- `src/EventLoop.cc:87`：调用 `poller_->poll()` 等待事件。
- `src/EventLoop.cc:88`：遍历活跃 `Channel`。
- `src/EventLoop.cc:91`：调用 `channel->handleEvent()`。
- `src/Channel.cc:91`：根据 `EPOLLIN / EPOLLPRI` 调用读回调。
- `src/TcpConnection.cc:190`：调用用户层 `messageCallback_`。
- `src/main.cc:49`：进入 EchoServer 的 `onMessage()`。

## 3. 四个核心对象的职责边界

### EventLoop

`EventLoop` 不直接关心 socket 怎么读写，它关心：

- 当前线程是否正在循环。
- 何时调用 `poller_->poll()`。
- 哪些 `Channel` 活跃。
- 如何把活跃事件分发给 `Channel`。
- 如何执行其他线程投递进来的任务。

重点代码：

```cpp
pollRetureTime_ = poller_->poll(kPollTimeMs, &activeChannels_);
for (Channel *channel : activeChannels_)
{
    channel->handleEvent(pollRetureTime_);
}
doPendingFunctors();
```

位置：`src/EventLoop.cc:87`

### Channel

`Channel` 不调用 `epoll_wait`，它只代表一个 fd 及其回调：

- `fd_`：这个 Channel 绑定的文件描述符。
- `events_`：希望监听的事件，比如读、写。
- `revents_`：`epoll_wait` 返回的实际发生事件。
- `readCallback_ / writeCallback_ / closeCallback_ / errorCallback_`：事件发生后的处理函数。

重点代码：

```cpp
if (revents_ & (EPOLLIN | EPOLLPRI))
{
    if (readCallback_)
    {
        readCallback_(receiveTime);
    }
}
```

位置：`src/Channel.cc:91`

### Poller

`Poller` 是抽象层，目的是让 `EventLoop` 不直接依赖某一种 IO 多路复用实现。

当前它主要维护：

```cpp
using ChannelMap = std::unordered_map<int, Channel *>;
ChannelMap channels_;
```

位置：`include/Poller.h`

你可以把它理解成：

```text
fd 是系统给的整数
Channel 是项目自己封装出来的 C++ 对象
Poller 用 map 把二者关联起来
```

### EPollPoller

`EPollPoller` 是真正接触 Linux epoll 的类：

- 构造函数调用 `epoll_create1`。
- `updateChannel()` 根据 Channel 状态决定 `ADD / MOD / DEL`。
- `poll()` 调用 `epoll_wait`。
- `fillActiveChannels()` 把 epoll 返回的事件还原成 `Channel*`。

重点代码：

```cpp
int numEvents = ::epoll_wait(epollfd_, &*events_.begin(),
                             static_cast<int>(events_.size()), timeoutMs);
```

位置：`src/EPollPoller.cc:34`

## 4. 你需要掌握到什么程度

这一阶段的合格标准：

1. 能画出这条链：

```text
EventLoop::loop
  -> EPollPoller::poll
  -> epoll_wait
  -> fillActiveChannels
  -> Channel::handleEvent
  -> TcpConnection::handleRead
  -> EchoServer::onMessage
```

2. 能解释 `Channel` 为什么需要同时有 `events_` 和 `revents_`：

```text
events_ 是我想监听什么。
revents_ 是这次 epoll 实际告诉我发生了什么。
```

3. 能解释为什么 `EventLoop` 不直接调用 `TcpConnection::handleRead()`：

```text
EventLoop 只负责事件循环和分发。
具体 fd 发生什么事件、该调用哪个业务处理函数，由 Channel 保存和触发。
这样 EventLoop 不需要知道 fd 背后是监听 socket、连接 socket、timerfd 还是 eventfd。
```

4. 能用 GDB 跑通一次消息回显链路：

```gdb
break EventLoop::loop
break EPollPoller::poll
break Channel::handleEventWithGuard
break TcpConnection::handleRead
break EchoServer::onMessage
run
```

5. 能用自己的话面试表达：

```text
这个项目使用 muduo 风格 Reactor 模型。EventLoop 负责事件循环，Poller/EPollPoller 封装 epoll，Channel 封装 fd 和事件回调。epoll_wait 返回就绪事件后，EPollPoller 将其转换为活跃 Channel 列表，EventLoop 遍历这些 Channel 并调用 handleEvent，最终根据 revents_ 触发读写关闭错误回调，进入 TcpConnection 和上层业务逻辑。
```

## 5. 本阶段小练习

练习不要急着改代码，先验证理解：

1. 在 `Channel::handleEventWithGuard()` 打断点，观察 `revents_` 的值。
2. 用 `nc 127.0.0.1 8080` 连接服务端并发送一行文本。
3. 在 GDB 中回答：
   - 当前触发的是哪个 fd？
   - 这个 fd 对应的是监听 socket 还是已连接 socket？
   - `readCallback_` 最终绑定的是哪个函数？

