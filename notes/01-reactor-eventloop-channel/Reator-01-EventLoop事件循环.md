# Reator-01-EventLoop事件循环

## 1. EventLoop 解决什么问题

`EventLoop` 是 Reactor 的“循环主体”。它负责在一个线程中不断做三件事：

```text
等待事件
分发事件
执行队列任务
```

在当前项目中，它不直接处理 socket 业务逻辑，而是把事件交给 `Channel`。

核心文件：

- `include/EventLoop.h`
- `src/EventLoop.cc`

## 2. 核心成员变量

位置：`include/EventLoop.h:73`

```cpp
std::atomic_bool looping_;
std::atomic_bool quit_;
const pid_t threadId_;
Timestamp pollRetureTime_;
std::unique_ptr<Poller> poller_;
std::unique_ptr<TimerQueue> timerQueue_;
int wakeupFd_;
std::unique_ptr<Channel> wakeupChannel_;
ChannelList activeChannels_;
std::atomic_bool callingPendingFunctors_;
std::vector<Functor> pendingFunctors_;
std::mutex mutex_;
```

逐个理解：

- `looping_`：当前 `EventLoop` 是否正在循环。
- `quit_`：是否要求退出循环。
- `threadId_`：创建这个 `EventLoop` 的线程 id，用来实现 one loop per thread 检查。
- `poller_`：IO 多路复用对象，当前实际是 `EPollPoller`。
- `activeChannels_`：本轮 `epoll_wait` 返回的活跃 fd 对应的 `Channel` 列表。
- `wakeupFd_`：跨线程唤醒当前 `EventLoop` 用的 `eventfd`。
- `wakeupChannel_`：把 `wakeupFd_` 也包装成 `Channel`，接入同一套事件分发机制。
- `pendingFunctors_`：其他线程投递给当前 loop 执行的任务队列。
- `mutex_`：保护 `pendingFunctors_`。

重点理解：`EventLoop` 管的是“一个线程内的事件调度”，不是所有连接的所有逻辑。

## 3. 构造函数做了什么

位置：`src/EventLoop.cc:44`

```cpp
EventLoop::EventLoop()
    : looping_(false)
    , quit_(false)
    , callingPendingFunctors_(false)
    , threadId_(CurrentThread::tid())
    , poller_(Poller::newDefaultPoller(this))
    , wakeupFd_(createEventfd())
    , wakeupChannel_(new Channel(this, wakeupFd_))
```

构造时做了几件关键事：

1. 记录当前线程 id。
2. 创建默认 Poller，当前默认是 `EPollPoller`。
3. 创建 `eventfd`，用于跨线程唤醒。
4. 创建 `wakeupChannel_`，把 `eventfd` 纳入 epoll 监听。

下面这段是 one loop per thread 的基础：

```cpp
thread_local EventLoop *t_loopInThisThread = nullptr;
```

位置：`src/EventLoop.cc:13`

构造函数会检查同一个线程是否已经创建过 `EventLoop`：

```cpp
if (t_loopInThisThread)
{
    LOG_FATAL<<"Another EventLoop"...;
}
else
{
    t_loopInThisThread = this;
}
```

位置：`src/EventLoop.cc:54`

这意味着：

```text
一个线程中最多只能有一个 EventLoop。
多个线程可以各自有自己的 EventLoop。
```

## 4. wakeupChannel_ 为什么也是 Channel

位置：`src/EventLoop.cc:63`

```cpp
wakeupChannel_->setReadCallback(
    std::bind(&EventLoop::handleRead, this));

wakeupChannel_->enableReading();
```

这里很关键。

`wakeupFd_` 是一个 `eventfd`。其他线程调用 `wakeup()` 时，会往这个 fd 写 8 字节。因为 `wakeupChannel_` 监听了读事件，所以当前线程阻塞在 `epoll_wait` 时会被唤醒。

这体现了一个统一设计：

```text
socket fd 的读事件 -> Channel 回调
eventfd 的读事件  -> Channel 回调
timerfd 的读事件  -> 也可以 Channel 回调
```

所以 `EventLoop` 不需要为不同 fd 写不同分支，它们都可以抽象成 `Channel`。

## 5. loop() 主循环拆解

位置：`src/EventLoop.cc:77`

```cpp
void EventLoop::loop()
{
    looping_ = true;
    quit_ = false;

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

    looping_ = false;
}
```

逐行理解：

1. `activeChannels_.clear()`：清理上一轮活跃事件。
2. `poller_->poll(...)`：进入 epoll 等待。
3. `activeChannels_` 被填充：Poller 把发生事件的 fd 转成 `Channel*`。
4. 遍历每个活跃 `Channel`。
5. 调用 `channel->handleEvent()`。
6. 执行队列中的跨线程任务。

核心思想：

```text
EventLoop 不判断是读事件还是写事件。
EventLoop 只拿到 Channel，然后让 Channel 自己处理。
```

## 6. runInLoop 与 queueInLoop

位置：`src/EventLoop.cc:126`

```cpp
void EventLoop::runInLoop(Functor cb)
{
    if (isInLoopThread())
    {
        cb();
    }
    else
    {
        queueInLoop(cb);
    }
}
```

含义：

```text
如果当前就在这个 EventLoop 所属线程，直接执行。
如果不是，就放进队列，交给 EventLoop 所属线程执行。
```

位置：`src/EventLoop.cc:139`

```cpp
void EventLoop::queueInLoop(Functor cb)
{
    {
        std::unique_lock<std::mutex> lock(mutex_);
        pendingFunctors_.emplace_back(cb);
    }

    if (!isInLoopThread() || callingPendingFunctors_)
    {
        wakeup();
    }
}
```

为什么需要 `wakeup()`？

因为目标 loop 可能正阻塞在：

```cpp
epoll_wait(...)
```

如果只把任务放进 `pendingFunctors_`，但不唤醒它，这个任务可能要等到超时或下一次 fd 事件到来才执行。

## 7. doPendingFunctors 为什么先 swap

位置：`src/EventLoop.cc:194`

```cpp
std::vector<Functor> functors;
callingPendingFunctors_ = true;

{
    std::unique_lock<std::mutex> lock(mutex_);
    functors.swap(pendingFunctors_);
}

for (const Functor &functor : functors)
{
    functor();
}

callingPendingFunctors_ = false;
```

这里的 `swap` 很重要。

它的作用：

- 缩短加锁时间。
- 避免执行回调时还持有锁。
- 避免回调内部再次调用 `queueInLoop()` 时死锁。

如果写成：

```cpp
lock();
for (...) {
    functor();
}
unlock();
```

那么某个 `functor()` 内部再次调用 `queueInLoop()`，就可能再次尝试拿同一把锁，导致死锁。

## 8. 掌握标准

学完 `EventLoop`，你需要能做到：

1. 能解释 `EventLoop::loop()` 每一行的职责。
2. 能说清楚为什么 `EventLoop` 不直接处理读写，而是调用 `Channel::handleEvent()`。
3. 能解释 `threadId_` 和 `isInLoopThread()` 的意义。
4. 能解释 `runInLoop()` 和 `queueInLoop()` 的区别。
5. 能解释为什么跨线程投递任务后需要 `eventfd` 唤醒。
6. 能解释 `doPendingFunctors()` 为什么要用局部 vector 和 `swap`。

面试表达模板：

```text
EventLoop 是 Reactor 的事件循环对象，每个线程最多一个 EventLoop。它内部持有 Poller，循环调用 poll 等待活跃事件，然后遍历 activeChannels 调用 Channel::handleEvent 分发事件。对于跨线程任务，EventLoop 使用 pendingFunctors_ 保存回调，并通过 eventfd 唤醒阻塞在 epoll_wait 的 loop 线程，最后在 doPendingFunctors 中执行这些任务。
```

## 9. 小练习

用 GDB 验证：

```gdb
break EventLoop::EventLoop
break EventLoop::loop
break EventLoop::queueInLoop
break EventLoop::wakeup
break EventLoop::doPendingFunctors
run
```

观察问题：

- 主线程创建的 `EventLoop::threadId_` 是多少？
- `loop()` 是否一直阻塞在 `poller_->poll()`？
- 当有新连接分配到 sub loop 时，是否会进入 `queueInLoop()` 和 `wakeup()`？

