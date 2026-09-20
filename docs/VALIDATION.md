# 本次验收

日期：2026-09-21。环境：本机 macOS / Apple Silicon，Apple Swift 6.4。以下是本次运行所得，不沿用压缩包 README 中的历史结果。

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
| GitHub CI | 已配置，最新状态见 README 徽章 | `macos-15` 执行构建、576 项测试、隔离烟雾测试和 App bundle 构建；此前的兼容 CLI 并发编译失败已在本次修复 |
| GitHub Release | 未发布 | 仓库已有 `v0.2.0` Git tag，但没有据此声称存在正式 Release 或可分发安装包 |
| Developer ID / 公证 | 未完成 | 没有声称已公证或可无提示分发 |

测试包含两种框架：XCTest 138 项，加 Swift Testing 438 项，共 576 项。测试日志中同一个 XCTest 汇总可能出现两遍，统计时未重复计数。

回归修复：原有 `testRestoreAllSeedsFromDiskAndClearsIt` 要求无条件丢弃未恢复快照，与新的可重试恢复契约冲突；已改为验证离线显示器的快照保留，并新增跨重载及 panic 的保留断言。

硬件探测结论只代表此机器在运行时能返回发现与诊断信息，不构成某型号显示器的写入兼容性认证。

项目已更新到 `0.2.3`，品牌标记统一为 Rounded Channel + Signature Gap + Fader，普通亮度交互统一使用 Spectral Cyan。Dell 身份兼容修复与真实读取的失败边界见[硬件检查](HARDWARE.md)。仓库已公开在 `hellowmq/displaydj`，默认分支为 `master`；源项目 Git 历史未导入，来源与许可证据继续单独保留。
