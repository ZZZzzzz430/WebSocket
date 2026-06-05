# test2 批改与查漏补缺

范围：

- `Reator-02-Channel事件封装与回调分发.md`
- `Reator-03-Poller与EPollPoller.md`
- `Reator-04-从epoll到EchoServer回调链.md`

说明：

- 本文件根据你在 `test2.md` 中填写的答案批改。
- 原答案保留在 `test2.md` 中，这里只写纠正、标准答案和后续代码实践方案。
- 你的自评分是 5 分，我认为比较准确。当前主要问题不是完全不会，而是几个核心边界仍然混淆。

---

## 一、总体评价

当前掌握情况：

```text
得分建议：5.5 / 10
```

已经掌握的点：

- 知道 `Channel` 是 fd 在 C++ 层的事件代理对象。
- 能区分 `events_` 是想监听的事件，`revents_` 是实际发生的事件。
- 知道 `Channel` 不直接调用 `epoll_wait`。
- 知道 `event.data.ptr = channel` 是为了 epoll 返回后找回 `Channel*`。
- 大致知道 `readCallback_` 会进入 `TcpConnection::handleRead()`。

需要重点补的点：

```text
1. Channel 不负责 fd 生命周期，Poller 也不负责 fd 生命周期，fd 通常由 Socket/TcpConnection/Acceptor 管理。
2. Channel::enableReading() 不会走 setReadCallback，也不会走 Poller::poll，而是走 updateChannel -> epoll_ctl。
3. TcpConnection 构造函数中给 Channel 绑定回调，不是在 Channel 构造函数中。
4. tie(shared_from_this()) 在 TcpConnection::connectEstablished() 中调用，不是在 Channel::handleEvent() 中调用。
5. Poller::channels_ 是 fd -> Channel* 的总映射，不是事件队列。
6. EventLoop::activeChannels_ 是本轮活跃 Channel* 列表。
7. EPollPoller::poll() 调用 epoll_wait，fillActiveChannels() 把 epoll_event 转成 Channel*。
8. Channel 根据 revents_ 分发 read/write/close/error 回调。
9. EchoServer::onMessage 不是 EPollPoller 或 Channel 直接调用，而是 TcpConnection::handleRead() 读取 Buffer 后调用 messageCallback_。
```

---

## 二、逐题批改

## 1. Channel 解决什么问题

你的回答：

```text
Channel 是 fd 在 C++ 代码层上面的代理对象。
它封装事件 fd、回调函数。
fd 生命周期受到 Poller 管理。
```

前两句大方向正确，最后一句需要纠正。

正确理解：

```text
Channel 不拥有 fd 生命周期。
Poller 也不拥有 fd 生命周期。
fd 通常由 Socket、TcpConnection、Acceptor 等对象管理。
Channel 只是保存 fd_ 的数值，并围绕这个 fd 保存事件和回调。
```

标准答案：

```text
Channel 是 Reactor 模型中对 fd 事件的 C++ 封装。
它把 fd_、events_、revents_、index_、所属 EventLoop，以及 readCallback_、writeCallback_、closeCallback_、errorCallback_ 绑定在一起。
它属于某个 EventLoop，但不负责 fd 的创建和关闭，也不负责回调函数内部业务逻辑的实现。
```

核心句：

```text
Channel 管事件，不管 fd 生命周期。
```

---

## 2. events_ / revents_ / index_

这题你答得比较好。

标准答案：

```text
events_  = 当前 Channel 希望注册到 epoll 的兴趣事件。
revents_ = epoll_wait 本轮返回后，该 fd 实际发生的就绪事件。
index_   = Channel 在 Poller/epoll 中的状态，用来判断 ADD、MOD、DEL。
```

判断题：

```text
1. 对。events_ 表示当前 Channel 想监听的事件。
2. 对。revents_ 表示 epoll_wait 实际返回的事件。
3. 对。index_ 表示 Channel 在 Poller 中的状态。
4. 错。Channel::handleEventWithGuard() 根据 revents_ 分发回调。
5. 对。EPollPoller::updateChannel() 根据 index_ 和 events_ 决定 ADD/MOD/DEL。
```

---

## 3. Channel 的事件注册链路

你的回答中这一题错误较多。

你写：

```text
Channel::enableReading()
  -> Channel::_setReadCallback
  -> EventLoop::updateChannel()
  -> Poll::poll()
  -> EPollPoller::update()
  -> epoll_ctl
```

问题：

- `enableReading()` 不会调用 `setReadCallback()`。
- `setReadCallback()` 是“设置回调”，不是“注册 epoll 事件”。
- `enableReading()` 不会走 `Poller::poll()`。
- `Poller::poll()` 是等待事件，`updateChannel()` 才是更新 epoll 监听事件。

标准链路：

```text
Channel::enableReading()
  -> Channel::update()
  -> EventLoop::updateChannel()
  -> EPollPoller::updateChannel()
  -> EPollPoller::update()
  -> epoll_ctl()
```

对应代码含义：

```text
Channel::enableReading()
  修改 events_，增加 EPOLLIN | EPOLLPRI

Channel::update()
  调用所属 EventLoop 的 updateChannel(this)

EventLoop::updateChannel()
  转发给 poller_->updateChannel(channel)

EPollPoller::updateChannel()
  根据 index_ 和 events_ 决定 ADD/MOD/DEL

EPollPoller::update()
  组装 epoll_event，调用 epoll_ctl
```

`enableWriting()` 和 `disableAll()` 也是同一条更新链，只是修改的 `events_` 不同。

---

## 4. Channel 回调绑定

你的回答：

```text
1. 在 Channel 构造函数中。
2. readCallback_ 绑定到 TcpRead。
3. writeCallback_ 绑定到 Tcpwrite。
```

需要纠正。

标准答案：

```text
1. 这段代码在 TcpConnection 的构造函数中。
2. Channel::readCallback_ 绑定到 TcpConnection::handleRead。
3. Channel::writeCallback_ 绑定到 TcpConnection::handleWrite。
4. closeCallback_ 绑定到 TcpConnection::handleClose。
5. errorCallback_ 绑定到 TcpConnection::handleError。
```

为什么不是直接绑定到 `EchoServer::onMessage()`？

```text
因为 Channel 只知道 fd 上有读事件，不知道如何从 socket 读取数据、如何处理 Buffer、连接状态如何变化。
这些是 TcpConnection 的职责。
所以 Channel 先调用 TcpConnection::handleRead()，由 TcpConnection 从 fd 读数据到 inputBuffer_，再调用用户注册的 messageCallback_，最终进入 EchoServer::onMessage()。
```

核心链路：

```text
Channel::readCallback_
  -> TcpConnection::handleRead()
  -> inputBuffer_.readFd(...)
  -> messageCallback_(conn, &inputBuffer_, time)
  -> EchoServer::onMessage()
```

---

## 5. tie 的生命周期保护

你的回答有对有错。

你写：

```text
这行代码在 Channel::handleEvent() 中调用。
```

这是错误的。

标准答案：

```text
channel_->tie(shared_from_this()) 在 TcpConnection::connectEstablished() 中调用。
```

`tie_` 类型：

```cpp
std::weak_ptr<void> tie_;
```

为什么用 `weak_ptr`：

```text
Channel 的回调里绑定了 TcpConnection 的 this 指针。
为了防止 TcpConnection 已经销毁但 Channel 还触发回调，需要在事件处理前判断 TcpConnection 是否还活着。
如果 Channel 直接保存 shared_ptr，会让 TcpConnection 和 Channel 的生命周期关系变复杂，可能导致连接对象无法按预期释放。
所以 Channel 保存 weak_ptr，事件触发时用 tie_.lock() 临时提升为 shared_ptr。
提升成功，说明 TcpConnection 还活着，可以执行回调。
提升失败，说明对象已经不存在，不再执行回调。
```

你写“访问野指针”是对的，但“导致栈溢出”不准确。更准确是：

```text
访问悬空指针，可能导致崩溃、未定义行为、内存错误。
```

`tie_.lock()` 失败意味着：

```text
绑定的 TcpConnection 对象已经销毁或不再存在，Channel 不应该继续执行回调。
```

不是简单等同于“连接关闭”，连接关闭是导致对象销毁的可能原因之一。

---

## 6. Poller 的职责

你的回答基本正确，但有几个字词要修正。

标准答案：

```text
1. Poller 是 IO 多路复用抽象层，不是具体 epoll 实现。
2. Poller::channels_ 保存 fd -> Channel* 的映射。
3. Poller::poll() 的作用是等待 IO 事件，并把本轮活跃 Channel 填入 activeChannels。
4. Poller::updateChannel() 的作用是新增、修改或删除某个 Channel 关注的事件。
5. 当前项目默认使用 EPollPoller。
```

`channels_` 准确含义：

```text
channels_ 的 key 是 fd。
channels_ 的 value 是 Channel*。
```

注意：

```text
Poller::channels_ 不是事件队列。
它是所有已纳入 Poller 管理的 fd 到 Channel 的映射。
```

---

## 7. activeChannels_ 与 channels_ 区别

这题你判断基本正确，但解释太简略。

标准对比：

```text
Poller::channels_ = unordered_map<int, Channel*>，保存 Poller 当前管理的所有 fd 到 Channel 的映射。
EventLoop::activeChannels_ = vector<Channel*>，只保存本轮 epoll_wait 返回的活跃 Channel。
```

判断题：

```text
1. 对。channels_ 是 fd -> Channel* 的 map。
2. 对。activeChannels_ 是本轮活跃 Channel* 列表。
3. 错。activeChannels_ 不保存所有注册到 epoll 的 Channel，只保存本轮活跃的 Channel。
4. 错。channels_ 保存所有被 Poller 管理的 Channel，不是只保存本轮活跃 Channel。
```

记忆方式：

```text
channels_ 是“总表”。
activeChannels_ 是“本轮结果”。
```

---

## 8. EPollPoller::poll()

你的回答有大方向，但不够准确。

标准答案：

```text
1. epollfd_ 来自 EPollPoller 构造函数中的 epoll_create1(EPOLL_CLOEXEC)。
2. events_ 是 vector<epoll_event>，作为 epoll_wait 的输出数组，用来接收本轮就绪事件。
3. numEvents > 0 表示本轮 epoll_wait 返回了至少一个就绪事件。
4. fillActiveChannels() 把 epoll_event 转成 Channel*，设置 revents_，并放入 activeChannels。
5. numEvents == events_.size() 说明这次数组被填满，可能还有更多事件，下次应该扩大接收数组。
6. Timestamp now 表示 poll 返回的时间点，会传给读回调，用于记录事件发生/返回时间。
```

你写：

```text
events_ 是已经监听到的活跃事件
```

更准确：

```text
events_ 是 epoll_wait 的结果缓冲区，它里面存放本轮返回的 epoll_event。
```

---

## 9. event.data.ptr = channel

你前 4 点大体正确，第 5 点错误。

标准答案：

```text
1. event.events 保存这个 Channel 想注册到 epoll 的兴趣事件，也就是 channel->events()。
2. event.data.ptr = channel 是把 C++ 层的 Channel* 存进 epoll_event。
3. epoll_wait 返回后，fillActiveChannels() 通过 events_[i].data.ptr 取回 Channel*。
4. 这一步让 Linux 返回的 epoll_event 能重新关联到项目里的 C++ Channel 对象，所以是从 fd 事件回到对象回调的关键。
5. 如果不保存 Channel*，也可以只保存 fd，然后通过 Poller::channels_ 这个 map 查 fd -> Channel*。代价是每个事件都要多一次哈希表查询，代码也没有直接保存指针方便。
```

你的“需要跨线程操作”不对。

这里和跨线程没有直接关系，核心是：

```text
直接通过 ptr 取 Channel*
vs
通过 fd 再查 channels_ map
```

---

## 10. EPOLL_CTL_ADD / MOD / DEL

你的 `test2.md` 这一段内容被截断了，这里给出完整标准答案。

```text
Channel 第一次加入 Poller：
  index_ = kNew，也就是 -1
  epoll_ctl 操作 = EPOLL_CTL_ADD
  之后 index_ 更新为 kAdded

Channel 已经加入 Poller，只是修改监听事件：
  index_ = kAdded
  epoll_ctl 操作 = EPOLL_CTL_MOD

Channel 已经加入 Poller，现在 events_ 为空：
  channel->isNoneEvent() = true
  epoll_ctl 操作 = EPOLL_CTL_DEL
  index_ 更新为 kDeleted

Channel 从 Poller 中彻底 remove：
  从 channels_ 中 erase(fd)
  如果 index_ == kAdded，则 EPOLL_CTL_DEL
  index_ 更新为 kNew
```

`disableAll()` 和 `remove()` 区别：

```text
disableAll()：
  把 events_ 置为 0，并通过 updateChannel() 让 epoll 不再监听这个 fd 的任何事件。
  但 Channel 对象和 Poller::channels_ 中的映射不一定彻底移除。

remove()：
  调用 EventLoop::removeChannel()，最终进入 EPollPoller::removeChannel()。
  它会从 Poller::channels_ 中删除 fd -> Channel* 映射。
```

简单记忆：

```text
disableAll 是“先不监听”。
remove 是“从 Poller 管理表中移除”。
```

---

## 11. 从客户端发送数据到 EchoServer::onMessage

你的 `test2.md` 中这一题也被截断了，这里给标准链路。

```text
客户端发送 hello
  -> 内核发现连接 fd 可读
  -> EPollPoller::poll()
  -> epoll_wait()
  -> EPollPoller::fillActiveChannels()
  -> 从 events_[i].data.ptr 取出 Channel*
  -> channel->set_revents(events_[i].events)
  -> activeChannels->push_back(channel)
  -> EventLoop::loop() 遍历 activeChannels_
  -> channel->handleEvent(pollRetureTime_)
  -> Channel 根据 revents_ 判断有 EPOLLIN / EPOLLPRI 事件
  -> 调用 readCallback_(receiveTime)
  -> TcpConnection::handleRead(receiveTime)
  -> inputBuffer_.readFd(channel_->fd(), &savedErrno)
  -> messageCallback_(shared_from_this(), &inputBuffer_, receiveTime)
  -> EchoServer::onMessage(conn, buf, time)
  -> conn->send(msg)
```

`messageCallback_` 注册时间：

```text
EchoServer 构造函数里调用 server_.setMessageCallback(...)。
之后 TcpServer 在创建 TcpConnection 时，会把这个用户层回调设置给 TcpConnection。
TcpConnection::handleRead() 读到数据后调用 messageCallback_，最终进入 EchoServer::onMessage。
```

---

## 12. 为什么不直接从 epoll_wait 调用业务函数

标准答案：

```text
EPollPoller 的职责是封装 epoll，不是处理业务。
epoll_wait 返回的是 fd 事件，这个 fd 背后可能是监听 socket、连接 socket、eventfd、timerfd，不一定是 TcpConnection。
如果 EPollPoller 直接调用 EchoServer::onMessage，就会让底层 IO 多路复用模块依赖上层业务对象，网络库和业务层强耦合。
这样后续接入 timerfd、eventfd、HTTP、WebSocket 时，EPollPoller 会被迫写大量业务判断，职责会变混乱。
正确做法是 EPollPoller 只把 epoll_event 转成 Channel*，EventLoop 分发 Channel，Channel 调用对应回调，最终由 TcpConnection 和业务层处理数据。
```

---

## 13. readCallback_ 到 messageCallback_ 的区别

你的 `test2.md` 里没有填写这一题，这里给标准答案。

```text
readCallback_：
  保存在 Channel 中。
  它是 fd 可读时 Channel 要调用的底层读事件回调。
  对 TcpConnection 来说，通常绑定到 TcpConnection::handleRead()。

messageCallback_：
  保存在 TcpConnection 中。
  它是读到完整数据后要调用的用户层消息回调。
  在当前 EchoServer 中，最终绑定到 EchoServer::onMessage()。
```

判断题：

```text
1. 对。readCallback_ 保存在 Channel 中。
2. 对。messageCallback_ 保存在 TcpConnection 中。
3. 对。readCallback_ 通常绑定到 TcpConnection::handleRead()。
4. 对。messageCallback_ 通常绑定到用户业务函数，比如 EchoServer::onMessage()。
5. 错。Channel 不会直接调用 EchoServer::onMessage()。
```

核心区别：

```text
readCallback_ 是“fd 可读事件回调”。
messageCallback_ 是“读到数据后的业务消息回调”。
```

---

## 14. 如果忘记 enableReading()

你的第 1 点错误。

你写：

```text
如果没调用 enableReading，连接 fd 能够监听到。
```

正确答案：

```text
1. 如果 channel_->enableReading() 没调用，连接 fd 不会注册 EPOLLIN 读事件。
2. 客户端发送数据后，TcpConnection::handleRead() 不会被调用。
3. EchoServer::onMessage() 不会被调用。
4. 应该从 connectEstablished -> enableReading -> Channel::update -> EventLoop::updateChannel -> EPollPoller::updateChannel -> EPollPoller::update 这条链排查。
```

建议断点：

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

## 15. 如果没有 event.data.ptr = channel

你前两点正确，后面需要补准确。

标准答案：

```text
1. epoll_wait 返回后不能直接拿到 Channel*。
2. 当前 fillActiveChannels() 依赖 events_[i].data.ptr，因此不能正常工作。
3. 如果只能拿到 fd，可以通过 Poller::channels_.find(fd) 找到对应 Channel*。
4. 当前项目直接保存 Channel*，可以省掉一次 map 查询，也让 fillActiveChannels() 的逻辑更直接。
```

注意：

```text
不是“通过底层 poll 封装”。
准确说是“通过 fd 到 Channel* 的 map 查询”。
```

---

## 16. 如果 Channel 根据 events_ 分发回调

你的回答基本正确。

标准答案：

```text
1. 会错误地调用没有实际发生的事件回调。例如 Channel 一直监听读事件，但本轮实际发生的是写事件或关闭事件，如果根据 events_ 判断，就可能误调用读回调。
2. events_ 只是兴趣事件，表示我希望 epoll 监听什么；revents_ 才是本轮 epoll_wait 实际告诉我发生了什么。
3. 正确依据是 revents_。
```

---

## 17. 判断题批改

你的第 5 题答错。

标准答案：

```text
1. 对。Channel 保存 fd 和回调，但不负责调用 epoll_wait。
2. 错。Channel::enableReading() 不直接调用 epoll_ctl，它通过 Channel::update -> EventLoop::updateChannel -> EPollPoller::updateChannel -> EPollPoller::update 间接调用。
3. 对。Channel::update() 会通过所属 EventLoop 间接更新 Poller。
4. 对。EPollPoller::fillActiveChannels() 会设置 Channel 的 revents_。
5. 错。Poller::channels_ 保存所有被 Poller 管理的 fd -> Channel* 映射，不是只保存本轮发生事件的 Channel。
6. 对。EventLoop::activeChannels_ 每一轮 loop 前会清空。
7. 对。event.data.ptr = channel 是为了 epoll 返回后找回 C++ 的 Channel 对象。
8. 对。TcpConnection::handleRead() 从 fd 读取数据到 Buffer，然后调用用户消息回调。
9. 错。EchoServer::onMessage() 是 TcpConnection::handleRead() 通过 messageCallback_ 间接调用的，不是 EPollPoller 直接调用。
10. 对。disableAll() 会让 Channel 不再关注任何事件，并触发一次 Poller 更新。
```

---

## 18. 面试表达题批改

## 19. 解释 Channel

你的表达中有几个问题：

```text
epoll_wait 监听到事件之后，会将 fd 返回，channel 根据 fd 进行封装回调。
```

更准确：

```text
epoll_wait 返回 epoll_event，EPollPoller 从 event.data.ptr 中取出之前保存的 Channel*，并设置该 Channel 的 revents_。
```

```text
EventLoop 会根据返回来 FillActiveChannles 进行调用回调处理。
```

更准确：

```text
fillActiveChannels() 是 EPollPoller 的函数，它负责填充 activeChannels_。EventLoop 负责遍历 activeChannels_ 并调用 Channel::handleEvent()。
```

标准表达：

```text
Channel 是 Reactor 模型中对 fd 事件的封装。它保存 fd_、想监听的事件 events_、epoll 实际返回的事件 revents_，以及读、写、关闭、错误等 callback。Channel 属于某个 EventLoop，但它不拥有 fd 的生命周期。业务对象如 TcpConnection 会把自己的 handleRead、handleWrite、handleClose、handleError 绑定到 Channel 对应回调上。epoll_wait 返回后，EPollPoller 会从 event.data.ptr 找回 Channel*，设置 revents_，并把它放入 activeChannels_。EventLoop 遍历 activeChannels_ 时调用 Channel::handleEvent()。Channel 再根据 revents_ 分发到对应 callback。对于 TcpConnection，Channel 还通过 tie 保存 weak_ptr，避免连接对象销毁后继续执行绑定了裸 this 的回调。
```

## 20. 解释 Poller / EPollPoller

你自己也写了“这点有点模糊”，判断准确。这里重点修正：

```text
channels_ 不是事件队列。
channels_ 是 fd -> Channel* 的总映射。
activeChannels_ 才是本轮活跃 Channel* 列表。
```

标准表达：

```text
Poller 是 IO 多路复用抽象层，EventLoop 通过 Poller 接口等待和更新事件。当前项目默认使用 EPollPoller，它是真正封装 epoll 的实现。EPollPoller 构造时通过 epoll_create1 创建 epollfd_。当 Channel 关注的事件变化时，EPollPoller::updateChannel() 会根据 Channel 的 index_ 和 events_ 决定调用 epoll_ctl 的 ADD、MOD 或 DEL。EPollPoller::poll() 内部调用 epoll_wait 等待就绪事件。Poller::channels_ 保存 fd 到 Channel* 的映射，用来记录当前 Poller 管理的 Channel。epoll_ctl 注册事件时，代码把 Channel* 存入 event.data.ptr。epoll_wait 返回后，EPollPoller 取出 event.data.ptr，设置 Channel 的 revents_，并把活跃 Channel 放入 EventLoop 的 activeChannels_。
```

## 21. 从 epoll 到 EchoServer 的回调链

你没有填写这一题。标准表达如下：

```text
客户端发送 hello 后，内核会把对应连接 fd 标记为可读。EventLoop 正在 loop() 中调用 EPollPoller::poll()，而 EPollPoller::poll() 内部阻塞在 epoll_wait。epoll_wait 返回后，EPollPoller::fillActiveChannels() 遍历返回的 epoll_event 数组。因为注册事件时 event.data.ptr 保存了 Channel*，所以这里可以直接取回连接 fd 对应的 Channel。EPollPoller 会把 events_[i].events 设置到 Channel 的 revents_ 中，并把该 Channel 放入 activeChannels_。EventLoop 随后遍历 activeChannels_，调用 Channel::handleEvent()。Channel::handleEventWithGuard() 根据 revents_ 发现有 EPOLLIN 读事件，于是调用 readCallback_。对于 TcpConnection 来说，readCallback_ 绑定的是 TcpConnection::handleRead()。TcpConnection::handleRead() 会调用 inputBuffer_.readFd() 从连接 fd 读取数据到 Buffer。读到数据后，它调用 messageCallback_(conn, &inputBuffer_, time)。messageCallback_ 是用户层消息回调，在当前 EchoServer 中绑定到 EchoServer::onMessage()。最后 EchoServer::onMessage() 从 Buffer 中取出字符串 hello，并调用 conn->send(msg) 回显给客户端。
```

---

## 三、当前必须背熟的 8 条

```text
1. Channel 管 fd 事件和回调，不拥有 fd 生命周期。
2. events_ 是兴趣事件，revents_ 是实际发生事件。
3. Channel 根据 revents_ 分发回调，不根据 events_。
4. enableReading() 的链路是 Channel::update -> EventLoop::updateChannel -> EPollPoller::updateChannel -> epoll_ctl。
5. Poller::channels_ 是 fd -> Channel* 总映射。
6. EventLoop::activeChannels_ 是本轮活跃 Channel* 列表。
7. event.data.ptr = channel 让 epoll_wait 返回后能找回 Channel*。
8. readCallback_ 进入 TcpConnection::handleRead，messageCallback_ 才进入 EchoServer::onMessage。
```

---

## 四、根据当前理解做代码工作的方案

你现在不适合直接大改 HTTP/WebSocket。更合适的是做“能验证 Reactor 链路的小功能”。下面按难度递进。

## 方案 A：给 Channel / EPollPoller 增加事件调试输出

目标：

```text
让你运行服务端时，能看见 fd、events_、revents_、ADD/MOD/DEL 的变化。
```

建议改动：

- 在 `Channel` 中增加一个辅助函数，把事件位转成字符串。
- 在 `EPollPoller::update()` 中打印：
  - fd
  - operation 是 ADD/MOD/DEL
  - event.events
- 在 `Channel::handleEventWithGuard()` 中打印：
  - fd
  - revents_
  - 最终走了 read/write/close/error 哪个分支

学习价值：

```text
你可以实际看到 enableReading -> EPOLL_CTL_ADD，发送数据 -> EPOLLIN，send 缓冲没写完 -> EPOLLOUT。
```

注意：

```text
这类日志只适合 Debug 学习，不适合高并发压测长期打开。
```

## 方案 B：写一个最小 GDB 验证笔记和断点脚本

目标：

```text
把你看不懂 GDB 的问题降低成固定步骤。
```

建议新增：

```text
notes/01-reactor-eventloop-channel/gdb-test2.md
debug/reactor.gdb
```

`debug/reactor.gdb` 可以包含：

```gdb
break EPollPoller::update
break EPollPoller::poll
break EPollPoller::fillActiveChannels
break Channel::handleEventWithGuard
break TcpConnection::handleRead
break EchoServer::onMessage
```

运行：

```bash
gdb -x debug/reactor.gdb ./bin/main
```

学习价值：

```text
把断点流程固定下来，你每次只观察 fd_、events_、revents_、numEvents、msg。
```

## 方案 C：增加一个 Echo 命令分支，验证业务回调位置

目标：

```text
只改 EchoServer::onMessage()，证明业务逻辑应该放在上层，而不是 EventLoop/Channel/EPollPoller。
```

示例行为：

```text
客户端输入 ping
服务端返回 pong

客户端输入 time
服务端返回当前时间

其他输入
服务端原样 echo
```

建议改动文件：

```text
src/main.cc
```

学习价值：

```text
你会更清楚 EchoServer::onMessage 是业务层入口。
底层 Reactor 不需要改，就能换业务行为。
```

## 方案 D：增加连接计数和简单状态日志

目标：

```text
在 onConnection() 中维护当前连接数。
```

示例：

```text
Connection UP, active connections = 1
Connection DOWN, active connections = 0
```

建议改动：

- 给 `EchoServer` 增加一个 `int connectionCount_`。
- 连接建立时加一。
- 连接断开时减一。

学习价值：

```text
练习 connectionCallback_，理解连接建立/关闭回调和 messageCallback_ 的区别。
```

## 方案 E：为 Buffer 或 LFU 写小单元测试

目标：

```text
先从非网络阻塞代码开始练测试。
```

建议优先：

```text
Buffer 基础读写测试
LFU 插入/淘汰测试
```

学习价值：

```text
不用先处理多线程和 epoll，先建立 CMake + 测试习惯。
```

---

## 五、推荐执行顺序

建议你按这个顺序做：

```text
1. 先做方案 B：GDB 断点脚本和调试笔记。
2. 再做方案 C：给 EchoServer::onMessage 增加 ping/time 分支。
3. 再做方案 A：增加 Debug 事件日志。
4. 最后做方案 D：连接计数。
```

原因：

```text
先用 GDB 看懂链路。
再只改业务层，确认底层 Reactor 不用动。
然后再给底层加日志，观察 Channel/Poller 行为。
最后用连接计数理解连接建立和关闭回调。
```

---

## 六、下一次建议的具体任务

建议下一次直接做这个最小任务：

```text
在 EchoServer::onMessage() 中增加 ping/time 两个命令：

输入 ping 返回 pong
输入 time 返回当前时间字符串
其他输入保持 echo
```

需要改的文件：

```text
src/main.cc
```

验证方式：

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j$(nproc)
./bin/main
```

另开终端：

```bash
nc 127.0.0.1 8080
```

测试：

```text
ping
time
hello
```

你应该能看到：

```text
pong
当前时间
hello
```

这个任务很适合现在做，因为它能强化：

```text
底层 Reactor 负责把消息送到 onMessage。
业务逻辑只需要改 onMessage。
```

