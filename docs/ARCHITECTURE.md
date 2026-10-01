# 架构与迁移

## 模块

- `DisplayDJCore`：显示器发现与稳定选择器、IOAV/DDC 编解码、验证与恢复、连接状态、用户偏好。保留原模块名便于追踪来源。
- `VibeDisplayCore`：内建亮度、Gamma、统一亮度服务、快照、保活租约、Agent 生命周期。DDCBackend 现在适配 DisplayDJCore，不再维护另一套 IOAV 传输。
- `VibeDisplayServer`：Network.framework HTTP 服务、路由、鉴权、会话回收。
- `display-cli`：主 CLI，保持 VibeDisplay 的 JSON envelope 与退出码。
- `DisplayDJBar`：App 的内部 target 名；可执行文件名是 DisplayDJBar（避免与兼容 CLI `displaydj` 在大小写不敏感磁盘上冲突），App 显示名为 DisplayDJ。
- `DisplayDJCLI`：兼容入口 `displaydj`，保持原参数与错误契约。

Swift 6 严格并发模式用于 DisplayDJ 来源模块。VibeDisplay 来源模块暂用 Swift 5 语言模式构建，避免把整合与全面并发迁移混为一次改动；工具链最低为 Swift 6。

## 同步与异步边界

DisplayDJ 的生产硬件接口为 async，旧 VibeDisplay 服务为同步。`SynchronousTask` 使用独立任务运行 async 操作；主线程等待时保持 RunLoop 运转，供 AppKit 发现显示器。后台线程使用 semaphore 等待。适配层不伪造超时成功，也不会在写任务继续运行时提前返回失败。真实 IOAV 硬超时应由进程隔离实现，目前仍是限制。

DDC 公共读写入口获得 `HardwareProcessLock`，覆盖整个读或写事务。锁位于当前用户临时目录，所有产品使用相同文件，等待最多五秒；系统在进程死亡时释放锁。内核中的 actor lane 继续约束单进程内的传输步骤。

## 数据和兼容性

- 新产品使用 `~/.displaydj` 配置、token、daemon descriptor 和 state；可用 `DISPLAYDJ_HOME` 隔离。不会自动读取旧 `~/.vibe-display` 状态或迁移旧登录项。
- 保留 DisplayDJ 原来的偏好与断开记录位置，以沿用别名、排序和重连数据。
- 新 App 使用 `io.github.hellowmq.displaydj` bundle ID；辅助功能授权可能需要用户重新授予，默认不开启。
- 主 CLI 使用 `uuid:<UUID>`；内部 DDC 适配统一成小写规范 UUID。合成的 VMS 标识不作为可写 DDC 目标。
- 已取消按枚举序号配置的 DDC 配对。服务遇到 `ddcServiceIndex` 时会报错，请移除旧配置。
- doctor 的旧 `ddcPairing` / `externalAVServiceCount` 字段由 `ddcEngine` 取代；其余 CLI 和 HTTP 仍沿用 v1。旧契约调用方应更新字段读取。

## 恢复与并发限制

当前源码的 `BrightnessCoordinator` 在 DDC 传输锁之上使用状态目录中的 `state.json.brightness-lock`，覆盖亮度写入、独立回读和恢复决策。菜单栏和兼容 CLI 仍可直接调用硬件内核，在同一个协调锁下先持久化手动接管；主 CLI、HTTP、预设和 Agent 复用相同规则，无需强制启动 daemon。进程退出释放锁，锁竞争最多等待五秒。统一锁是有界的串行控制，不承诺跨屏原子事务。

`PersistedState.brightnessRevisions` 以规范化 UUID 保存控制版本；`brightnessSnapshotOwnership` 把恢复点绑定到版本和首次捕获它的会话，手动撤销点的 sessionID 为 nil。Agent 会话的 `brightnessRevisions` 只在 begin 捕获。手动写入在触碰硬件前更新版本并退役旧 Agent 恢复点，已有会话不能在下一阶段重新取得权限。直接主 CLI/HTTP 写入可保留本轮手动撤销点，自动退出清理只恢复属于自动化的有效恢复点。恢复判断始终重读磁盘，不使用 daemon 缓存或旧进程内快照复活已被接管的状态。

Agent 生命周期操作另用 `state.json.brightness-lock.sessions` 串行化，锁顺序为会话 → 亮度 → state 文件锁／DDC 锁。重叠会话在同一控制版本共享原始恢复点；还有活动会话时跳过恢复。预设将完整预检、逐屏写入和失败回退放在亮度协调锁内，避免回退覆盖途中插入的手动写入。写入获得锁后重新解析在线 UUID，原生屏使用新鲜 runtime ID。

恢复成功才删除仍有效的快照，离线或失败恢复点保留。手动接管属于明确退役旧恢复点的动作。SIGKILL、断电、损坏文件和硬件失联不能保证即时恢复。旧快照缺少所有权时只允许显式恢复，旧会话缺少控制声明时不自动调光。新客户端拒绝与活着的旧版本服务并行写入；旧版 App/CLI 本身不认识此规则，应一并更新。同一状态目录之外、系统设置、实体按键及其他应用的变更不在接管检测范围内。

Gamma 与 DisplayServices 不受 DDC 硬件锁覆盖。内建显示器已经通过 DisplayBrightnessAccess 接入菜单栏卡片；Gamma 尚未接入基础卡片。

## 产品命名与来源边界

应用 DisplayDJ、主命令 display-cli、仓库 displaydj；兼容命令 displaydj 只用于旧脚本。三个可执行产品共享 `VibeVersion.current` 这一版本来源。当前仓库是独立 Git 历史，没有导入两个源项目的 `.git`；版权与代码来源记录仍须保留，详见[来源与许可](PROVENANCE.md)。

## v0.3.0 预览版显示工具扩展

`AppleSiliconDDCControl` 在既有读写编排中传入连续 VCP feature，复用身份、基线、进程锁与恢复。`MonitorControlService` 将同步 CLI/API 请求转到该内核，逐项返回失败；不会由亮度成功推断音量可用。

`DisplayModeService` 使用 CoreGraphics 的 session 配置事务；每次重读目标与候选，设置后确认身份和模式，失败尝试恢复。模式操作与多个独立进程之间尚无统一产品层仲裁，不应并行应用多个桌面配置。

`DisplayProfileStore` 的独立文件锁覆盖完整读改写，和旧 Agent `StateStore` 的并发限制不同。`DisplayProfileService` 将全量预检与逐屏执行分开，执行和回退前重新解析 UUID/transport。当前源码已将预设写入和回退接入亮度所有权协调；1.0.0 发布时尚无该仲裁。

`DisplayToolsView` 只负责交互，由它启动 App 内置主 CLI 子进程，沿用有 daemon 则路由 daemon 的策略。子进程在后台读取输出，不阻塞主线程，不以 shell 拼接参数。窗口由菜单栏控制器持有，关闭可再打开。原基础亮度卡片保留既有直接调用路径。
