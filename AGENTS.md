# AGENTS.md

## 项目定位

这是一个 C++11 高性能网络服务器 / WebServer 学习项目，目前更接近 **muduo 风格的 Reactor 网络库 + EchoServer 示例**，并额外包含：

- 基于 `epoll` 的事件驱动网络模块
- `EventLoop` / `Channel` / `Poller` / `EPollPoller` / `Acceptor` / `TcpConnection` / `TcpServer`
- one loop per thread 的线程模型：`EventLoopThread`、`EventLoopThreadPool`
- 定时器模块：`Timer`、`TimerQueue`
- 异步日志模块：`AsyncLogging`、`LogFile`、`LogStream`、`Logger`
- 内存池模块：`memoryPool`
- LFU 缓存模块：`LFU.h`
- 当前入口程序是 `src/main.cc`，默认启动 8080 端口 EchoServer

用户正在把该项目作为 C++ 后端项目学习材料，希望通过它理解网络编程、Reactor、epoll、多线程、日志、内存池、CMake/Makefile，并逐步具备优化开发和面试表达能力。

## Codex 开始工作前必须先问的问题

在开始大规模改代码、重构、写文档或生成学习路线前，先向用户询问下面问题。不要一次问太多，可以优先问 5～8 个最关键的问题。

### 1. 学习目标

1. 你当前更想把这个项目用于哪一类目标？  E 都要，但要重心放在 AB，理解项目并完成面试
   - A. 读懂项目源码
   - B. 写进简历并准备面试
   - C. 在原项目上新增功能
   - D. 学 CMake / Makefile / Linux 调试
   - E. 以上都要，但请排序
2. 你希望我讲解时偏向：   源码理解，面试八股，但不代表其他不重要，我有余力就多学一点
   - 源码逐行拆解
   - 模块调用链梳理
   - 画架构图 / 时序图
   - 面试八股总结
   - GDB 调试路线
3. 你现在最卡的模块是哪一个？比如 `EventLoop`、`Channel`、`TcpConnection`、线程池、日志、内存池、CMake。  回调吧

### 2. 当前环境

1. 你是在 Linux、WSL、Docker 还是远程服务器上运行？ Linux mint 430 机器，我是 Window 电脑上使用 vscode 终端进行 ssh 连接，此外也可通过 docker 进行，顺便练习工具，但是这不是重点

2. 你的编译命令是什么？例如：  如下， cmake -S . -B  ...

   ```bash
   cmake -S . -B build
   cmake --build build -j$(nproc)
   ./bin/main
   ```

3. 当前项目能否成功编译运行？如果不能，请贴出完整报错。  可以运行

4. 你希望我优先保证：能跑起来、能调试、能测试，还是代码结构更清晰？  能调试和测试，让我参与到开发，理解项目并完成调试和测试

### 3. 项目改造方向

1. 你想把它继续做成 EchoServer，还是扩展成真正的 HTTP/WebSocket Server？  可以扩展 业务层代码，但要放到理解项目之后，至于什么业务到时候再说吧
2. 如果要新增功能，优先级是什么？ 没有想好
   - HTTP 解析与响应
   - WebSocket 握手和帧解析
   - 路由系统
   - 静态文件服务
   - 定时踢出空闲连接
   - 压测与性能优化
   - 单元测试
   - 日志完善
   - CMake 重构
3. 是否允许大改目录结构？还是尽量在原结构上小步修改？ 尽量小修改吧
4. 是否需要保留原作者代码风格，还是可以现代化为 C++17/20？  可以 现代化 C++ 17 / 20

### 4. 你的基础背景

1. 你目前对以下内容的掌握程度如何？分别用 0～5 分回答： C++ 类 4分， socket3 ，epoll 2， 线程 2，Cmake 1 GDB 2 
   - C++ 类、智能指针、RAII
   - socket 编程
   - epoll
   - 线程 / 互斥锁 / 条件变量
   - CMake
   - GDB
2. 你是否已经学过 CSAPP、操作系统、计算机网络？哪些地方比较薄弱？ 学过 CS 144，对于 app 只有部分，操作系统只简单了解，不算很多。
3. 你更希望我补基础，还是直接结合源码讲？结合源码讲解

### 5. 输出偏好

1. 每次回答你希望是什么形式？ 详细教程，方便理解，最好结合代码
   - 简短提示
   - 详细教程
   - 先给结论再拆代码
   - 代码注释版
   - 问答式引导
2. 是否希望我每次给你留一个“小练习”？  可以，但是练习最好别太难，把我从项目分神就不好了
3. 是否希望我把每个模块整理成可放进 README / 笔记 / 简历的版本？ 要，最好新建一个存放笔记的文件，按照模块进行不同区分。只要笔记，不用简历。

## 项目结构概览

```text
.
├── CMakeLists.txt          # 顶层 CMake，添加 src / memory / log 子目录
├── README.md               # 原项目介绍，偏宣传/说明，源码细节较少
├── include/                # 所有头文件
├── src/                    # 网络库核心源码 + main.cc
├── log/                    # 异步日志模块源码
├── memory/                 # 内存池模块源码
├── lib/                    # 已生成的动态库，不建议提交到 Git
├── bin/                    # 编译后的可执行文件目录，不建议提交到 Git
├── build/                  # CMake 构建目录，不建议提交到 Git
└── img/                    # README 图片资源
```

## 建议的 Git 忽略项

如果用户询问哪些文件不要提交，建议添加或检查 `.gitignore`：

```gitignore
build/
bin/
lib/*.so
logs/
*.log
*.o
*.a
*.so
*.out
.cache/
.vscode/
.idea/
.DS_Store
nvim-linux-x86_64.appimage
```

注意：如果 `lib/` 中的 `.so` 是项目运行必须依赖且没有源码生成方式，需要先确认再忽略。当前项目中 `src/`、`log/`、`memory/` 都有源码和 CMake 生成库，通常不需要提交生成的 `.so`。

## 编译和运行建议

优先使用 out-of-source build：

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j$(nproc)
./bin/main
```

测试 EchoServer：

```bash
nc 127.0.0.1 8080
# 输入任意文本，应收到相同文本回显
```

或：

```bash
telnet 127.0.0.1 8080
```

## Codex 工作原则

### 1. 先理解，再修改

除非用户明确要求直接改代码，否则先做：

1. 说明当前模块职责
2. 画出调用链
3. 指出关键类和关键函数
4. 给出最小验证方式
5. 最后再建议是否修改代码

### 2. 小步修改

用户正在学习项目，不要一次性进行大规模重构。优先：

- 每次只改一个模块
- 每次说明为什么改
- 每次给出编译命令和测试命令
- 每次说明可能影响哪些文件

### 3. 保留学习价值

不要只给最终答案。应该帮助用户理解：

- 这段代码解决什么问题
- 为什么要这样设计
- 如果不用这种设计会有什么问题
- 它和 OS / 网络 / C++ 八股如何对应
- 面试时怎么表达

### 4. 对不确定内容要验证

涉及以下内容时，要先搜索或读取项目文件，不要凭空判断：

- 函数调用链
- 成员变量含义
- 编译错误来源
- 线程安全问题
- 生命周期问题
- CMake 链接问题
- 运行路径和日志路径

## 模块拆解路线

建议按下面顺序带用户理解项目。

### 第 0 阶段：先跑起来

目标：确认项目能编译、能运行、能 echo。

需要检查：

- `CMakeLists.txt`
- `src/CMakeLists.txt`
- `log/CMakeLists.txt`
- `memory/CMakeLists.txt`
- `src/main.cc`

输出内容：

- 编译命令
- 运行命令
- 测试命令
- 常见错误处理
- 生成文件解释：`build/`、`bin/`、`lib/`

### 第 1 阶段：Reactor 主干

核心文件：

- `include/EventLoop.h` / `src/EventLoop.cc`
- `include/Channel.h` / `src/Channel.cc`
- `include/Poller.h` / `src/Poller.cc`
- `include/EPollPoller.h` / `src/EPollPoller.cc`
- `src/DefaultPoller.cc`

要讲清楚：

- `EventLoop` 为什么是事件循环
- `Channel` 为什么是 fd 的事件封装
- `Poller` 和 `EPollPoller` 的关系
- `epoll_wait` 返回后事件如何分发
- `Channel::handleEvent()` 如何调用用户回调

建议生成调用链：

```text
main()
  -> EventLoop loop
  -> loop.loop()
  -> Poller::poll()
  -> epoll_wait()
  -> activeChannels
  -> Channel::handleEvent()
  -> readCallback_ / writeCallback_ / closeCallback_ / errorCallback_
```

### 第 2 阶段：连接建立

核心文件：

- `include/Socket.h` / `src/Socket.cc`
- `include/InetAddress.h` / `src/InetAddress.cc`
- `include/Acceptor.h` / `src/Acceptor.cc`
- `include/TcpServer.h` / `src/TcpServer.cc`

要讲清楚：

- socket 创建、bind、listen、accept
- `Acceptor` 只负责监听新连接
- `TcpServer::newConnection()` 如何创建 `TcpConnection`
- 主 loop 和 sub loop 如何分工

建议调用链：

```text
TcpServer::start()
  -> Acceptor::listen()
  -> listenfd 注册到 main EventLoop
  -> 有新连接到来
  -> Acceptor::handleRead()
  -> accept()
  -> TcpServer::newConnection()
  -> 创建 TcpConnection
  -> 分配给某个 sub EventLoop
```

### 第 3 阶段：连接读写

核心文件：

- `include/TcpConnection.h` / `src/TcpConnection.cc`
- `include/Buffer.h` / `src/Buffer.cc`
- `include/Callbacks.h`
- `src/main.cc`

要讲清楚：

- `TcpConnection` 管理一个已连接 socket
- `Buffer` 如何处理半包/粘包的基础缓冲问题
- `onMessage` 是用户层业务回调
- `send()` 如何写回数据
- 连接关闭时回调如何触发

当前 `main.cc` 是 EchoServer：收到什么就回显什么。

### 第 4 阶段：多线程模型

核心文件：

- `include/EventLoopThread.h` / `src/EventLoopThread.cc`
- `include/EventLoopThreadPool.h` / `src/EventLoopThreadPool.cc`
- `include/Thread.h` / `src/Thread.cc`
- `include/CurrentThread.h` / `src/CurrentThread.cc`

要讲清楚：

- one loop per thread
- main loop 只负责 accept
- sub loop 负责连接读写
- `runInLoop()` / `queueInLoop()` 的意义
- 为什么要用 wakeup fd 或类似机制唤醒 loop

### 第 5 阶段：定时器

核心文件：

- `include/Timer.h` / `src/Timer.cc`
- `include/TimerQueue.h` / `src/TimerQueue.cc`
- `include/Timestamp.h` / `src/Timestamp.cc`

要讲清楚：

- timerfd 或定时事件如何接入 epoll
- 定时器如何排序和触发
- 重复定时任务如何重新加入
- 可以如何扩展为空闲连接检测

### 第 6 阶段：日志系统

核心文件：

- `include/Logger.h` / `src/Logger.cc`
- `include/AsyncLogging.h` / `log/AsyncLogging.cc`
- `include/LogFile.h` / `log/LogFile.cc`
- `include/LogStream.h` / `log/LogStream.cc`
- `include/FileUtil.h` / `log/FileUtil.cc`

要讲清楚：

- 前端日志接口和后端落盘线程
- 双缓冲异步日志思想
- 日志滚动
- 为什么服务器不能每次同步写磁盘

### 第 7 阶段：内存池和 LFU

核心文件：

- `include/memoryPool.h` / `memory/memoryPool.cc`
- `include/LFU.h`
- `include/KICachePolicy.h`

要讲清楚：

- 内存池解决什么问题
- 小对象频繁分配为什么慢
- LFU 缓存的淘汰策略
- 当前 `main.cc` 中 LFU 只是初始化示例，是否实际接入业务需要进一步确认

### 第 8 阶段：项目优化和简历化

可选优化方向：

1. CMake 现代化：使用 `target_include_directories`、明确 target 依赖、避免全局 `include_directories`
2. `.gitignore` 清理：不提交 `build/`、`bin/`、`lib/*.so`、日志文件
3. 添加 HTTP 解析：从 EchoServer 进化为 HTTP Server
4. 添加 WebSocket：握手、mask、frame 解析、ping/pong、close frame
5. 添加测试：单元测试 Buffer、HTTP parser、LFU、内存池
6. 添加压测：`wrk` / `ab` / 自写客户端
7. 添加 GDB 调试脚本和学习断点
8. 添加 README 架构图和模块说明

## 回答用户时的推荐格式

用户问“讲解某个模块”时，按这个结构回答：

```text
1. 这个模块解决什么问题
2. 关键类/文件
3. 核心数据成员
4. 核心函数调用链
5. 结合一条请求的完整流程
6. 容易出错/面试常问点
7. 建议你亲手做的小练习
```

用户问“报错怎么解决”时，按这个结构回答：

```text
1. 先判断错误类型
2. 指出最可能的原因
3. 给出最小修复命令或代码
4. 解释为什么这样修
5. 给出验证命令
```

用户问“能不能改成某功能”时，按这个结构回答：

```text
1. 这个功能在当前架构中的位置
2. 最小实现方案
3. 需要改哪些文件
4. 每个文件改什么
5. 编译运行测试方式
6. 后续可以怎么优化
```

## GDB 调试建议

建议用户从这些断点开始：

```gdb
break main
break EventLoop::loop
break EPollPoller::poll
break Acceptor::handleRead
break TcpServer::newConnection
break TcpConnection::handleRead
break EchoServer::onMessage
run
```

调试连接流程：

1. 启动服务端并停在 `EventLoop::loop`
2. 另开终端执行：`nc 127.0.0.1 8080`
3. 观察是否进入 `Acceptor::handleRead`
4. 输入消息，观察是否进入 `TcpConnection::handleRead`
5. 继续进入 `EchoServer::onMessage`

## CMake 学习建议

这个项目适合用来学习 CMake，因为它有顶层目录和多个子目录。

先让用户掌握：

- `cmake_minimum_required`
- `project`
- `set(CMAKE_CXX_STANDARD 11)`
- `include_directories`
- `add_subdirectory`
- `file(GLOB ...)`
- `add_library`
- `add_executable`
- `target_link_libraries`
- `CMAKE_RUNTIME_OUTPUT_DIRECTORY`
- `CMAKE_LIBRARY_OUTPUT_DIRECTORY`

然后再逐步重构为现代 CMake。

## 面试表达模板

如果用户要把项目写进简历，可以辅助整理为：

```text
基于 C++11 实现的高性能网络服务器，采用 Reactor 模型和 epoll I/O 多路复用，实现了 EventLoop、Channel、Poller、TcpServer、TcpConnection 等核心组件；使用 one loop per thread 线程模型处理并发连接；实现异步日志、定时器、内存池和 LFU 缓存模块，提高服务端可维护性和性能。
```

面试讲解顺序：

1. 整体架构：Reactor + epoll + 线程池
2. 新连接如何建立
3. 数据如何读取和回写
4. 多线程如何分配连接
5. 日志为什么异步
6. 定时器可以做什么
7. 内存池和缓存的意义
8. 自己做过哪些改动和优化

## 当前项目需要特别注意的点


2. 当前 `main.cc` 仍是 EchoServer，不是真正的 WebSocket Server。

3. `README.md` 主要是项目介绍，缺少具体源码运行和模块文档，建议后续补充。


5. 代码中存在 `src/CurrentThread.cc` 和 `log/CurrentThread.cc` 两份同名实现，需要检查是否重复、是否链接冲突、是否设计上有意分离。


   ```bash
   ss -lntp | grep 8080
   ```

7. 如果用户说“WebSocket 项目”，他是指仓库名

## 给 Codex 的行为约束

- 不要在没有询问目标的情况下直接大规模重构。
- 不要直接删除用户文件，尤其是 `lib/`、`bin/`、`build/`，除非用户明确确认或只是建议加入 `.gitignore`。
- 不要假设项目已经支持 HTTP 或 WebSocket，必须以源码为准。
- 修改代码后必须给出编译命令和测试命令。
- 讲解时尽量结合用户已有基础：CSAPP、C++、Linux、GDB、CMake。
- 用户更需要“能学会”的解释，而不是只给一段最终代码。
