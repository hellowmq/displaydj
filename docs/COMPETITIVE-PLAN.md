# DisplayDJ 追赶计划：桌面控制 + 独立 CLI

研究日期：2026-09-21。基线为 `master` 的 `cd3b7a2`；本文“本次实现”指 v0.3.0 预览版的新增代码。构建和模拟测试通过不等于显示器实测通过。

## 方向与范围

先补齐日常显示器控制和自动化共用的内核，再补交互体验，最后推进依赖私有系统接口的显示技术。CLI 是独立产品入口：显示器发现、硬件操作、预设和系统模式在没有菜单栏 App 时也能使用；Gamma、长期租约与 Agent 生命周期需要常驻服务。所有新功能先定义服务与机器输出，再接 CLI、HTTP、GUI，避免形成三套不同逻辑。

与竞品相比，差距不仅是按钮数量，还包括协议覆盖、恢复机制、硬件兼容矩阵和可信分发。现有项目的优势是已具备 Agent 阶段、心跳、租约和恢复流程；应保留这些能力，并让普通脚本使用同样的稳定接口。

## 研究依据与复用边界

- [MonitorControl README](https://github.com/MonitorControl/MonitorControl#readme)：日常亮度、音量、对比度，多种调光方式、键盘控制、同步与 OSD。以其桌面体验作为近期基准。
- [MonitorControl License](https://github.com/MonitorControl/MonitorControl/blob/main/License.txt)：MIT；本项目已有派生关系与署名，见 [PROVENANCE.md](PROVENANCE.md)。未来引用代码必须保留来源、对应 commit 和许可。
- [MonitorControl Command.swift](https://github.com/MonitorControl/MonitorControl/blob/main/MonitorControl/Enums/Command.swift)：核查连续控制的 VCP 常量，contrast `0x12`、audioSpeakerVolume `0x62`。本次复用本仓库执行器，没有复制其应用代码。
- [BetterDisplay 官方功能比较](https://github.com/waydabber/BetterDisplay/wiki/List-of-free-and-Pro-features)：功能范围包括显示模式、缩放、虚拟屏、HDR、颜色和视频处理；对比页由竞品作者维护，应结合各项目官方说明理解。
- [BetterDisplay 仓库](https://github.com/waydabber/BetterDisplay)和 [CLI 文档](https://github.com/waydabber/BetterDisplay/wiki/Integration-features,-CLI)：作为功能与交互参考，不把公开分发仓库当成全部商业产品代码可复用的授权。
- [betterdisplaycli](https://github.com/waydabber/betterdisplaycli)：客户端开源不等于整个 BetterDisplay 引擎开源。我们继续使用自己的本地执行器，不新增对 BetterDisplay App 的运行依赖。
- [Apple CoreGraphics 模式设置](https://developer.apple.com/documentation/coregraphics/cgconfiguredisplaywithdisplaymode(_:_:_:_:))：一期使用系统公开枚举出来的模式，不能声称能够创建任意 HiDPI 分辨率。

## 差距矩阵

“待做”是明确未交付项，不能在 README、UI 或发布说明中写成已支持。

| 能力 | 竞品基准 | 项目基线与本次变化 | 下一步 |
| --- | --- | --- | --- |
| 外屏亮度、内建背光 | 两者都有 | 基线已有 DDC、DisplayServices；App 与 README 已说明内建屏支持 | 扩硬件实测 |
| 外屏音量、对比度 | 两者都有 | **本次新增**共享 DDC 连续控制、CLI/API、GUI 读取和步进 | 验证有扬声器/无扬声器、非 100 最大值、失败恢复 |
| 输入源、静音、关机 | BetterDisplay 控制面更广 | **待做**；不能套用连续百分比模型 | 建立离散 VCP、能力枚举和链路失联语义 |
| 软件与混合调光 | 两者支持多种途径 | 基线 CLI/HTTP 有 Gamma；GUI 显式选择和混合曲线**待做** | 驻留、颜色表恢复、明确 transport、硬件最低值衔接 |
| 媒体键、OSD、亮度同步 | MonitorControl 的成熟日常体验 | 基线滚轮和可选自定义快捷键；媒体键、OSD、持续同步**待做** | 增量同步、反馈环隔离、用户优先级 |
| 分辨率、刷新率、HiDPI 模式 | BetterDisplay | **本次新增**已有模式枚举、像素尺寸与 HiDPI 标记、设置、回读与失败恢复、CLI/API/GUI | 同时保存多个屏幕的模式与布局 |
| 任意缩放、虚拟屏、EDID | BetterDisplay | **待做**；现有模式枚举不等同于这些功能 | 独立 macOS 版本兼容模块和实验门槛 |
| 布局、主屏、镜像、旋转 | BetterDisplay | 仅现有断开/重连；其余**待做** | 原子拓扑计划、确认与自动回退 |
| 预设与自动化 | 常用桌面需求 | **本次新增**命名亮度预设，UUID + transport，跨进程存储锁，全量预检、dry-run、失败回退 | 扩展到音量/模式/布局，再做事件触发 |
| HDR/XDR、颜色、LUT、PIP | BetterDisplay 专项能力 | **待做** | 需求验证后分模块立项，不能承诺所有面板通用 |
| CLI/HTTP/脚本 | BetterDisplay 有丰富集成 | 基线已有独立 CLI、API、Agent/租约；**本次扩展**三类控制与严格新命令参数 | versioned schema、completion、NDJSON watch、幂等操作 ID |
| 硬件覆盖、分发 | 两者较成熟 | Apple Silicon DDC；Intel DDC、完整验证矩阵、Developer ID 签名/公证**待做** | 先取得真实成功链路，后扩大平台 |

## 已落实的第一批代码

1. `AppleSiliconDDCControl` 只开放 contrast 和 volume。读写依旧经过稳定身份、拓扑检查、进程锁、基线读取、最大值换算、回读验证和失败恢复。相对增量在同一锁内按当时基线计算；不支持或失败作为逐显示器结果保留。
2. `DisplayModeService` 列出逻辑尺寸、物理像素、刷新率、当前模式、是否适合桌面和 HiDPI 标记。设置只接受当前候选 ID 与单个稳定目标，使用 session 范围 CoreGraphics transaction；回读不符尝试恢复旧模式。`--dry-run` 只读。mode ID 不能跨重启持久化，0 Hz 表示未知固定刷新率。
3. `DisplayProfileStore/Service` 使用独立 `profiles.json`，避免覆盖临时 Agent 恢复点。文件锁覆盖读改写；损坏文件报错并保留，不静默重建。保存不写硬件；同名预设要显式 `--replace`。应用先检查所有显示器、控制方式和亮度基线，任一失败则零写入；执行中失败对已尝试目标逆序恢复并报告结果。Gamma 实际应用要求 daemon。
4. 新命令有相同 JSON envelope、明确选择器、非零失败退出码和只读预演；拒绝未知/重复参数、遗漏值、无效整数、额外位置参数和不适用的预演标志。旧 `displaydj` 参数和 JSON 保持兼容。
5. 菜单栏打开独立“显示设置与预设”窗口，复用打包 CLI，所以默认走正在运行的 daemon，错误和预检与脚本一致。基础亮度卡片仍沿用原控制器。
6. 关联可靠性修复：精确名称/UUID 重名不再取第一块屏，空选择器拒绝；亮度读取失败不再从批量结果中消失，缺少基线时停止写入，缺少回读时不以请求值冒充结果。

## 后续执行顺序与验收门槛

以下工作量是规划估算，以一位熟悉 macOS 的开发者、已有可用测试设备为前提；不是已排期承诺。硬件不具备时开发完成与验收完成分开记录。

| 阶段 | 工作包 | 依赖 / 粗估 | 验收出口 |
| --- | --- | --- | --- |
| P0：本次 | 上述共享控制、模式、亮度预设、CLI/API/GUI | 已实现，本地验证见 VALIDATION | 单元回归、真实只读枚举、预演零写、隔离 API 通过；物理写入仍待硬件 |
| P1a：可靠控制 | snapshot 保存 transport 和所有者；统一服务仲裁；暂停 Agent；状态事务串行化；用户修改优先 | 3–5 人日 | Agent 恢复不会覆盖后来的人类调整；断电/重启恢复不跨 transport |
| P1b：调光体验 | 每屏显式 Gamma 设置、恢复颜色表、低亮度混合曲线；内建屏与外屏操作一致 | 3–5 人日，依赖 P1a | 选择可见、驻留退出可恢复、睡眠唤醒可重建、截图/颜色影响可解释 |
| P1c：键盘与同步 | 媒体键、OSD、单源同步、多屏组合、亮度上下限 | 3–5 人日，可与 P1a 研究并行 | 不抢系统音量目标、不产生同步反馈环、权限撤销后降级明确 |
| P2a：桌面配置 | 模式特征持久化，排列/主屏/旋转/镜像，预设扩展；倒计时自动回退 | 5–8 人日，依赖可靠状态层 | 插拔和 mode ID 变化后仍解析正确；屏幕不可见时自动退回 |
| P2b：协议扩展 | 能力字符串探测、离散 VCP、输入源和静音；Intel 适配；设备 quirks | 5–10 人日 + 测试设备 | 不把发送成功标为生效；输入切换导致失联单独报告；每种链路有证据 |
| P2c：自动化接口 | machine schema、shell completion、事件 watch、请求 ID/幂等；预设事件触发 | 3–5 人日 | stdout 可解析、stderr 日志、可取消；旧客户端兼容；重复请求不重复调硬件 |
| P3：高级显示 | 虚拟屏/HiDPI、HDR/XDR、颜色 profile/LUT、视频能力各自模块化 | 每项另作 1–2 周研究后估算 | macOS/芯片/设备分层验证；未验证接口默认实验性，不捆绑基础 CLI |
| 分发轨道 | Intel + arm64 CI、签名、公证、安装/卸载、升级回滚 | P1 后 2–4 人日，需证书配置 | 发布 SHA、包签名、下载、首次启动和卸载均验证 |

最快下一步应是 **P1a + 一条可成功读写的 DDC 实测链路**，然后做 P1b/P1c。现有 Dell 的历史 Get VCP 失败记录见 [HARDWARE.md](HARDWARE.md)，新增控制代码不会自动修好线材/协议链路。先验证一个清楚的设备范围，再扩大支持承诺。

## CLI 必须保留的产品契约

- 无 GUI 也能执行硬件控制、显示模式与预设管理；驻留能力显式依赖 `serve`。
- selector 持久化使用 UUID；名称歧义失败，索引和 mode ID 只用于当前会话。
- 新写命令支持审阅目标的 `--dry-run`，明确覆盖范围；已有不支持的命令必须拒绝该标志，不能边声称预演边执行。
- 批量结果逐屏可见；CLI 任一屏失败退出 1。HTTP 外层成功仅表示请求被处理，调用方还要检查 `results[].ok` / profile 的 `data.ok`。
- 不把传输可用当作某 VCP 已支持，不把请求值当作硬件回读。
- 输入切换、关机、拓扑调整需各自的恢复语义，不对未知 VCP 开放任意写。
- 当前跨进程 DDC 锁不等于全产品事务；预设回退是 best effort，不承诺跨屏原子性、SIGKILL 恢复或用户意图仲裁。

## 回归与发布清单

- 每个服务提供可注入读取/写入，覆盖正常、离线、歧义、失败、读回不符和恢复失败。
- CLI 子进程验证 stdout JSON、退出码、错参数、模式预演、预设存取和 daemon 路由。
- 新 API 继续受原 Bearer token 鉴权；隔离 `DISPLAYDJ_HOME`，不修改用户配置和会话。
- GUI 验证实际窗口、长模式列表、错误状态、键盘/辅助功能和重开窗口。本次自动 UI 工具不可用时，明确留下视觉验收缺口。
- 物理写入验收必须先取得可读基线，再小幅调整、独立回读、恢复并再次回读；不将模拟设备测试写成实机成功。
- v0.3.0 作为预览版发布；完成硬件矩阵、Developer ID 签名和公证后再提供正式分发承诺。
