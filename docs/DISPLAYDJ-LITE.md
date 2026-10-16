# DisplayDJ Lite 0.1.0

Lite 只做单台外屏退出 Mac 桌面与重新连接。它与 Full 共用连接内核，有独立 App、版本和恢复文件；没有亮度、Gamma、模式、CLI、HTTP、登录项或 daemon。当前为预发布候选；公开下载以实际 GitHub Release 为准。

## 使用与恢复

主面板显示当前外屏和 Lite 保存的恢复入口。点击断开后先看到独立确认框，说明窗口会移到其他在线屏幕；Return/Escape 取消。内建、镜像、虚拟/未知类型、身份不唯一和最后在线屏幕受保护。有当前待恢复记录时须先恢复，不能继续断开另一台。

操作期间原行显示进度并阻止重复提交，只有新拓扑核验后才报告结果。失败保留记录和重试入口，记录不代表目标当前在线或已实际接线。系统拒绝连接时提供检测显示器和重启提示，不静默清理记录。

正常退出只提供恢复并退出或取消。恢复未确认则取消退出。新断开使用 CoreGraphics 应用作用域，连接恢复提交到会话作用域以处理旧原型的断开基线。崩溃/卸载的边界、系统恢复步骤及私有接口限制见 [恢复与卸载](LITE-RECOVERY.md)。

## 本地构建

```bash
bash scripts/build-lite-app.sh
python3 -B scripts/smoke-lite.py
bash scripts/run-lite-app.sh
```

默认运行真实模式，启动只读取；只有明确确认的连接操作才写入。产物 `.build/DisplayDJLite.app`，标识 `io.github.hellowmq.displaydj.lite`，版本 0.1.0，部署目标 macOS 13。`--release` 构建 Release。已批准图标随包生成 icns；菜单栏使用同家族模板图标，面板跟随系统浅深色。

```bash
bash scripts/run-lite-app.sh --preview
bash scripts/package.sh --product lite --format all --output-dir /tmp/lite-0.1.0-candidate
```

`--preview` 是明确标注的内存模拟，不读取本机设备、不写真实记录、不代表设备验证。打包从同一次构建生成 ZIP/DMG，各自校验身份、文件、权限、许可证、架构、签名和 SHA-256。已有同名输出时拒绝覆盖。签名默认 ad-hoc、未经公证；可选 Developer ID 分支尚需实际证书验收。

## 数据与升级

恢复文件：`~/Library/Application Support/DisplayDJLite/disconnected-displays.json`。诊断可通过 `DISPLAYDJ_LITE_HOME` 选择独立位置，不继承 Full 的 `DISPLAYDJ_HOME`。文件保存在 App 外，覆盖安装不会删除它。不能通过删除记录假装恢复成功。

Full 的恢复数据和二进制不被 Lite 接管。连接内核沿用短期共享意图账本，让 Full 识别主动变化；这不是跨进程互斥锁，避免两款 App 同时操作同一目标。Lite 拓扑监听只刷新，不批量启用新显示器。

当离线 UUID 不可读时，只接受本次开机期间的唯一记录且编号未被在线设备占用，之后仍核验恢复 UUID。跨开机的旧编号不会被盲用。

## 2026-10-16 候选验收

- 完整 `swift test` 在已核对的 `CFFIXED_USER_HOME` 隔离目录运行：717 项通过（Swift Testing 与 XCTest 合计）。测试使用内存模拟和隔离存储；实体操作证据单列如下。
- Lite 专项 24 项、配置作用域 4 项测试覆盖记录/身份保护、恢复失败、退出串行、应用作用域断开、会话作用域恢复和 Full 默认行为。它们注入事务，不操作真实显示器。
- 构建、严格签名、bundle smoke 与打包检查按候选包执行；新 CI 配置包含两款 App，远端结果以对应提交的 Checks 为准。
- 新 Lite 已覆盖安装到 `/Applications/DisplayDJLite.app`，旧包在 App 外以 ZIP 备份，安装后核对进程路径与完整包字节；恢复文件保留。
- 已连接 Dell 的真实恢复验收通过：普通重新连接、恢复并退出，以及恢复子进程在主界面 SIGKILL 后约 7.3 秒恢复目标并结束。旧 HP 记录被安全保留为未接入历史，不阻塞 Dell，也未被清除。
- `.forAppOnly` 单独回收在该设备实测失败，已用断开前确认就绪的恢复子进程补足，不再仅以 API 作用域宣称安全。详细发现、过程与边界见 [实体设备验收](LITE-DEVICE-VERIFICATION.md)。

用户已确认测试后 Dell 画面正常；随后带走 MacBook，Dell 暂时物理断开。当前这组正常恢复/异常结束恢复验收无需再接屏重复。

公开发布仍需明确授权；当前准备预发布草稿。HP 实体恢复、完整画质测评、浅色完整验收、VoiceOver、干净首装、最低系统和更广硬件支持未验证。不能宣传“卸载必然恢复”或“永远不会出问题”。
