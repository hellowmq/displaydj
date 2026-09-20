# Dell 硬件检查

2026-09-21，用户提供并授权检查的显示器：**DELL D2720DS**。Mac：**Apple M1**。本次代理负责只读识别、注册表证据和受约束兼容修复；主代理复核源码后独立重建、重新读取。

## 已确认

- 唯一外接 Dell 正常在线，2560×1440、60 Hz；稳定身份无歧义。
- 原服务匹配在本机失败，因为旧 M1 的节点名为裸 `dcpext`，代码只接受数字后缀。
- 同一代理的祖先包含 `dispext0:dcpav-service-epic:0`，framebuffer 端口 0 的完整厂商/产品/序列三元组与显示器身份匹配。
- 新兼容路径仅在 External、精确端点证据和完整 framebuffer 身份同时成立时接受裸 `dcpext`，保留原有数字解析、身份匹配和歧义拒绝。
- 修复后的只读亮度请求越过了身份关联，但 `IOAVServiceWriteI2C` 在发送 **Get VCP 请求**时返回 `-535740416` / `0xe0114000`，仍未取得当前亮度。
- 注册表报告链路为 `Upstream: DP / Downstream: HDMI`，含 DP→HDMI 转换；不能由此推断具体转接设备型号。

虽然函数名含 WriteI2C，这次发送的是请求读取亮度的 Get VCP 帧，**没有发送改变亮度的 Set VCP 帧**，也没有断开显示器。

## 尚未确认

本地 SDK 只确认错误码属于 IOKit audio/video 子系统，没有该完整返回码的具体解释。程序将未知返回码保守归类为 permanent-transport-failure，不代表已经证明硬件永久故障，也不能证明 DDC/CI 关闭。

仍需确认 Dell OSD 中的 DDC/CI 开关、Mac→Dell 的线材/转接器/扩展坞与实际输入口。没有可靠原始亮度基线前，不运行写入测试。

## 授权后的复验入口

```bash
# 先只读验证，使用 displaydj list 提供的该目标稳定 UUID
displaydj get brightness --display uuid:<UUID> --json

# 只有确认具体显示器与写入授权后才运行
python3 scripts/hardware-smoke.py --display uuid:<UUID> --allow-write
```

脚本只操作一个明确 UUID：先读取硬件基线并确认主 CLI 使用 DDC，再调整约 3 个百分点，独立读回，最后恢复并再次读取原值。它不测试断开/重连。恢复信息保存在本机独立临时目录，避免覆盖正常 Agent 状态；失败时保留用于恢复。`finally` 不是 SIGKILL 或断电恢复保证。

公开文档不记录显示器的实际 UUID 或序列号。
