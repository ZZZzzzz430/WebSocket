# Reator-05-主干串联总复习

## 0. 这份笔记解决什么问题

这一份把前面的内容串起来：

- `Reator-00`：Reactor 主干总览
- `Reator-01`：`EventLoop`
- `Reator-02`：`Channel`
- `Reator-03`：`Poller / EPollPoller`
- `Reator-04`：从 `epoll_wait` 到 `EchoServer::onMessage`
- `test1 / test2 / answer`：你做题时暴露出的误区和修正

本阶段最终要搞清楚一句话：

```text
客户端 fd 上发生事件后，项目如何从 epoll_wait 一步步走到业务回调 EchoServer::onMessage。
```

---

## 1. Reactor 主干总图

当前项目的 Reactor 主干可以分成五层：

```text
EchoServer
  业务层：onConnection / onMessage

TcpConnection
  连接层：读写 fd、管理 Buffer、连接状态、调用用户回调

Channel
  事件分发层：封装 fd、events_、revents_、读写关闭错误回调

EventLoop
  事件循环层：poll 等待事件、遍历 activeChannels_、执行 pendingFunctors_

Poller / EPollPoller
  IO 多路复用层：封装 epoll_create1 / epoll_ctl / epoll_wait
```

记住职责边界：

```text
EPollPoller 不处理业务。
EventLoop 不判断读写事件。
Channel 不读取 socket 数据。
TcpConnection 不负责 epoll_wait。
EchoServer 不关心 epoll 细节。
```

---

## 2. 一条消息的完整调用链

客户端发送 `hello` 后，正确链路是：

```text
客户端发送 hello
  -> 内核发现连接 fd 可读
  -> EventLoop::loop()
  -> EPollPoller::poll()
  -> epoll_wait()
  -> EPollPoller::fillActiveChannels()
  -> 从 events_[i].data.ptr 取出 Channel*
  -> channel->set_revents(events_[i].events)
  -> activeChannels->push_back(channel)
  -> EventLoop 遍历 activeChannels_
  -> channel->handleEvent(pollRetureTime_)
  -> Channel::handleEventWithGuard()
  -> 判断 revents_ 包含 EPOLLIN / EPOLLPRI
  -> readCallback_(receiveTime)
  -> TcpConnection::handleRead(receiveTime)
  -> inputBuffer_.readFd(channel_->fd(), &savedErrno)
  -> messageCallback_(shared_from_this(), &inputBuffer_, receiveTime)
  -> EchoServer::onMessage(conn, buf, time)
  -> conn->send(msg)
```

你需要把这条链背熟到能手写。

面试时可以压缩成：

```text
epoll_wait 返回就绪事件后，EPollPoller 通过 event.data.ptr 找回 Channel，设置 revents_ 并填入 activeChannels_。EventLoop 遍历活跃 Channel，调用 Channel::handleEvent。Channel 根据 revents_ 触发 readCallback_，进入 TcpConnection::handleRead。TcpConnection 从 fd 读取数据到 Buffer，再调用用户注册的 messageCallback_，最终进入 EchoServer::onMessage。
```

---

## 3. EventLoop：循环和调度

核心代码：

```cpp
while (!quit_)
{
    activeChannels_.clear();
    pollRetureTime_ = poller_->poll(kPollTimeMs, &activeChannels_);
    for (Channel *channel : activeChannels_)
    {
        channel->handleEvent(pollRetureTime_);
    }
    doPendingFunctors();
}
```

逐步解释：

```text
activeChannels_.clear()
  清空上一轮活跃事件列表。

poller_->poll(...)
  调用 Poller 等待 IO 事件。本项目实际进入 EPollPoller::poll()，再进入 epoll_wait()。

for Channel*
  遍历本轮活跃 Channel。

channel->handleEvent(...)
  让 Channel 根据 revents_ 分发读、写、关闭、错误回调。

doPendingFunctors()
  执行投递到当前 EventLoop 的任务，比如跨线程任务。
```

`EventLoop` 的主职责：

```text
1. 等待事件。
2. 分发活跃 Channel。
3. 执行 pendingFunctors_。
```

不是：

```text
监听连接、分配连接、直接处理业务数据。
```

这些工作由 `Acceptor / TcpServer / TcpConnection / EchoServer` 分别完成。

---

## 4. 你的误区：EventLoop 职责

### 误区 1：EventLoop 主要负责监听连接、分配连接

你的原理解：

```text
EventLoop 在主循环中主要做监听连接、分配连接、处理其他线程回调。
```

正确理解：

```text
EventLoop 是更底层的事件循环，它不关心这个 fd 是监听 fd 还是连接 fd。
它只负责 poll 等待事件、遍历 activeChannels_、调用 Channel::handleEvent、执行 pendingFunctors_。
```

更准确表述：

```text
监听连接是 listenfd 对应 Channel 的读事件。
分配连接是 TcpServer / EventLoopThreadPool 的逻辑。
EventLoop 只是驱动这些 Channel 上的事件发生。
```

### 误区 2：EventLoop 根据 connfd 判断事件

你的原理解：

```text
具体事件类型由 Channel 根据 connfd 判断。
```

正确理解：

```text
具体事件类型由 Channel 根据 revents_ 判断。
connfd 只是文件描述符编号，不表示这次发生了什么事件。
```

---

## 5. Channel：fd 事件和回调的封装

`Channel` 代表一个 fd 的事件代理对象。

它保存：

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

核心概念：

```text
fd_       = 这个 Channel 绑定的文件描述符编号
events_   = 我想监听什么事件
revents_  = epoll_wait 本轮实际告诉我发生了什么事件
index_    = Channel 在 Poller/epoll 中的状态
callback  = 事件发生后要调用的函数
```

最重要的区分：

```text
events_ 是兴趣事件。
revents_ 是就绪事件。
Channel 根据 revents_ 分发回调。
```

`Channel::handleEventWithGuard()` 的核心逻辑：

```cpp
if ((revents_ & EPOLLHUP) && !(revents_ & EPOLLIN))
{
    closeCallback_();
}

if (revents_ & EPOLLERR)
{
    errorCallback_();
}

if (revents_ & (EPOLLIN | EPOLLPRI))
{
    readCallback_(receiveTime);
}

if (revents_ & EPOLLOUT)
{
    writeCallback_();
}
```

---

## 6. 你的误区：Channel 和 fd 生命周期

### 误区 1：fd 生命周期由 Poller 管理

你的原理解：

```text
fd 的生命周期受到 Poller 管理。
```

正确理解：

```text
Channel 不拥有 fd 生命周期。
Poller 也不拥有 fd 生命周期。
fd 通常由 Socket、TcpConnection、Acceptor 等对象管理。
Channel 只是保存 fd_ 的整数值，并围绕这个 fd 记录事件和回调。
```

固定记法：

```text
Socket/TcpConnection 管 fd 生命周期。
Channel 管 fd 事件和回调。
Poller 管 fd 到 Channel 的监听关系。
```

### 误区 2：Channel 底层都是 TCP

你的原理解中出现过：

```text
Channel 底层也是通过 TCP 进行。
```

正确理解：

```text
Channel 不一定代表 TCP 连接。
它可以代表 listen socket、连接 socket、eventfd、timerfd。
Channel 是 fd 事件抽象，不是 TCP 专属对象。
```

---

## 7. Channel 注册事件：enableReading 到 epoll_ctl

正确链路：

```text
Channel::enableReading()
  -> events_ |= kReadEvent
  -> Channel::update()
  -> EventLoop::updateChannel(this)
  -> poller_->updateChannel(channel)
  -> EPollPoller::updateChannel(channel)
  -> EPollPoller::update(operation, channel)
  -> epoll_ctl(epollfd_, operation, fd, &event)
```

注意：

```text
enableReading() 不会调用 setReadCallback()。
enableReading() 不会调用 Poller::poll()。
enableReading() 是修改监听事件，然后更新 epoll。
```

`setReadCallback()` 是另一件事：

```text
setReadCallback()
  设置读事件发生后应该调用哪个函数。
```

所以要分开：

```text
setReadCallback：绑定回调。
enableReading：注册读事件。
```

---

## 8. 你的误区：事件注册链路

你的原回答：

```text
Channel::enableReading()
  -> Channel::_setReadCallback
  -> EventLoop::updateChannel()
  -> Poll::poll()
  -> EPollPoller::update()
  -> epoll_ctl
```

错误点：

```text
1. enableReading 不走 setReadCallback。
2. updateChannel 不走 Poller::poll。
3. Poller::poll 是等待事件，不是更新事件。
```

正确链路：

```text
Channel::enableReading()
  -> Channel::update()
  -> EventLoop::updateChannel()
  -> EPollPoller::updateChannel()
  -> EPollPoller::update()
  -> epoll_ctl()
```

用一句话记：

```text
注册事件走 updateChannel，等待事件走 poll。
```

---

## 9. Poller / EPollPoller：封装 epoll

`Poller` 是抽象层：

```cpp
virtual Timestamp poll(int timeoutMs, ChannelList *activeChannels) = 0;
virtual void updateChannel(Channel *channel) = 0;
virtual void removeChannel(Channel *channel) = 0;
```

`EPollPoller` 是具体 epoll 实现：

```text
epoll_create1
  创建 epoll 实例，得到 epollfd_

epoll_ctl
  添加、修改、删除 fd 关注事件

epoll_wait
  等待就绪事件
```

关键成员：

```cpp
int epollfd_;
std::vector<epoll_event> events_;
```

`Poller::channels_`：

```cpp
std::unordered_map<int, Channel *> channels_;
```

含义：

```text
key   = fd
value = Channel*
```

它是“总表”。

`EventLoop::activeChannels_`：

```cpp
std::vector<Channel *> activeChannels_;
```

它是“本轮结果”。

---

## 10. 你的误区：channels_ 和 activeChannels_

### 误区 1：activeChannels_ 是 fd 与 Channel 的映射

你的原理解：

```text
activeChannels_ 里装的是 fd 与 Channel 的映射。
```

正确理解：

```text
activeChannels_ 是 vector<Channel*>，只保存本轮发生事件的 Channel。
```

### 误区 2：Poller::channels_ 是事件队列

你的原理解：

```text
channels_ 是事件队列，将监听到的事件放入其中管理。
```

正确理解：

```text
Poller::channels_ 是 fd -> Channel* 的总映射。
它保存 Poller 当前管理的所有 Channel，不是事件队列，也不是本轮活跃事件列表。
```

固定对照：

```text
Poller::channels_         = 总表，fd -> Channel*
EventLoop::activeChannels_ = 本轮活跃列表，vector<Channel*>
EPollPoller::events_       = epoll_wait 的输出数组，vector<epoll_event>
```

---

## 11. event.data.ptr = channel：从 fd 回到 C++ 对象

注册 epoll 事件时：

```cpp
event.events = channel->events();
event.data.fd = fd;
event.data.ptr = channel;
```

`event.data.ptr = channel` 的意义：

```text
把 C++ 层的 Channel* 存进 epoll_event。
epoll_wait 返回后，可以从 events_[i].data.ptr 直接取回 Channel*。
```

返回时：

```cpp
Channel *channel = static_cast<Channel *>(events_[i].data.ptr);
channel->set_revents(events_[i].events);
activeChannels->push_back(channel);
```

这一步非常关键：

```text
Linux 内核只知道 fd 和事件。
项目需要回到 C++ 对象，才能调用 Channel::handleEvent() 和回调函数。
event.data.ptr 就是这座桥。
```

如果不保存 `Channel*`，也可以：

```text
只保存 fd，然后用 Poller::channels_.find(fd) 找 Channel*。
```

但这样每次事件返回都要多一次 map 查询，没有直接存指针方便。

---

## 12. 你的误区：event.data.ptr 替代方案

你的原理解：

```text
如果不保存 Channel*，需要跨线程操作。
```

正确理解：

```text
这和跨线程没有直接关系。
如果不保存 Channel*，可以通过 fd 到 Poller::channels_ 这个 map 中查找 Channel*。
区别只是直接取指针 vs 通过 fd 查表。
```

---

## 13. EPOLL_CTL_ADD / MOD / DEL

`Channel::index_` 的三个状态：

```text
kNew     = -1  从未加入 Poller
kAdded   = 1   已经加入 Poller
kDeleted = 2   曾经加入，但当前从 epoll 删除
```

注册逻辑：

```text
第一次加入：
  index_ = kNew
  操作 = EPOLL_CTL_ADD
  之后 index_ = kAdded

已经加入，只是修改事件：
  index_ = kAdded
  events_ 非空
  操作 = EPOLL_CTL_MOD

已经加入，现在不关注任何事件：
  index_ = kAdded
  channel->isNoneEvent() = true
  操作 = EPOLL_CTL_DEL
  之后 index_ = kDeleted

彻底 remove：
  channels_.erase(fd)
  如果 index_ == kAdded，先 EPOLL_CTL_DEL
  之后 index_ = kNew
```

`disableAll()` 和 `remove()` 区别：

```text
disableAll()
  events_ = 0，让 epoll 不再监听这个 fd 的任何事件。

remove()
  从 Poller::channels_ 这张总表中删除 fd -> Channel* 映射。
```

简单记：

```text
disableAll 是不监听。
remove 是不管理。
```

---

## 14. readCallback_ 和 messageCallback_

这是你后面最容易混淆的地方。

`readCallback_`：

```text
保存位置：Channel
绑定对象：TcpConnection::handleRead
触发时机：Channel 发现 revents_ 中有 EPOLLIN / EPOLLPRI
层级：网络库底层读事件回调
```

`messageCallback_`：

```text
保存位置：TcpConnection
绑定对象：EchoServer::onMessage
触发时机：TcpConnection::handleRead 从 fd 读到数据后
层级：用户业务消息回调
```

完整关系：

```text
Channel::readCallback_
  -> TcpConnection::handleRead()
  -> inputBuffer_.readFd(...)
  -> TcpConnection::messageCallback_
  -> EchoServer::onMessage()
```

所以：

```text
Channel 不直接调用 EchoServer::onMessage。
EPollPoller 不直接调用 EchoServer::onMessage。
EventLoop 也不直接调用 EchoServer::onMessage。
```

真正调用用户消息回调的是：

```text
TcpConnection::handleRead()
```

---

## 15. 你的误区：回调绑定位置

### 误区 1：TcpConnection 回调绑定代码在 Channel 构造函数中

你的原理解：

```text
这段 setReadCallback 代码在 Channel 构造函数中。
```

正确理解：

```text
这段代码在 TcpConnection 构造函数中。
TcpConnection 创建自己的 Channel，然后把 TcpConnection::handleRead / handleWrite / handleClose / handleError 绑定进去。
```

### 误区 2：readCallback_ 绑定到 TcpRead

正确函数名：

```text
readCallback_  -> TcpConnection::handleRead
writeCallback_ -> TcpConnection::handleWrite
closeCallback_ -> TcpConnection::handleClose
errorCallback_ -> TcpConnection::handleError
```

### 误区 3：handleRead 读完数据后“调用 EchoServer 等函数”

更准确：

```text
TcpConnection::handleRead() 读数据到 inputBuffer_。
如果 n > 0，它调用 messageCallback_(shared_from_this(), &inputBuffer_, receiveTime)。
messageCallback_ 之前由 EchoServer/TcpServer 注册，最终指向 EchoServer::onMessage。
```

---

## 16. tie：生命周期保护

`TcpConnection` 构造函数中绑定回调时用了裸 `this`：

```cpp
std::bind(&TcpConnection::handleRead, this, ...)
```

风险：

```text
如果 TcpConnection 已经销毁，但 Channel 仍然触发事件，回调里的 this 就变成悬空指针。
```

所以连接建立时调用：

```cpp
channel_->tie(shared_from_this());
```

位置：

```text
TcpConnection::connectEstablished()
```

`Channel` 中保存：

```cpp
std::weak_ptr<void> tie_;
```

事件触发时：

```cpp
std::shared_ptr<void> guard = tie_.lock();
if (guard)
{
    handleEventWithGuard(receiveTime);
}
```

含义：

```text
lock 成功：TcpConnection 还活着，可以执行回调。
lock 失败：对象已经不存在，不再执行回调。
```

为什么不用 `shared_ptr`：

```text
Channel 如果长期持有 TcpConnection 的 shared_ptr，可能让连接对象无法按预期释放。
weak_ptr 不增加引用计数，只在事件处理瞬间尝试提升。
```

---

## 17. 你的误区：tie 调用位置和含义

你的原理解：

```text
channel_->tie(shared_from_this()) 在 Channel::handleEvent() 中调用。
tie_.lock() 失败意味着 Tcp 连接关闭。
```

正确理解：

```text
tie() 在 TcpConnection::connectEstablished() 中调用。
Channel::handleEvent() 里只是使用 tie_.lock() 做生命周期检查。
tie_.lock() 失败意味着绑定对象已经不存在，不一定只等同于连接关闭。
```

---

## 18. 如果忘记 enableReading()

你原来的错误理解：

```text
如果没调用 enableReading，连接 fd 仍然能够监听到。
```

正确理解：

```text
如果 TcpConnection::connectEstablished() 中没有调用 channel_->enableReading()，
连接 fd 就不会注册 EPOLLIN 读事件。
客户端发送数据后，epoll 不会把这个连接 fd 的读事件返回给当前 Channel。
TcpConnection::handleRead() 不会被调用。
EchoServer::onMessage() 也不会被调用。
```

排查断点：

```gdb
break TcpConnection::connectEstablished
break Channel::enableReading
break Channel::update
break EventLoop::updateChannel
break EPollPoller::updateChannel
break EPollPoller::update
break TcpConnection::handleRead
```

---

## 19. eventfd 和 pendingFunctors_ 补充串联

虽然 `test2` 重点是 Channel/Poller，但 Reactor 主干还必须记住 `EventLoop` 的跨线程唤醒机制。

`queueInLoop(cb)`：

```text
把 cb 放入 pendingFunctors_。
如果调用者不在目标 EventLoop 线程，调用 wakeup()。
```

`wakeup()`：

```text
向 wakeupFd_ 写 8 字节。
wakeupFd_ 是 eventfd。
wakeupChannel_ 监听 wakeupFd_ 的读事件。
epoll_wait 被唤醒。
EventLoop::handleRead() 读取 eventfd。
本轮事件处理后 doPendingFunctors() 执行 cb。
```

关键区分：

```text
eventfd 负责唤醒 epoll_wait。
doPendingFunctors() 负责真正执行任务。
```

---

## 20. 最终掌握标准

学完 Reactor 主干，你至少要能做到：

```text
1. 手写 epoll_wait 到 EchoServer::onMessage 的完整链路。
2. 解释 EventLoop、Channel、Poller、EPollPoller、TcpConnection 的职责边界。
3. 区分 events_ 和 revents_。
4. 区分 Poller::channels_、EventLoop::activeChannels_、EPollPoller::events_。
5. 解释 Channel::enableReading() 如何走到 epoll_ctl。
6. 解释 event.data.ptr = channel 的作用。
7. 解释 readCallback_ 和 messageCallback_ 的区别。
8. 解释 tie 为什么能保护 TcpConnection 生命周期。
9. 解释 eventfd 如何唤醒阻塞在 epoll_wait 的 EventLoop。
```

如果能做到这些，你才算真正读通了 Reactor 主干。

---

## 21. 你的错误和正确理解总对照

| 你的错误理解 | 正确理解 |
| --- | --- |
| `activeChannels_` 是 fd 与 Channel 的映射 | `activeChannels_` 是本轮活跃 `Channel*` 列表 |
| `Poller::channels_` 是事件队列 | `Poller::channels_` 是 `fd -> Channel*` 总映射 |
| `EventLoop` 主要负责监听连接、分配连接 | `EventLoop` 负责等待事件、分发 Channel、执行 pendingFunctors_ |
| `Channel` 根据 connfd 判断事件类型 | `Channel` 根据 `revents_` 判断读写关闭错误事件 |
| `enableReading()` 会走 `setReadCallback()` | `setReadCallback()` 绑定回调，`enableReading()` 注册读事件 |
| `enableReading()` 会走 `Poller::poll()` | `enableReading()` 走 `updateChannel -> epoll_ctl` |
| `fd` 生命周期由 Poller 管理 | fd 生命周期通常由 `Socket/TcpConnection/Acceptor` 管理 |
| `Channel` 底层都是 TCP | `Channel` 可以封装 socket fd、eventfd、timerfd |
| `setReadCallback` 代码在 Channel 构造函数中 | 该绑定代码在 `TcpConnection` 构造函数中 |
| `readCallback_` 直接进入 EchoServer | `readCallback_ -> TcpConnection::handleRead -> messageCallback_ -> EchoServer::onMessage` |
| `tie()` 在 `Channel::handleEvent()` 中调用 | `tie()` 在 `TcpConnection::connectEstablished()` 中调用 |
| `tie_.lock()` 失败只表示连接关闭 | 更准确是绑定对象已经不存在，不应继续执行回调 |
| 不存 `event.data.ptr` 需要跨线程找 Channel | 可以通过 fd 查 `Poller::channels_`，和跨线程无直接关系 |
| 忘记 `enableReading()` 后 fd 仍能监听读事件 | 不会注册 EPOLLIN，读事件不会进入 `handleRead()` |
| `EPollPoller` 可以直接调用业务函数 | `EPollPoller` 只封装 epoll，不依赖业务层 |

---

## 22. 最小复述模板

你可以按这个模板复述 Reactor 主干：

```text
这个项目采用 muduo 风格 Reactor 模型。EventLoop 是事件循环对象，每个线程最多一个 EventLoop，它内部持有 Poller，循环调用 poll 等待事件。当前默认 Poller 实现是 EPollPoller，底层通过 epoll_create1 创建 epollfd，通过 epoll_ctl 注册或修改 fd 事件，通过 epoll_wait 等待就绪事件。每个 fd 会被封装成 Channel，Channel 保存 fd_、events_、revents_ 和读写关闭错误回调。注册 epoll 时，EPollPoller 会把 Channel* 存入 event.data.ptr，所以 epoll_wait 返回后可以直接找回 Channel，设置 revents_ 并放入 activeChannels_。EventLoop 遍历 activeChannels_，调用 Channel::handleEvent。Channel 根据 revents_ 调用 readCallback_、writeCallback_ 等回调。对 TcpConnection 来说，readCallback_ 绑定到 TcpConnection::handleRead，handleRead 从 fd 读数据到 Buffer，再调用 messageCallback_，最终进入 EchoServer::onMessage。
```

---

## 23. 下一步代码实践方向

现在最适合做小步代码验证，不要大改。

推荐顺序：

```text
1. 只改 EchoServer::onMessage，增加 ping/time 命令。
2. 增加一个 GDB 断点脚本，固定观察 epoll_wait -> Channel -> TcpConnection -> EchoServer。
3. 增加 Debug 日志，打印 fd、events_、revents_、ADD/MOD/DEL。
4. 在 onConnection 中增加连接计数，区分 connectionCallback_ 和 messageCallback_。
```

第一步最推荐：

```text
输入 ping 返回 pong。
输入 time 返回当前时间。
其他输入保持 echo。
```

原因：

```text
这个改动只发生在业务层 EchoServer::onMessage。
它能证明底层 Reactor 只是把消息送到业务回调，业务逻辑不应该写进 EventLoop / Channel / EPollPoller。
```

