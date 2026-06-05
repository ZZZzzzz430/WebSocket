# Reator-03-Poller与EPollPoller

## 1. Poller 解决什么问题

`Poller` 是 IO 多路复用的抽象层。

它的目的不是提高 epoll 本身的能力，而是隔离底层实现：

```text
EventLoop 只依赖 Poller 接口
具体用 epoll、poll 还是其他机制，由 Poller 子类决定
```

当前项目中，默认实现是 `EPollPoller`。

核心文件：

- `include/Poller.h`
- `src/Poller.cc`
- `include/EPollPoller.h`
- `src/EPollPoller.cc`
- `src/DefaultPoller.cc`

## 2. Poller 的接口

位置：`include/Poller.h`

```cpp
virtual Timestamp poll(int timeoutMs, ChannelList *activeChannels) = 0;
virtual void updateChannel(Channel *channel) = 0;
virtual void removeChannel(Channel *channel) = 0;
```

三个接口分别对应：

- `poll()`：等待事件，把活跃 Channel 填到 `activeChannels`。
- `updateChannel()`：新增或修改某个 Channel 的监听事件。
- `removeChannel()`：从 Poller 中移除某个 Channel。

`Poller` 还维护：

```cpp
using ChannelMap = std::unordered_map<int, Channel *>;
ChannelMap channels_;
```

含义：

```text
key   = fd
value = 这个 fd 对应的 Channel*
```

## 3. 默认为什么是 EPollPoller

位置：`src/DefaultPoller.cc`

```cpp
Poller *Poller::newDefaultPoller(EventLoop *loop)
{
    if (::getenv("MUDUO_USE_POLL"))
    {
        return nullptr;
    }
    else
    {
        return new EPollPoller(loop);
    }
}
```

当前代码中，如果没有设置 `MUDUO_USE_POLL`，就创建 `EPollPoller`。

注意：这里 `MUDUO_USE_POLL` 分支当前返回 `nullptr`，说明项目没有真正实现 poll 版本。所以学习时不要误以为当前支持 poll。

## 4. EPollPoller 的核心成员

位置：`include/EPollPoller.h`

```cpp
int epollfd_;
EventList events_;
```

含义：

- `epollfd_`：`epoll_create1` 返回的 epoll 实例 fd。
- `events_`：传给 `epoll_wait` 的数组，用来接收就绪事件。

构造函数：

位置：`src/EPollPoller.cc:13`

```cpp
EPollPoller::EPollPoller(EventLoop *loop)
    : Poller(loop)
    , epollfd_(::epoll_create1(EPOLL_CLOEXEC))
    , events_(kInitEventListSize)
```

这里初始事件数组大小是 16。如果一次返回的事件数量等于当前数组大小，会扩容。

## 5. epoll_wait 如何返回 Channel

位置：`src/EPollPoller.cc:29`

```cpp
Timestamp EPollPoller::poll(int timeoutMs, ChannelList *activeChannels)
{
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
    return now;
}
```

这段代码做了三件事：

1. 调用 `epoll_wait` 等待就绪事件。
2. 如果有事件，调用 `fillActiveChannels()`。
3. 如果事件数组满了，把 `events_` 扩容一倍。

关键是 `fillActiveChannels()`。

位置：`src/EPollPoller.cc:113`

```cpp
void EPollPoller::fillActiveChannels(int numEvents, ChannelList *activeChannels) const
{
    for (int i = 0; i < numEvents; ++i)
    {
        Channel *channel = static_cast<Channel *>(events_[i].data.ptr);
        channel->set_revents(events_[i].events);
        activeChannels->push_back(channel);
    }
}
```

这里为什么能拿到 `Channel*`？

因为注册 epoll 事件时，代码把 `Channel*` 放进了 `event.data.ptr`。

位置：`src/EPollPoller.cc:131`

```cpp
event.events = channel->events();
event.data.fd = fd;
event.data.ptr = channel;
```

所以 epoll 返回后可以直接从 `events_[i].data.ptr` 取回 `Channel*`。

这是本项目事件分发能从 Linux fd 回到 C++ 对象的关键。

## 6. updateChannel 如何决定 ADD/MOD/DEL

位置：`src/EPollPoller.cc:9`

```cpp
const int kNew = -1;
const int kAdded = 1;
const int kDeleted = 2;
```

`Channel::index_` 表示 Channel 在 Poller 中的状态：

- `kNew`：从未加入过 epoll。
- `kAdded`：已经加入 epoll。
- `kDeleted`：曾经加入过，但当前已从 epoll 删除。

位置：`src/EPollPoller.cc:63`

```cpp
void EPollPoller::updateChannel(Channel *channel)
{
    const int index = channel->index();

    if (index == kNew || index == kDeleted)
    {
        if (index == kNew)
        {
            int fd = channel->fd();
            channels_[fd] = channel;
        }
        channel->set_index(kAdded);
        update(EPOLL_CTL_ADD, channel);
    }
    else
    {
        if (channel->isNoneEvent())
        {
            update(EPOLL_CTL_DEL, channel);
            channel->set_index(kDeleted);
        }
        else
        {
            update(EPOLL_CTL_MOD, channel);
        }
    }
}
```

逻辑拆解：

```text
新 Channel 或已删除 Channel
  -> EPOLL_CTL_ADD

已存在 Channel 且没有任何关注事件
  -> EPOLL_CTL_DEL

已存在 Channel 且还有关注事件
  -> EPOLL_CTL_MOD
```

常见例子：

```text
channel->enableReading()
  -> events_ 加上 EPOLLIN
  -> updateChannel()
  -> 如果第一次注册，则 EPOLL_CTL_ADD
```

```text
channel->enableWriting()
  -> events_ 加上 EPOLLOUT
  -> updateChannel()
  -> 如果已经注册过，则 EPOLL_CTL_MOD
```

```text
channel->disableAll()
  -> events_ = 0
  -> updateChannel()
  -> EPOLL_CTL_DEL
```

## 7. update() 才是真正调用 epoll_ctl 的地方

位置：`src/EPollPoller.cc:124`

```cpp
void EPollPoller::update(int operation, Channel *channel)
{
    epoll_event event;
    ::memset(&event, 0, sizeof(event));

    int fd = channel->fd();

    event.events = channel->events();
    event.data.fd = fd;
    event.data.ptr = channel;

    if (::epoll_ctl(epollfd_, operation, fd, &event) < 0)
    {
        ...
    }
}
```

要重点理解：

```text
epoll_ctl 监听的是 fd。
项目保存的是 Channel。
event.data.ptr = channel 让 epoll 返回时能找到对应 Channel。
```

## 8. Poller 到 EventLoop 的返回关系

完整过程：

```text
EventLoop::loop()
  -> poller_->poll(timeout, &activeChannels_)
  -> EPollPoller::poll()
  -> epoll_wait()
  -> fillActiveChannels()
  -> activeChannels_ 填入 Channel*
  -> 返回 EventLoop
  -> EventLoop 遍历 Channel*
  -> Channel::handleEvent()
```

所以 `EPollPoller` 只负责：

```text
把内核返回的 epoll_event 转成项目里的 Channel*
```

它不直接调用业务回调。

## 9. 掌握标准

学完 `Poller / EPollPoller`，你需要能做到：

1. 能解释 `Poller` 为什么是抽象层。
2. 能说清楚 `channels_` 的 key 和 value 分别是什么。
3. 能解释 `EPollPoller::poll()` 如何调用 `epoll_wait`。
4. 能解释 `event.data.ptr = channel` 的作用。
5. 能画出 `enableReading -> epoll_ctl(ADD)` 的链路。
6. 能区分 `EPOLL_CTL_ADD / MOD / DEL` 分别在什么情况下调用。
7. 能解释为什么 `EPollPoller` 不直接调用 `TcpConnection::handleRead()`。

面试表达模板：

```text
Poller 是 IO 多路复用抽象层，EventLoop 只依赖 Poller 接口。当前项目默认使用 EPollPoller，它内部创建 epollfd，并用 epoll_ctl 管理 Channel 关注的 fd 事件。注册事件时会把 Channel* 放入 epoll_event.data.ptr，epoll_wait 返回后再取出 Channel*，设置 revents_，填充 activeChannels，交给 EventLoop 统一分发。
```

## 10. 小练习

用 GDB 验证：

```gdb
break EPollPoller::updateChannel
break EPollPoller::update
break EPollPoller::poll
break EPollPoller::fillActiveChannels
run
```

观察问题：

- 第一次 `enableReading()` 时，`operation` 是不是 `EPOLL_CTL_ADD`？
- 客户端发消息时，`epoll_wait` 返回的 `numEvents` 是多少？
- `events_[i].data.ptr` 指向的 Channel 的 `fd()` 是多少？
- `channel->set_revents()` 设置了什么事件？

