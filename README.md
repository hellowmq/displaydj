<div align="center">

# DisplayDJ

**用菜单栏控制显示器，也可单独使用命令行自动化。**

A macOS menu bar app, command-line tool, and local API for display control and agent workflows.

[![macOS checks](https://github.com/hellowmq/displaydj/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/hellowmq/displaydj/actions/workflows/ci.yml)

`v0.3.0 preview` · `macOS 13+` · `Swift 6` · `Apple Silicon DDC/CI` · `MIT`

</div>

DisplayDJ 将 **DisplayDJ 的菜单栏与外屏硬件引擎**，和 **VibeDisplay 的 CLI、HTTP、保活租约、Agent 生命周期**合并为一个 Swift Package。外屏亮度读写共用同一套实现，并通过进程间锁协调 App、CLI 与后台服务。

当前版本为 `0.3.0` 预览版，由 [`master`](https://github.com/hellowmq/displaydj/tree/master) 统一维护 App、CLI、硬件内核、服务和版本。GitHub Actions 负责构建与测试；发布包为本机 arm64 的 ad-hoc 签名 ZIP，尚未经过 Developer ID 签名和 Apple 公证。当前验证结果与限制见[验收记录](docs/VALIDATION.md)。

<p align="center">
  <img src="Assets/DisplayDJIcon.svg" alt="DisplayDJ：开放圆角控制通道、固定缺口与横向 fader" width="160">
</p>

DisplayDJ 的视觉锚点是 **Rounded Channel + Signature Gap + Fader**：辨识度来自开放轮廓和固定缺口，而不是复杂的内部隐喻。完整规则见[品牌系统](docs/BRAND.md)。

## 使用方式

| 入口 | 适合谁 | 已实现能力 |
| --- | --- | --- |
| **DisplayDJ.app** | 日常桌面操作 | 亮度卡片、滚轮、可选快捷键、别名与排序、断开/重连；工作区新增模式、音量/对比度与预设窗口 |
| **display-cli** | 终端、脚本、编程 Agent | 显示器发现、亮度、恢复、断开/重连、保活、任务阶段、诊断、服务管理；无需启动 App 或后台服务 |
| **可选本地服务** | 需要 HTTP 接入或跨命令持续状态的自动化 | Bearer token 鉴权、Gamma、保活租约、会话与心跳；通过 CLI 启停 |

另保留 `displaydj` 兼容命令，原有 `get brightness` / `set brightness` 脚本可以继续使用。它保留旧 JSON schema 与退出码，不与新 CLI 的契约混用。

## 正在追赶的能力

v0.3.0 预览版新增 **外屏对比度/音量、分辨率与刷新率模式、命名亮度预设**，均接入主 CLI 与 HTTP；菜单栏可打开“显示设置与预设”窗口。新增写入支持 `--dry-run`，保留逐屏失败与恢复结果。详细范围、与 BetterDisplay / MonitorControl 的差距和下一阶段安排见[完整追赶计划](docs/COMPETITIVE-PLAN.md)。新硬件写入能力仍需实机验收，不代表已全面对齐竞品。

```bash
# 单独使用 CLI，不需要先打开菜单栏 App
.build/debug/display-cli volume get --display external --json
.build/debug/display-cli contrast set 60% --display uuid:<UUID> --dry-run --json
.build/debug/display-cli modes list --display main --json
.build/debug/display-cli modes set <MODE_ID> --display uuid:<UUID> --dry-run --json

# 保存当前亮度，预演后应用；Gamma 预设实际应用需要本地服务
.build/debug/display-cli profile save work
.build/debug/display-cli profile apply work --dry-run --json
.build/debug/display-cli profile apply work

# 构建并打开本地 App 的显示设置窗口
./script/build_and_run.sh --tools
```

## 开始使用

需要 macOS 13+、Swift 6.0+ 工具链和 Python 3（仅打包与烟雾测试）。首次构建需要获取 Apple 的 `swift-argument-parser`；主 CLI、硬件内核和 HTTP 层本身不使用该依赖。

### 菜单栏 App

```bash
swift build
bash scripts/build-app.sh
open '.build/DisplayDJ.app'
```

App 的亮度卡片支持外接 DDC 与内建屏原生背光；Gamma 软件调光仍通过主 CLI / HTTP 提供。App 不负责启动或管理自动化服务。

### 独立 CLI

运行 `swift build --product display-cli` 后即可单独使用 CLI，无需打开 App 或启动后台服务；也可以将可执行文件放入自己的 PATH 目录。App 包内同样包含 `Contents/MacOS/display-cli` 和兼容命令 `displaydj`。

```bash
.build/debug/display-cli doctor --json
.build/debug/display-cli displays --json

# 从 displays 输出复制目标 UUID；亮度值是 0…1 或显式百分比
.build/debug/display-cli brightness set 60% --display uuid:<UUID>
.build/debug/display-cli brightness set +5% --display uuid:<UUID>
.build/debug/display-cli brightness restore

# 只在一个命令运行期间保持唤醒
.build/debug/display-cli keepawake run -- make test

# 把开始、运行、完成与恢复交给任务生命周期
# 默认配置会改变显示器亮度，先检查 config show
.build/debug/display-cli config show
.build/debug/display-cli agent run --label 'test suite' -- make test
```

### 可选后台服务

普通 CLI 操作不需要服务。HTTP 接入、命令退出后仍需保持的 Gamma 调光与租约、以及跨命令管理 Agent 会话时，再启动本地服务。服务由 CLI 管理，结束时也可用 CLI 停止；只有明确需要登录后自动启动时才安装登录项。

```bash
.build/debug/display-cli serve --detach
.build/debug/display-cli daemon status
.build/debug/display-cli daemon stop

# 可选：登录后自动启动；关闭自动启动请运行 daemon uninstall
.build/debug/display-cli daemon install
.build/debug/display-cli daemon uninstall
```

## 共享架构

```mermaid
flowchart LR
    App[菜单栏 App] --> DDC[DisplayDJCore\n身份匹配 / DDC 验证 / 进程间锁]
    CLI[display-cli CLI] --> Core[VibeDisplayCore\n亮度 / 快照 / 租约 / Agent 会话]
    HTTP[本地 HTTP API] --> Core
    Core --> DDC
    Core --> Native[内建屏 DisplayServices]
    Core --> Gamma[软件 Gamma]
    Legacy[displaydj 兼容 CLI] --> DDC
```

菜单栏适合直接操作；CLI 适合脚本。只有需要持续状态或 HTTP 接入时才运行后台服务；App 不会自动安装登录项或启动服务。若已通过 `daemon install` 安装登录项，`daemon stop` 后服务会重新启动；使用 `daemon uninstall` 关闭自动启动。

## 可以依赖什么

- **身份匹配**：DDC 使用 DisplayDJ 的服务与显示器身份关联，不再按两份枚举列表的位置配对。旧 `ddcServiceIndex` 配置会被拒绝，避免误控另一块屏幕。
- **写后验证**：DDC 写入前读取基线，写入后核验读回值；失败尝试恢复并报告结果，不用请求值冒充读回值。
- **跨进程协调**：App、主 CLI、兼容 CLI 的 DDC 操作共用本机用户锁。进程退出自动释放；等待超时返回 busy，不强行争用硬件。
- **恢复可重试**：成功恢复后才移除恢复点；断开的显示器或失败的恢复会保留快照。
- **本地接口**：HTTP 仅在 loopback 接口工作，默认要求令牌。配置与令牌默认在 `~/.displaydj/`。
- **断开保护**：拒绝批量断开、镜像屏断开和最后一块在线显示器断开。

恢复不等于绝对保证。SIGKILL 无法执行清理；快照可用于之后显式恢复。DDC/私有系统 API 可能卡住或因设备、线缆、macOS 版本变化而不可用。Gamma 是软件变暗，需要进程常驻，不能冒充硬件背光调节。

## 兼容范围

| 能力 | 当前边界 |
| --- | --- |
| Apple Silicon 外屏 DDC | 共用 DisplayDJ 读写实现；本次完成只读探测，未进行真实亮度写入验收 |
| 内建屏亮度 | 主 CLI / HTTP 的 DisplayServices 后端；本次未做真实写入验收 |
| Intel 外屏 DDC | 未实现生产读写路径；可能使用软件 Gamma |
| 显示器断开 / 重连 | 依赖私有 API；缺失时明确失败；本次未改变真实显示拓扑 |
| App 与 Agent 同时调光 | 硬件操作会串行，但 Agent 结束仍可能恢复之前的快照；没有“手动操作优先”的所有权仲裁 |
| 分发 | 本地架构 ZIP 与 SHA-256；尚未验证双架构、Developer ID 签名或公证 |

## 开发与打包

GitHub Actions 在 `macos-15` 上对每次 push 和 pull request 执行与本地相同的核心检查：

```bash
swift build
swift test
python3 scripts/smoke.py
bash scripts/build-app.sh

# 可选：生成本机架构、ad-hoc 签名的 ZIP
bash scripts/package.sh
```

测试覆盖两套原有测试及整合边界；烟雾测试使用独立状态目录，只读探测真实屏幕并验证服务鉴权与退出。`package.sh` 输出 `outputs/displaydj-<版本>-macos-<架构>.zip` 与校验和。它不上传 GitHub，也不修改 Applications。

- [CLI / HTTP 参考](docs/API.md)
- [Agent 接入](docs/AGENT-INTEGRATION.md)
- [架构与迁移](docs/ARCHITECTURE.md)
- [来源与许可](docs/PROVENANCE.md)
- [验证结果](docs/VALIDATION.md)
- [Dell 硬件检查](docs/HARDWARE.md)
- [后续里程碑](docs/ROADMAP.md)

## 许可与致谢

MIT，完整许可见 [LICENSE](LICENSE) 与 [LICENSES](LICENSES)。本项目的部分实现派生自 MonitorControl，因此保留 **MonitorControl Contributors** 的版权与许可声明。合并进 DisplayDJ 的 VibeDisplay 来源单独记录，不能将整个项目描述为“未派生自 MonitorControl”。

维护者 GitHub：[@hellowmq](https://github.com/hellowmq)。项目仓库：[hellowmq/displaydj](https://github.com/hellowmq/displaydj)。
