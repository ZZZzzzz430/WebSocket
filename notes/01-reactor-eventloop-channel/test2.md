# test2：Channel / Poller / epoll 回调链自测

范围：

- `Reator-02-Channel事件封装与回调分发.md`
- `Reator-03-Poller与EPollPoller.md`
- `Reator-04-从epoll到EchoServer回调链.md`

目标：

通过这份测试，检查你是否真正理解：

- `Channel` 如何封装 fd、事件和回调
- `events_ / revents_ / index_` 的含义
- `Channel::enableReading()` 如何一步步走到 `epoll_ctl`
- `Poller::channels_` 和 `EventLoop::activeChannels_` 的区别
- `EPollPoller::poll()` 如何调用 `epoll_wait`
- `event.data.ptr = channel` 的意义
- 一条消息如何从 `epoll_wait` 走到 `EchoServer::onMessage`

建议方式：

先独立作答，不翻笔记。答完后再对照源码和笔记检查。

---

## 一、Channel 基础理解

### 1. Channel 解决什么问题

请用自己的话回答：

```text
Channel 是什么？   将 fd 与回调函数进行绑定，是 fd 在 C++ 代码层上面的代理对象
它封装了哪些东西？ 事件 fd ， 回调函数
它是否拥有 fd 的生命周期？ 不拥有， Channel 只关心 fd 事件与注册、分发回调， fd 的生命周期收到 Poller 进行管理
```

要求至少包含这些关键词：

- `fd_`
- `events_`
- `revents_`
- `readCallback_`
- `writeCallback_`
- `EventLoop`

参考作答格式：

```text
Channel 是 ________。
它把 ___fd_____、__CallBack______、_events_______ 和 _revents_______ 绑定在一起。
它属于某个 __EvenLoop______，但不负责 保存 fd 或者 回调函数的实现________。
```

---

### 2. events_ / revents_ / index_

请解释下面三个成员：

```text
events_ = 想要监听的事件
revents_ = 实际上返回到的就绪事件
index_ = channel 在 epoll 当中的状态
```

然后判断：

1. `events_` 表示当前 Channel 想监听的事件。    对
2. `revents_` 表示本轮 `epoll_wait` 实际返回的事件。对
3. `index_` 用来表示 Channel 在 Poller 中的状态。 对
4. `Channel::handleEventWithGuard()` 根据 `events_` 判断调用哪个回调。 错，使用 revent 进行分发
5. `EPollPoller::updateChannel()` 会根据 `index_` 决定 `ADD / MOD / DEL`。 对

要求：

- 每条写“对”或“错”。
- 错误项要说明原因。

---

### 3. Channel 的事件注册链路

请补全 `enableReading()` 到 `epoll_ctl()` 的调用链：

```text
Channel::enableReading()
  -> _Channel::_setReadCallback_________ ___________
  -> EventLoop::updateChannel()
  -> __Poll::poll()____________________
  -> EPollPoller::update()
  -> ___epoll_ctl___________________
```

要求：

- 写出函数名。
- 说明每一步属于哪个类。
- 说明 `enableWriting()` 和 `disableAll()` 大体也会走到哪里。

---

### 4. Channel 回调绑定

阅读下面代码：

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

请回答：

1. 这段代码在哪个类的构造函数中？ Channel
2. `Channel::readCallback_` 最终绑定到哪个函数？ TcpRead
3. `Channel::writeCallback_` 最终绑定到哪个函数？ Tcpwrite
4. 为什么不是直接绑定到 `EchoServer::onMessage()`？  封装 与 回调实现， Echo 是业务层
5. `TcpConnection::handleRead()` 做完底层读取后，如何进入 `EchoServer::onMessage()`？ 完成读取数据之后调用 Echo Server 等函数进行回显

---

### 5. tie 的生命周期保护

请解释：

```cpp
channel_->tie(shared_from_this());
```

回答这些问题：

1. 这行代码在哪个函数里调用？  channel::handleEvent()
2. `tie_` 在 `Channel` 中是什么类型？ 指针，弱引用的 weak_ptr
3. 为什么 `Channel` 里保存的是 `weak_ptr`，而不是直接保存 `shared_ptr`？ 保存成 shared 导致 tcp 析构函数失效。因为还有引用不能销毁
4. 如果没有 `tie()`，`Channel` 回调中绑定的裸 `this` 可能有什么风险？ 访问野指针，导致栈溢出等错误
5. `Channel::handleEvent()` 中 `tie_.lock()` 失败意味着什么？ Tcp 连接关闭

---

## 二、Poller / EPollPoller 理解

### 6. Poller 的职责

请回答：

1. `Poller` 是具体 epoll 实现，还是 IO 多路复用抽象层？  OP 多路复用抽象层，封装 epoll
2. `Poller::channels_` 保存的是什么？  fd 与 Channel 的映射
3. `Poller::poll()` 的作用是什么？     把活跃的 fd 放进 activeChannels
4. `Poller::updateChannel()` 的作用是什么？   新增或者更改 channel 的简体个时间
5. 当前项目默认使用哪个 Poller 实现？ EPollPoller

请写出 `channels_` 的准确含义：

```text
channels_ 的 key 是 ________。
channels_ 的 value 是 __Channel* 
```

---

### 7. activeChannels_ 与 channels_ 区别

请对比：

```text
Poller::channels_ = Channels
EventLoop::activeChannels_ = activeChannels
```

判断：

1. `channels_` 是 `fd -> Channel*` 的 map。  对
2. `activeChannels_` 是本轮活跃的 `Channel*` 列表。  对
3. `activeChannels_` 会保存所有注册到 epoll 的 Channel。  错，只保存本轮活跃事件
4. `channels_` 只保存本轮发生事件的 Channel。 错，是 fd 与 Channel 的映射

要求：

- 每条写“对”或“错”。
- 用一句话说明这两个容器的区别。

---

### 8. EPollPoller::poll()

阅读下面代码：

```cpp
int numEvents = ::epoll_wait(epollfd_, &*events_.begin(),
                             static_cast<int>(events_.size()), timeoutMs);
Timestamp now(Timestamp::now());

if (numEvents > 0)
{
    fillActiveChannels(numEvents, activeChannels);
    if (numEvents == events_.size())
    {
        events_.resize(events_.size() * 2);
    }
}
```

请回答：

1. `epollfd_` 是怎么来的？  内核事件的句柄
2. `events_` 的作用是什么？   已经监听到的活跃事件
3. `numEvents > 0` 表示什么？  当阻塞到事件
4. 为什么要调用 `fillActiveChannels()`？ 把活跃事件放入 activeChannel ，Event Loop 循环回调
5. 为什么 `numEvents == events_.size()` 时要扩容？ 缓存不够，要扩容进行保存 fd
6. `EPollPoller::poll()` 返回的 `Timestamp now` 有什么意义？ 不知道

---

### 9. event.data.ptr = channel

阅读下面代码：

```cpp
event.events = channel->events();
event.data.fd = fd;
event.data.ptr = channel;
```

请回答：

1. `event.events` 保存什么？  想要监听的事件
2. `event.data.ptr = channel` 的作用是什么？  拿到 channel 回调，进行保存
3. `epoll_wait` 返回后，项目如何从 `epoll_event` 找回 `Channel*`？通过 event.data.ptr 保存 Channel 的指针
4. 为什么这一步是“从 Linux fd 回到 C++ 对象”的关键？  因为通过指针数组进行保存 ，将 fd 封装成 C++ 的Channel 对象
5. 如果不保存 `Channel*`，你觉得还可以怎么找回 Channel？代价是什么？需要跨线程操作

---

### 10. EPOLL_CTL_ADD / MOD / DEL

请补全下面逻辑：

```text
Channel 第一次加入 Poller：
  index_ = __-1______
  epoll_ctl 操作 = ________

Channel 已经加入 Poller，只是修改监听事件：
  index_ = ________
  epoll_ctl 操作 = ________
→Server::onMessage

请补全完整链路：

```text
客户端发送 hello
  -> 内核发现连接 fd ________
  -> EPollPoller::poll()
  -> ______________________
  -> EPollPoller::fillActiveChannels()
  -> 从 events_[i].data.ptr 取出 ________
  -> channel->set_revents(________)
  -> activeChannels->push_back(________)
  -> EventLoop::loop() 遍历 activeChannels_
  -> ______________________
  -> Channel 根据 revents_ 判断有 ________ 事件
  -> 调用 readCallback_(receiveTime)
  -> ______________________
  -> inputBuffer_.readFd(channel_->fd(), &savedErrno)
  -> messageCallback_(shared_from_this(), &inputBuffer_, receiveTime)
  -> ______________________
→要求从下面角度回答：

- `EPollPoller` 的职责
- fd 背后对象类型不确定
- 业务层和网络库耦合
- 后续扩展 timerfd / eventfd / HTTP / WebSocket 的影响

---

### 13. readCallback_ 到 messageCallback_ 的区别

请解释：

```text
readCallback_ =
messageCallback_ =
```

判断：

1. `readCallback_` 保存在 `Channel` 中。
2. `messageCallback_` 保存在 `TcpConnection` 中。
3. `readCallback_` 通常绑定到 `TcpConnection::handleRead()`。
4. `messageCallback_` 通常绑定到用户业务函数，比如 `EchoServer::onMessage()`。
5. `Channel` 会直接调用 `EchoServer::onMessage()`。

---

## 四、代码推理题

### 14. 如果忘记 enableReading()

在 `TcpConnection::connectEstablished()` 中有：

```cpp
channel_->enableReading();
```

请回答：

1. 如果这行代码没调用，连接 fd 会被 epoll 监听读事件吗 ？  能够监听到
2. 客户端发送数据后，`TcpConnection::handleRead()` 会被调用吗？ 不会调用，fd 监听到，但是没有调用到回调
3. `EchoServer::onMessage()` 会被调用吗？ 不会， 回调没有调用
4. 这类 bug 应该在哪些断点上排查？ break break EPollPOller::poll

建议断点：

```gdb
break TcpConnection::connectEstablished
break Channel::enableReading
break EPollPoller::update
break EPollPoller::poll
break TcpConnection::handleRead
```

---

### 15. 如果没有 event.data.ptr = channel

假设 `EPollPoller::update()` 中没有：

```cpp
event.data.ptr = channel;
```

请回答：

1. `epoll_wait` 返回后还能直接拿到 `Channel*` 吗？  不能
2. `fillActiveChannels()` 当前代码还能正常工作吗？  不能
3. 如果只能拿到 fd，要怎么找到对应 Channel？  通过底层 poll 封装
4. 为什么当前项目选择保存 `Channel*` 更方便？ 因为直接将 事件 封装成 C++ 指针，能够通过指针访问对象

---

### 16. 如果 Channel 根据 events_ 分发回调

假设 `Channel::handleEventWithGuard()` 错误地根据 `events_` 判断读写，而不是根据 `revents_`。

请回答：

1. 会产生什么错误？  回调错误的函数。
2. 为什么“我监听了读事件”不等于“这次真的发生了读事件”？  events 只是开始时初始化给出的要监听事件，但返回事件进行绑定时，可能会有其他状体，比如该连接关闭事件
3. 正确判断依据应该是什么？  通过 revent

---

## 五、判断题

请判断对错，并说明原因。

1. `Channel` 保存 fd 和回调，但不负责调用 `epoll_wait`。 对
2. `Channel::enableReading()` 会直接调用 Linux `epoll_ctl`。  错 ，channel 不会调用，只负责绑定事件和 fd。调用底层函数时 Poller 封装的 poll 进行调用
3. `Channel::update()` 会通过所属 `EventLoop` 间接更新 Poller。  对
4. `EPollPoller::fillActiveChannels()` 会设置 Channel 的 `revents_`。 对
5. `Poller::channels_` 只保存本轮发生事件的 Channel。 对
6. `EventLoop::activeChannels_` 每一轮 loop 前会清空。 对
7. `event.data.ptr = channel` 是为了 epoll 返回后能找回 C++ 的 Channel 对象。  对
8. `TcpConnection::handleRead()` 负责从 fd 读取数据到 Buffer，然后调用用户消息回调。   对
9. `EchoServer::onMessage()` 是由 `EPollPoller` 直接调用的。 错，是 TcpConnection 进行调用
10. `disableAll()` 会让 Channel 不再关注任何事件，并触发一次 Poller 更新。 对

---

## 六、GDB 实操题

### 17. 验证 Channel 注册读事件

启动：

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j$(nproc)
gdb ./bin/main
```

设置断点：

```gdb
break TcpConnection::connectEstablished
break Channel::enableReading
break Channel::update
break EventLoop::updateChannel
break EPollPoller::updateChannel
break EPollPoller::update
run
```

另开终端：

```bash
nc 127.0.0.1 8080
```

记录：

1. `connectEstablished()` 中调用 `enableReading()` 的 fd 是多少？
2. `Channel::events_` 在 `enableReading()` 后是什么？
3. `EPollPoller::update()` 中的 `operation` 是 `ADD` 还是 `MOD`？
4. `event.data.ptr` 是否等于当前 `Channel*`？

---

### 18. 验证消息回调链

设置断点：

```gdb
break EPollPoller::poll
break EPollPoller::fillActiveChannels
break Channel::handleEventWithGuard
break TcpConnection::handleRead
break EchoServer::onMessage
run
```

客户端发送：

```text
hello
```

记录：

1. `epoll_wait` 返回的 `numEvents` 是多少？
2. `events_[i].events` 是什么？
3. `channel->revents_` 是什么？
4. `Channel::handleEventWithGuard()` 走到了读回调、写回调、关闭回调还是错误回调？
5. `TcpConnection::handleRead()` 中 `readFd()` 返回值 `n` 是多少？
6. `EchoServer::onMessage()` 中 `msg` 是什么？

---

## 七、面试表达题

### 19. 解释 Channel

请用 5 到 8 句话解释 `Channel`。

必须包含：

- fd
- events_
- revents_
- callback
- EventLoop
- tie
- TcpConnection

建议开头：

```text
Channel 是 Reactor 模型中对 fd 事件的封装...
Channel 是 Reactor 模型中对 fd 事件的封装，核心成员包括想要监听的事件 events，和实际上监听到的事件 revents ，在项目运行中 epoll_wait 监听到事件之后，会将 fd 返回，channel 根据 fd 进行封装回调。 EventLoop 循环，每次有活跃事件之后， EventLoop 会根据返回来 FillActiveChannles 进行调用回调处理。再由 Channel 进行事件分发与调用回调，但是此时会有由 Tcp 连接关闭的可能，因此在进行分发之前会根据成员变量 tie 来进行判断连接是否关闭，如果关闭则退出当前事件，连接还在就回调 Tcp 进行。
```


---

### 20. 解释 Poller / EPollPoller

请用 5 到 8 句话解释 `Poller / EPollPoller`。

必须包含：

- IO 多路复用
- epoll_create1
- epoll_ctl
- epoll_wait
- channels_
- activeChannels_
- event.data.ptr

Poller 是封装 IO 多路复用， EPollPoller 则是底层的框架用于阻塞 IO 事件。
epoll_create1, epoll_ctl, epoll_wait 则对应事件的状态，根据此来进行 fd 的返回。 Channels 则是事件队列，将监听到的事件放入此中进行管理，
这点有点模糊
---

### 21. 解释从 epoll 到 EchoServer 的回调链

请用一段话解释：

```text
客户端发送 hello 后，项目是如何从 epoll_wait 一步步走到 EchoServer::onMessage 的？
```

要求：

- 不少于 8 句话。
- 必须准确区分 `Channel::readCallback_` 和 `TcpConnection::messageCallback_`。
- 必须提到 `Buffer`。

---

## 八、自评分标准

完成后按下面标准给自己打分： 5 分

```text
0-3 分：只记得 Channel / Poller 名字，不能画出调用链。
4-6 分：能说出大概流程，但混淆 activeChannels_、channels_、events_、revents_。
7-8 分：能完整解释 Channel、Poller、epoll_wait 到 onMessage 的链路。
9-10 分：能结合源码、GDB、生命周期 tie、event.data.ptr、ADD/MOD/DEL 进行完整表达。
```

建议目标：

这一部分达到 8 分以上，再进入连接建立模块 `Acceptor / TcpServer / TcpConnection`。

