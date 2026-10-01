# 验收记录

## 2026-10-02：1.0.1 发布验收

本轮源码加入逐屏控制权、跨进程协调及 CLI 跳过原因；`swift test` 通过 **651 项**。内建屏真实写入与独立回读验证手动接管、会话结束、daemon 退出和显式恢复，结束时回到原始亮度。外屏 DDC 和本轮 GUI 人工操作未验收。行为及完整边界见 [MANUAL-BRIGHTNESS-PRIORITY.md](MANUAL-BRIGHTNESS-PRIORITY.md)。

最终源码再次通过完整测试和隔离烟雾测试，release App 构建及严格签名校验通过。本轮还加入 DDC 控件可用性显示和系统减少动态效果支持；UI 人工操作尚未验收。发布范围为 arm64、ad-hoc 签名、未公证，详见 [1.0.1 发布说明](RELEASE-NOTES-1.0.1.md)。

## 2026-09-28：v1.0.0 发布验收

本节对应 `v1.0.0` 源码、由该版本构建的 GitHub Release，以及开发机上的最终安装验收。本机为 arm64、macOS 27.0；最低 macOS 13 的目标和 Intel 未做安装或硬件验收。发布包采用 ad-hoc 签名且未公证，不声称可无提示安装。真实设备详情及私有日志索引见 [DEVICE-VALIDATION.md](DEVICE-VALIDATION.md)，发版门槛见 [RELEASE-1.0-CHECKLIST.md](RELEASE-1.0-CHECKLIST.md)。

| 项目 | 本地证据与边界 |
| --- | --- |
| 自动化 | 最终源码运行 `swift test` 通过 **626 项**：Server 47、Vibe Core 113、DDC Core 196、兼容 CLI 9、App 257、新主 CLI 守护协议 4；`python3 -B scripts/smoke.py`、release 构建与 `git diff --check` 通过，烟雾测试不请求硬件写入 |
| Release 构建 | 从 `v1.0.0` 源码生成 arm64 ZIP、DMG 及各自 SHA-256；ZIP 中两个 CLI、Info.plist、架构、文件内容与本地 App 一致，DMG 可验证并挂载读取。签名是 ad-hoc，未公证；发布页明确记录首次打开和辅助功能重新授权边界 |
| HP 当前连接 | DDC 亮度和对比度小幅写入、独立回读、恢复通过；音量 VCP 不支持。HP Gamma 色表单独读回 97%，DDC 背光保持 56% |
| 双屏 | 内建屏原生背光与 HP DDC 亮度分别调节，中文名称预设跨屏应用后均回到基线；后续用户操作的 GUI 日志显示同步手势逐屏写入并回读确认 95%、26%、100%，结束时两屏均回到测试前 100%。尚无单屏写入失败的 GUI 证据或独立肉眼观感记录 |
| 模式守护 | HP 上守护 CLI 的 keep、stdin 关闭、15 秒超时与控制进程异常退出模拟均完成真实模式回读与恢复；后续用户 GUI 操作的守护日志显示一次明确保留和一次超时恢复，最终回到所保留的模式，而非测试前模式。设置窗口倒计时的肉眼效果未记录 |
| GUI 与安装 | 已备份原 0.3.0 安装版并安装 1.0.0 至 `/Applications/DisplayDJ.app`；App 与 daemon 运行路径均来自新 bundle。用户 GUI 操作日志覆盖双屏同步和模式确认；用户还完成了辅助功能的干净重置、当前 App 授权、重启及全局快捷键实测。Computer Use 对 App 仍返回 `AXError.cannotComplete`，干净用户首装和真实睡眠唤醒仍待验收 |

本次 1.0.0 是范围受限的开源直发版本。构建机没有有效 Developer ID 身份，因此发布包不会取得 Gatekeeper 的公证信任；最低系统版本、Intel 和更广硬件矩阵仍缺少证据，不能从版本号推断这些能力。

## 2026-09-21：v0.3.0 预览版本地验收

本版包含共享 DDC 对比度/音量、显示模式、亮度预设，以及唤醒后亮度未确认时的等待状态。下表记录本机验证结果。提交 `35d088d` 对应的 [GitHub Actions](https://github.com/hellowmq/displaydj/actions/runs/35617044147) 已通过；[v0.3.0 Release](https://github.com/hellowmq/displaydj/releases/tag/v0.3.0) 已发布为预览版，提供 arm64 ZIP 与 SHA-256 文件。远端构建通过不代表新增硬件写入已完成实机验收。

| 项目 | 结果与边界 |
| --- | --- |
| 自动化测试 | `swift test` 通过 **594 项**：Vibe Core 105、Server 47、DDC Core 190、兼容 CLI 9、App 243；XCTest 152 + Swift Testing 442 |
| CLI/API 烟雾测试 | `python3 scripts/smoke.py` 通过；使用隔离状态目录，覆盖 0.3.0 版本、严格参数、只读模式预演、离线预设、HTTP 鉴权、daemon 清理；没有请求硬件写入 |
| Release 包 | `bash scripts/package.sh` 通过，生成 arm64 ZIP 与 SHA-256；校验文件读回通过，App 严格签名校验通过。签名仅为 ad-hoc，未经过 Developer ID 签名或公证 |
| 本机安装 | `/Applications/DisplayDJ.app` 已更新到 0.3.0；运行进程来自该路径，主程序与构建包逐字节一致 |
| 菜单栏唤醒状态 | 用户已看到灰色等待态；自动测试覆盖首次读取失败不报错、后续恢复、重复失败显示重试和唤醒时清除旧读数。完整合盖/唤醒设备矩阵未完成 |
| 新显示设置窗口 | 源码、构建和注入后端测试通过；完整 GUI 视觉与交互验收未完成 |
| 新硬件写入 | 对比度、音量、模式切换及多屏回退尚无真实设备写入/恢复证据；不得据此声称设备兼容 |
| 平台与分发 | 本机 arm64；Intel、双架构、Developer ID 签名、公证和无提示安装仍未验证 |

本机测试日志位于 `/tmp/displaydj-030-test.log`，隔离烟雾测试和发布包校验于本轮命令执行。

## 2026-09-21：v0.3.0 开发阶段记录（历史快照）

此处记录发布前的开发快照：基线 `cd3b7a2`，记录时改动尚未提交、推送或发布，版本号仍为 `0.2.3`。新增实现范围见 [COMPETITIVE-PLAN.md](COMPETITIVE-PLAN.md)。

| 项目 | 结果与边界 |
| --- | --- |
| 构建与自动化测试 | `swift test` 通过 **591 项**：Vibe Core 104、Server 47、DDC Core 190、兼容 CLI 9、App 241；XCTest 151 + Swift Testing 440，不重复计数 |
| 新功能单元测试 | 15 项新增测试：VCP 选择与相对最大值换算、DDC 写失败恢复、模式预演/写回/恢复、预设存储与覆盖保护、损坏文件保留、离线/transport 变化预检、多屏逆序回退、精确选择器歧义、HTTP 参数与预演 |
| 扩展 CLI/API 烟雾测试 | `python3 scripts/smoke.py` 通过；非法参数和 dry-run 误用拒绝、实际模式列表与当前模式预演、隔离离线预设存取、认证、daemon 路由、SIGTERM 清理 |
| 当前只读硬件发现 | 本轮枚举到一块 1440×900、60 Hz 显示器，8 个候选模式；`contrast/volume get --display external` 均以 `display_not_found` / 退出 3 明确失败，没有可用外屏可做新 DDC 验收 |
| App 打包与启动 | `./script/build_and_run.sh --tools` 成功；包含主 CLI/兼容 CLI，ad-hoc 签名严格验证通过，已确认本工作区 App 进程存在 |
| GUI 视觉与交互 | **未完成**。Computer Use 对完整 App 路径两次返回 `Sky Computer Use native pipe closed before response`；Bundle ID 重试因安装版与工作区版共用 ID 而有歧义。不能把启动证明当成视觉验收 |
| 物理写入与恢复 | **未运行**。没有发送改变亮度/对比度/音量的命令，没有切换显示模式；预演只读。新 VCP 写入、实际模式切换与多屏恢复仅有注入后端测试证据 |
| 差异检查 | `git diff --check` 通过 |
| 分发 | 没有运行本轮 release 打包、远端 CI、签名公证或发布流程；下面的历史 Release 构建不覆盖本轮新代码 |

本机详细日志位于 git 忽略的 `outputs/catch-up-2026-09-21/`。历史 Dell 记录属于另一轮探测，不能用来声称这次已有可写外屏。

## 历史：v0.2.x 整合版记录

日期：2026-09-21。环境：本机 macOS / Apple Silicon，Apple Swift 6.4。以下是当时运行所得，不沿用压缩包 README 中的历史结果。

| 项目 | 结果 | 证据 / 范围 |
| --- | --- | --- |
| Debug 构建 | 通过 | `swift build`，主 CLI、兼容 CLI、App 和库 |
| 自动化测试 | 通过，576 项 | `swift test`：Vibe Core 93、Server 45、DisplayDJ Core 188、兼容 CLI 9、App 241 |
| 新增整合测试 | 通过 | 规范 UUID、非法目标不触达硬件、未验证写入失败、MainActor 桥接、非有限输入、离线与 panic 快照保留、硬件锁串行与异常释放 |
| 主 CLI 烟雾测试 | 通过 | version、help、错误 envelope / 退出码、只读显示器枚举与诊断 |
| 本地 HTTP | 通过 | 独立临时状态目录，拒绝无令牌请求，health / displays / sessions，SIGTERM 清理描述文件 |
| HTTP 参数保护 | 通过 | 拒绝非 loopback host、负数端口和溢出端口 |
| Release 构建与 ZIP | 通过 | `bash scripts/package.sh`，arm64 架构，附 SHA-256 |
| App 签名检查 | 通过 | `codesign --verify --deep --strict`，仅 ad-hoc 签名 |
| App 启动 | 此前整合版进程已启动后清理 | 改名后的 App 尚未进行可视验收 |
| App 可视验收 | 未完成 | Computer Use 两次返回 `timeoutReached`，未取得可用界面状态或截图 |
| 真实亮度写入 / 恢复 | 未运行 | 本次只读探测，未对用户显示器发出调光操作 |
| 真实断开 / 重连 | 未运行 | 未改变显示拓扑 |
| Intel / 双架构 | 未验证 | 本次仅 arm64 构建 |
| GitHub CI | 当时已配置 | `macos-15` 执行构建、576 项测试、隔离烟雾测试和 App bundle 构建；此前的兼容 CLI 并发编译失败已在本次修复 |
| GitHub Release | 当时未发布 | 仓库已有 `v0.2.0` Git tag；本行只记录该阶段，不代表当前 Release 状态 |
| Developer ID / 公证 | 未完成 | 没有声称已公证或可无提示分发 |

测试包含两种框架：XCTest 138 项，加 Swift Testing 438 项，共 576 项。测试日志中同一个 XCTest 汇总可能出现两遍，统计时未重复计数。

回归修复：原有 `testRestoreAllSeedsFromDiskAndClearsIt` 要求无条件丢弃未恢复快照，与新的可重试恢复契约冲突；已改为验证离线显示器的快照保留，并新增跨重载及 panic 的保留断言。

硬件探测结论只代表此机器在运行时能返回发现与诊断信息，不构成某型号显示器的写入兼容性认证。

当时项目版本为 `0.2.3`。Dell 身份兼容修复与真实读取的失败边界见[硬件检查](HARDWARE.md)；源项目 Git 历史未导入，来源与许可证据见[来源与许可](PROVENANCE.md)。
