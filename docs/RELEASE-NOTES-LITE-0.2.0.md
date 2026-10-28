# DisplayDJ Lite 0.2.0 — 预发布

2026-10-29 · [下载 ZIP / DMG 与 SHA-256](https://github.com/hellowmq/displaydj/releases/tag/lite-v0.2.0)

本版修复 DDC 硬件亮度查询，增加默认脱敏的本地诊断导出，并改善唤醒、插拔和恢复保护。Lite 继续提供基础亮度与外屏连接控制，保持独立 App、数据和恢复记录。

- 保留源地址参与的 Get VCP 校验字节；严格核验实际回复，失败不自动启用软件调光。
- 从帮助入口导出本地 JSON/文本诊断，不需要 Full、CLI 或后台服务，不自动上传。
- 唤醒和拓扑变化后作废旧读数及过期写入意图，合并刷新并进行有限重试。
- 与新版 Full/CLI 协调完整连接事务；恢复子进程只处理仍属于自身的恢复责任。旧版本不参与协议。
- 断开前确认恢复保护就绪；正常退出前恢复并核验，失败保留记录并取消退出。保留未接入历史屏幕记录，不按复用编号操作其他屏幕。

完整自动测试 773 项通过。已安装 Lite 在 Apple M1 / macOS 27.2 / H27T22S（DP→DP）上，经界面完成 **0% → 5% → 0%**，独立 DDC 命令确认调节与恢复。当前内核的 Dell 普通断开/重连、物理拔插和 Lite 主进程异常结束后的恢复另有本机记录；不宣称所有异常或所有设备都能自动恢复。详见[发布验证记录](RELEASE-2026-10-29.md)。

**预发布；Apple Silicon arm64；macOS 13 为部署目标；ad-hoc 签名、未经 Apple 公证。** 升级或卸载前先恢复当前外屏并正常退出，再覆盖 `/Applications/DisplayDJLite.app`，不要覆盖 Full。恢复文件位于 App 外，不随覆盖安装删除。见[恢复与卸载说明](LITE-RECOVERY.md)。

## English

Fixes hardware DDC query checksums, adds read-only redacted local diagnostics, and improves wake/topology refresh and recovery ownership coordination. The installed Lite app passed H27T22S hardware brightness adjustment and restoration with independent readback. The new connection protocol requires cooperating new versions. **Prerelease, arm64, ad-hoc signed, not notarized.** Restore and quit before replacing or uninstalling Lite; do not delete recovery records to bypass a failure. 773 automated tests passed; hardware support remains connection-specific.
