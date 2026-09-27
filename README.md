<div align="center">

# DisplayDJ

**用菜单栏控制显示器，也可单独使用命令行自动化。**

A macOS menu bar app, command-line tool, and local API for display control and agent workflows.

[![macOS checks](https://github.com/hellowmq/displaydj/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/hellowmq/displaydj/actions/workflows/ci.yml)

`v1.0.0` · `macOS 13+ target` · `Swift 6` · `Apple Silicon DDC/CI` · `MIT`

</div>

DisplayDJ 提供菜单栏、独立命令行和可选的本地 HTTP 接口，用于管理显示器亮度及自动化任务。App、CLI 与后台服务共用外屏控制内核，通过进程间锁协调 DDC 操作。

当前版本为 [v1.0.0](https://github.com/hellowmq/displaydj/releases/tag/v1.0.0)。下载包仅支持 macOS arm64，采用 ad-hoc 签名，尚未经过 Developer ID 签名和 Apple 公证；首次打开可能需要在 Finder 中按住 Control 点击 App 后选择“打开”，或在“系统设置 → 隐私与安全性”中确认打开。启用全局快捷键时还需允许辅助功能权限；授权后若未立即生效，请退出并重新打开 DisplayDJ。详见[验证记录](docs/VALIDATION.md)与[1.0 验收清单](docs/RELEASE-1.0-CHECKLIST.md)。

<p align="center">
  <img src="Assets/DisplayDJIcon.svg" alt="DisplayDJ 图标" width="160">
</p>

## 使用方式

| 入口 | 适合谁 | 已实现能力 |
| --- | --- | --- |
| **DisplayDJ.app** | 日常桌面操作 | 亮度卡片、滚轮、可选快捷键、别名与排序、断开/重连；显示设置窗口提供每屏 Gamma、模式、外屏音量/对比度、亮度预设与可选硬件亮度同步 |
| **display-cli** | 终端、脚本、编程 Agent | 显示器发现、亮度、恢复、断开/重连、保活、任务阶段、诊断、服务管理；无需启动 App 或后台服务 |
| **可选本地服务** | 需要 HTTP 接入或跨命令持续状态的自动化 | Bearer token 鉴权、Gamma、保活租约、会话与心跳；通过 CLI 启停 |

另保留 `displaydj` 兼容命令，原有 `get brightness` / `set brightness` 脚本可以继续使用。它保留旧 JSON schema 与退出码，不与新 CLI 的契约混用。

## 显示控制与预设

DisplayDJ 提供外屏对比度与音量、系统已有显示模式的选择，以及命名亮度预设。主 CLI 和 HTTP 均提供这些功能；菜单栏可打开“显示设置与预设”窗口。相关写入支持 `--dry-run` 预演。v1.0.0 在一台 HP D27k 的当前连接上完成 DDC 亮度、对比度的小幅写入、独立回读和恢复；这项结果不能推广到其他显示器或连接方式。

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

App 的亮度卡片支持外接 DDC 与内建屏原生背光。设置窗口还提供逐屏 Gamma 软件调光：打开窗口或切屏时自动读取，松开滑块即应用；服务未运行时需由用户点击“启用软件调光”。快捷键可选择已选中的显示器或鼠标所在显示器，多屏硬件亮度同步默认关闭。App 不会自动安装登录项。

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

普通 CLI 操作不需要服务。HTTP 接入、命令退出后仍需保持的 Gamma 调光与租约、以及跨命令管理 Agent 会话时，再启动本地服务。设置窗口也有显式启动按钮；结束时可用 CLI 停止。只有明确需要登录后自动启动时才安装登录项。

```bash
.build/debug/display-cli serve --detach
.build/debug/display-cli daemon status
.build/debug/display-cli daemon stop

# 可选：登录后自动启动；关闭自动启动请运行 daemon uninstall
.build/debug/display-cli daemon install
.build/debug/display-cli daemon uninstall
```

只有需要持续状态或 HTTP 接入时才运行后台服务；App 不会自动安装登录项或启动服务。若已通过 `daemon install` 安装登录项，`daemon stop` 后服务会重新启动；使用 `daemon uninstall` 关闭自动启动。模块关系与迁移说明见[架构文档](docs/ARCHITECTURE.md)。

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
| Apple Silicon 外屏 DDC | 共用 DisplayDJ 读写实现；v1.0.0 在 HP D27k 当前连接验证了亮度和对比度写入、回读与恢复；该屏音量不支持 DDC 调节 |
| 内建屏亮度 | 主 CLI / HTTP 的 DisplayServices 后端；v1.0.0 完成小幅写入、独立回读与恢复 |
| Intel 外屏 DDC | 未实现生产读写路径；可能使用软件 Gamma |
| macOS 13/14 | 构建目标从 13 起；v1.0.0 只在本机 macOS 27 实测，尚无最低版本的安装与硬件验收 |
| 显示器断开 / 重连 | 依赖私有 API；v1.0.0 在此前 Dell 当前连接上完成断开、重连与拓扑回读，其他设备尚无此证据 |
| App 与 Agent 同时调光 | 硬件操作会串行，但 Agent 结束仍可能恢复之前的快照；没有“手动操作优先”的所有权仲裁 |
| 分发 | arm64 ZIP、DMG 与 SHA-256；ad-hoc 签名且未公证，尚未验证双架构或 Developer ID 签名 |

## 开发与打包

GitHub Actions 在 `macos-15` 上对每次 push 和 pull request 执行与本地相同的核心检查：

```bash
swift build
swift test
python3 scripts/smoke.py
bash scripts/build-app.sh

# 可选：生成本机架构、ad-hoc 签名的 ZIP 或 DMG
bash scripts/package.sh
bash scripts/package-dmg.sh
```

测试覆盖两套原有测试及整合边界；烟雾测试使用独立状态目录，只读探测真实屏幕并验证服务鉴权与退出。`package.sh` 和 `package-dmg.sh` 默认输出 `outputs/displaydj-<版本>-macos-<架构>.*` 与校验和；已有同名文件时会拒绝覆盖，可设置 `DISPLAYDJ_OUTPUT_DIR` 选择新目录。它们不上传 GitHub，也不修改 Applications。

- [CLI / HTTP 参考](docs/API.md)
- [Agent 接入](docs/AGENT-INTEGRATION.md)
- [架构与迁移](docs/ARCHITECTURE.md)
- [来源与许可](docs/PROVENANCE.md)
- [验证结果](docs/VALIDATION.md)
- [1.0.0 发布说明](docs/RELEASE-NOTES-1.0.0.md)
- [1.0 验收清单](docs/RELEASE-1.0-CHECKLIST.md)
- [设备分阶段验证](docs/DEVICE-VALIDATION.md)
- [双屏界面验收步骤](docs/GUI-ACCEPTANCE-1.0.md)
- [Dell D2720DS 探测记录](docs/HARDWARE.md)
- [后续里程碑](docs/ROADMAP.md)

## 许可与致谢

MIT，完整许可见 [LICENSE](LICENSE) 与 [LICENSES](LICENSES)。部分实现派生自 MonitorControl，项目保留 **MonitorControl Contributors** 的版权与许可声明；各模块的来源见[来源与许可](docs/PROVENANCE.md)。

维护者 GitHub：[@hellowmq](https://github.com/hellowmq)。项目仓库：[hellowmq/displaydj](https://github.com/hellowmq/displaydj)。
