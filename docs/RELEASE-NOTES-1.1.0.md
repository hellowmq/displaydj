# DisplayDJ Full 1.1.0

2026-10-29 · [下载 ZIP / DMG 与 SHA-256](https://github.com/hellowmq/displaydj/releases/tag/v1.1.0)

修复部分外屏无法读取 DDC 亮度的问题，新增本地诊断导出，并改进唤醒、屏幕插拔与多个控制入口之间的恢复协调。

- **DDC 查询修复**：IOAV 适配器保留正确的 Get VCP 校验字节，不再漏算源地址。继续检查实际回复的源地址、长度、校验和与目标 VCP，不将无效回复或 Gamma 当作硬件成功。
- **本地诊断导出**：在操作偏好中导出 JSON 与文本报告，默认隐藏 UUID、序列号、用户名、本机路径和原始错误内容；只读采集，由用户选择保存位置，不自动上传。
- **唤醒与拓扑更新**：作废过期读数和操作意图，保持操作绑定原稳定目标，避免较晚完成的请求覆盖新状态。
- **连接恢复协调**：同一用户下，新版 Full、Lite 和 CLI 串行核对完整连接事务，旧恢复责任不覆盖更新的意图。旧版本不参与该协议；Full/Lite 仍分别保存恢复记录。

完整自动测试 773 项通过。Apple M1 / macOS 27.2 / H27T22S（DP→DP）上，已安装 Full 与 Lite 分别经真实界面调节 **0% → 5% → 0%**，每步通过独立 DDC 命令回读；同源 Release CLI 另完成 0% → 3% → 0% 验证。其他设备与待验范围见[发布验证记录](RELEASE-2026-10-29.md)。

**Apple Silicon arm64；macOS 13 为部署目标；ad-hoc 签名，未经 Developer ID 签名或 Apple 公证。** 最低系统与全型号兼容不由当前单机结果推定。提供独立 ZIP、DMG 及各自 SHA-256。

升级前恢复当前外屏并正常退出旧 Full/Lite，再覆盖对应 App；配置、预设与恢复记录沿用原目录。独立复制到 PATH 的 CLI 也需更新；可选后台服务与 App 使用同一版本。替换 ad-hoc App 后，系统可能需要重新确认全局键盘控制的辅助功能授权。不要删除恢复记录来绕过失败。

## English

Fixes the Apple Silicon IOAV Get VCP checksum, adds redacted local diagnostic export, and improves stale-request invalidation and cross-process display-connection recovery coordination. Both installed apps passed real H27T22S hardware brightness adjustment and restoration with independent DDC readback. Older versions do not participate in the new connection protocol. 773 automated tests passed; see the validation notes for device-specific limits. **arm64, ad-hoc signed, not notarized; macOS 13 deployment target.** Restore and quit before upgrading. Previous releases remain available for rollback.
