# 分阶段设备验收

此文档用于 0.3.0 之后的开发验证；代码、构建和模拟测试不能代替屏幕上的效果。每次记录版本、commit、macOS、连接方式、命令日志与肉眼观察。日志可能包含显示器 UUID、序列号和本机路径，仅私下提供，不放入公开 issue 或仓库。

## 用户双屏 GUI 操作后的日志复核（2026-09-22，本地 1.0.0 候选）

用户按 [GUI 验收步骤](GUI-ACCEPTANCE-1.0.md)操作，并指出两项体验问题：正式应用模式本身已有确认，额外强制预览没有意义；快捷键提示应左侧降低、右侧增大。私有 `displaydj-ui-acceptance.log` 与 `mode-guard.jsonl` 已在本机读取，公开记录不复制显示器身份。

| 项目 | 日志及独立回读能确认什么 | 仍缺什么 |
| --- | --- | --- |
| 双屏硬件同步 | `BrightnessWrite` 显示两屏同步意图，并分别回读确认 95%、26%、100% 的写入；测试前保存的两屏亮度均为 100%，测试后只读回报两屏仍为 100%。没有记录到写入错误 | 用户的屏幕观感；本轮滑块拖动跨越较大范围，不是原验收步骤所写的精确 ±5 个百分点 |
| 模式确认 | 守护日志显示 HP 从原模式 ID 60 应用 ID 88 后用户选择保留；随后从 ID 88 应用 ID 81，15 秒未确认而恢复到 ID 88。当前只读模式仍为 ID 88（3008 × 1692@60），与测试前保存的 ID 60（1920 × 1080@60）不同，符合第一次明确保留的选择 | 窗口倒计时的肉眼效果；原验收步骤要求最终回到测试前模式，但用户目前保留了另一个模式，不把它误判为恢复失败，也不擅自改回 |
| 快捷键、Gamma | 保存的 OSLog 没有 `BrightnessHotkey` 事件；该日志没有 Gamma 专项事件，daemon 文本日志为空。最终两屏 Gamma 只读均为 100% | 是否实际触发快捷键、Gamma 期间的画面变化、权限撤销提示，不能从这些日志判为通过或失败 |

这次反馈促成界面修正：保留可选的 10 秒预览，取消“应用并确认”前的预览门槛；快捷键展示顺序改为降低在左、增大在右，实际键位映射不变。修正后完整单测与 CLI smoke 通过，release 包校验通过，候选已重新安装并启动；新界面仍需实际点击和肉眼确认。

用户进一步要求移除设置窗口的模式预览，并质疑 Gamma 的手动“读取／应用”步骤。最新候选已移除窗口预览按钮（CLI 诊断预览保留）；Gamma 在打开窗口或切屏时自动读取，用户主动启用服务后松开滑块即提交，失败时重新读取以免显示未确认值；关闭按钮继续显式恢复系统色表。`SoftwareDimming` OSLog 类别记录逐屏结果，不写入原始 UUID。最新代码完整单测、CLI smoke、release 包校验通过，已安装到本机；窗口实操效果仍待观察。

## HP D27k 外屏实测（2026-09-22，未发布的工作区代码）

用户换上 HP D27k 后，macOS 与 `displaydj list` 均识别为一台非镜像外屏，内建屏同时在线。用户观察到滑块能改变亮度；本轮用独立 DDC 请求验证了硬件通路。当前接线的具体接口和线材尚未记录，因此以下结论只归于 **HP 的当前连接**，也不能反推此前 Dell 失败的原因。

| 控制项 | 只读预检 | 小幅写入、独立回读、恢复 |
| --- | --- | --- |
| 硬件亮度，VCP 0x10 | 读取 56% | 56% → 53% → 56%，三次读数及恢复检查通过 |
| 硬件对比度，VCP 0x12 | 读取 80% | 80% → 77% → 80%，三次读数及恢复检查通过 |
| 显示器音量，VCP 0x62 | 显示器明确报告此功能不支持 | 未写入，界面应保持不可用状态 |
| 独立软件调光，Gamma | 隔离服务中先读到外屏 RGB 最大值 1.0 | 调到 97% 时独立 CoreGraphics 公式读到 RGB 0.97，关闭后恢复 1.0；前后 DDC 硬件亮度仍为 56% |

每项使用唯一稳定 UUID 与隔离 `DISPLAYDJ_HOME`，`scripts/hardware-smoke.py` 分别保留只读与写入阶段的私有 `report.json`、`commands.jsonl`；写入阶段还保留 `hardware-recovery.json`。软件调光另有隔离命令与色表日志。报告包含设备身份，不复制进公开文档。命令、DDC 回读与独立色表回读证明协议响应及恢复，**尚未由用户对 HP OSD 数值、肉眼亮度／对比度变化作独立验收**。多屏快捷键目标、Gamma 状态隔离和可选的相同百分点硬件亮度同步已做代码及注入式验证，实际 GUI 操作和跨屏观感仍待补。后续仍需验证无 DDC 屏幕的界面路径及设备热插拔后的状态更新。

另用隔离配置完成一次真实双屏预设事务：内建屏原生背光基线 67%，HP DDC 亮度基线 56%；保存中文名称预设并只读预演后，分别调至 65%／53%，逐屏独立回读匹配；应用预设后回到 67%／56%，最终恢复检查均通过。私有 `report.json` 与 `commands.jsonl` 位于本机临时 `displaydj-two-screen-profile-*` 目录。此验证覆盖 CLI 的跨屏预设、两条硬件控制路径和恢复，不覆盖菜单栏同步开关或其视觉反馈。

HP 外屏还完成独立显示模式守护实测：从当前模式暂时切至系统列出的 1600 × 900@60，`guarded-set` 回读确认后分别试了关闭 stdin 管道、发送 `keep`、等待 15 秒超时；管道关闭与超时均恢复原模式，`keep` 保留目标模式，随后显式设回原模式。另用辅助进程在收到切换确认后直接 `os._exit` 模拟 App 异常退出，原模式约 1.27 秒后独立回读恢复。每种路径的 `commands.jsonl`、`report.json` 与守护日志均保存在本机独立临时目录，最终原模式已回读匹配。此验证覆盖 CLI 子进程和真实 WindowServer，不等于设置窗口的点击、可见倒计时或 App 本体崩溃的视觉验收。

## 当前 Dell 外屏实测（2026-09-22，未发布的工作区代码）

目标为同一台 Dell D2720DS，2560 × 1440、60 Hz，内建屏同时在线。用户说明显示器 OSD 的 DDC/CI 已开启，并推测当前使用 HDMI 链路；本机只读注册表显示 DP→HDMI 转换，尚未核实实际线材与输入口。以下结果只适用于**当前连接**。每项使用目标稳定 UUID，原始 UUID 和序列号只保留在本机私有日志中。

| 项目 | 本轮证据与边界 |
| --- | --- |
| DDC 亮度、对比度、音量预检 | 三项各执行只读 `--preflight`。Get VCP 0x10／0x12／0x62 均在 `IOAVServiceWriteI2C` 请求阶段返回 `-535740416`／`0xe0114000`；没有取得硬件基线，没有发送 Set VCP，也没有运行写入阶段。服务身份匹配成功；错误不能单独归因于线材、转接器或显示器。 |
| 外屏软件调光 | 隔离 daemon 中设为 97%，独立 CoreGraphics 色表公式读出 Dell 的 RGB 最大值从 1.0 变为 0.97；关闭后回到 1.0。内建屏保持 1.0。 |
| 外屏亮度预设 | 对 Dell 保存 97% Gamma 预设，改为 90% 后应用，独立色表读回 Dell 0.97，内建屏仍为 1.0；服务停止后两屏读回 1.0。 |
| 外屏显示模式 | 从 2560 × 1440@60 临时预览 2048 × 1152@60，进程结束后读回原模式；正式设置同一模式后独立读回目标，再设置回原模式并读回原值。模式 ID 只在本次枚举有效。 |
| 外屏断开／重连 | 首次断开已验证；首次重连命令因系统拓扑发布延迟报告验证失败，但随后 Dell 已在线，重复恢复命令遭 CoreGraphics 错误。修复为有限等待并先保存恢复身份后，隔离复测中断开、重连、独立列表验证均通过；只执行一次重连事务，记录最终为空。 |
| GUI 与视觉 | 以上有命令及系统状态回读；尚无窗口点击、显示器 OSD 或肉眼观感的独立验收。 |

私有报告目录由 `hardware-smoke.py` 和外屏隔离测试打印，包含 `report.json`、`commands.jsonl`；重连复测另有独立 `commands.jsonl`。日志中的请求、退出码和恢复状态足以复查本轮结论，但公开材料不复制设备身份。隔离测试发现连接记录原先写入日常 Application Support；现已改为尊重 `DISPLAYDJ_HOME`。本轮产生的一条过期日常记录在确认显示器在线后通过 `connect` 正常清除，外屏仍在线。

本轮修复后完整 `swift test` 通过 606 项，`python3 scripts/smoke.py` 通过，`bash scripts/build-app.sh` 与 `codesign --verify --deep --strict` 通过；包仍为 0.3.0 的本地 ad-hoc 签名构建。收尾只读复核显示双屏在线、Dell 在线、日常断开记录为 0。系统里仍运行着早于本轮代码的服务，新 CLI 对缺失的软件调光接口会明确提示重启服务；没有擅自停止该日常服务。App 的真实窗口与操作尚未视觉验收。

### TODO：同一台 Dell 换 DP 连接后的 DDC 对照

1. 保持 **同一台 Dell D2720DS** 与同一台 Mac，记录新线材、转接器、输入口和显示器 OSD DDC/CI 状态；先运行 `display-cli doctor --json` 与 `displaydj list --json`，确认稳定身份、分辨率、镜像状态，并比较注册表链路。不能仅按“换成 DP”推断 DDC 一定可用。
2. 用同一稳定 UUID 逐项运行上述三条 `--preflight`，保留各自的 `report.json` 与 `commands.jsonl`。比较 Get VCP 的阶段、错误码、耗时和读到的最大值；如果仍读不到基线，停止，继续排查显示器输入、适配链路及实现兼容性。
3. 只有某项读取成功，才对该项运行 `--allow-write`：脚本记录基线、小幅改动、独立回读、恢复与恢复回读。任一恢复失败立刻停止后续项，保留 `hardware-recovery.json`，按日志中的原值手动恢复。音量是否有物理输出需另作肉眼／听觉验收。
4. 对比“当前连接失败”与“DP 连接结果”时，仅改变连接链路，不把两个结果混成一次兼容性结论；若 DP 成功，再在 App 中检查硬件滑块和错误提示。若仍失败，不直接归咎于显示器或线材。

## 本轮内建屏记录（2026-09-21，未发布的工作区代码）

| 检查 | 结果 |
| --- | --- |
| 构建与 App bundle | `swift build`、`bash scripts/build-app.sh` 通过，工作区 App 为 ad-hoc 签名 |
| 自动化 | `swift test` 通过 598 项；`python3 scripts/smoke.py` 通过，隔离测试没有请求硬件写入 |
| 内建屏 Gamma | 隔离 daemon 中 `dimming get` 为 100%，`set 97%` 返回成功且再次读取为 97%，`off` 后再次读取为 100%；服务已停止。私有命令日志保存在本机临时目录 |
| 外屏脚本拒绝路径 | 对内建屏执行 `--preflight` 返回失败，日志记录两条只读命令，未尝试 `set` 或 `restore` |
| GUI 视觉与交互 | 工作区 App 已构建；Computer Use 对完整 App 路径两次超时，不能声称完成视觉验收 |
| 外屏 DDC | 本轮只有内建屏，未执行外屏写入／恢复 |

## 追加内建屏记录（2026-09-22，隔离工作区验证）

| 检查 | 实测结果 |
| --- | --- |
| 原生背光 | `display-services` 从约 68.9% 调到 70.9%，独立读取匹配；恢复后读取约 68.9%。私有 `commands.jsonl` 保存在本机临时目录 |
| 亮度预设 | 内建屏基线约 68.9%，调到 70.9% 后应用预设，再次读取约 68.9%；`data.ok=true`。私有 `commands.jsonl` 保存在本机临时目录 |
| 显示模式 | 内建屏枚举 8 个模式；对当前模式执行 `--dry-run`，未实际切换 |
| 服务退出恢复 | 隔离 daemon 中 Gamma 100% → 97%；正常停止并重启后读取 100%；测试 daemon 已停止。私有 `commands.jsonl` 保存在本机临时目录 |
| 接口权限 | 未带 Bearer 令牌请求 `GET /v1/software-dimming` 返回 HTTP 401；没有执行未授权写入 |

上述日志含本机设备身份与路径，只供私下排障。命令回读和服务状态不等于人工观察到颜色、OSD 或窗口交互。竞品差距和仍可在内建屏推进的项目见 [FEATURE-GAP-AUDIT.md](FEATURE-GAP-AUDIT.md)。

## 追加开发验证（2026-09-22）

daemon 现监听系统及屏幕唤醒通知，延迟一秒按稳定 UUID 重新枚举并应用之前的 Gamma 值；重应用失败会清除内存中旧值并记录警告。两项注入式测试覆盖新运行时 ID、无关屏不写入及失败清理。`swift test` 全套通过，App bundle 构建通过。**尚未让真实机器睡眠/唤醒，因此这项是代码与模拟验证，不是物理效果验收。**

工作区 App 启动后，Computer Use 对完整 bundle 路径仍返回 `timeoutReached`，无法读取设置窗口；本次启动的两个工作区进程已退出，原有安装版及原有 daemon 未处理。GUI 视觉验收仍未完成。

内建屏显示模式从当前 ID 3（1440×900）预览到 ID 2（1280×800）：切换回读 `verified=true`，CLI 退出后独立枚举再次得到 ID 3。预览使用 `.forAppOnly`，10 秒后进程退出；私有 `commands.jsonl` 保存在本机临时目录。这验证了本机临时切换和自动恢复。

正式 `.forSession` 模式也在内建屏完成一次小范围验证：ID 3 → ID 2，独立回读 ID 2；约两秒后设回 ID 3，再次独立回读 ID 3。App 的 15 秒确认与超时回退已实现并编译通过，但 GUI 点击和计时器行为因 Computer Use 超时尚未完成端到端验收；App 异常终止时也不能依靠窗口计时器恢复。

构建包入口复核：`codesign --verify --deep --strict` 通过；打包 CLI 报告 arm64、0.3.0，Info.plist 版本同为 0.3.0。签名仍为 ad-hoc，未公证；这只能证明本机构建包内部一致，不能证明正式分发可用。

Gamma 的命令回读证明驻留服务保存了请求的色表系数，不能单独证明用户肉眼看到预期变化；界面与观感仍需补验。

## 第一阶段：只用内建屏

1. `swift test` 与 `python3 scripts/smoke.py`：验证服务和 CLI 契约，不写显示硬件。
2. `display-cli doctor --json`：确认内建屏、`display-services` 控制方式及系统版本；只读。
3. 软件调光走独立的 `dimming` 路径。它更改 Gamma 色表，不调整背光，也不要求辅助功能权限。`serve` 常驻是为了保持效果；停止服务或运行 `dimming off` 恢复颜色。自定义全局快捷键另需辅助功能授权。
4. 在内建屏上依次执行 `display-cli serve --detach`、`display-cli dimming get --display builtin --json`、`display-cli dimming set 97% --display builtin --json`、`display-cli dimming off --display builtin --json`。预期画面短暂轻微变暗，随后恢复；同时检查 JSON 中 `transport=gamma`、`ok=true`。如果正在使用重要的颜色工作流，先结束工作再做视觉检查。
5. 内建背光与软件调光分开记录：`brightness` 的成功不能证明 `dimming` 成功，反之亦然。

## 第二阶段：用户接入外屏

先关闭其他控制显示器亮度的应用，并确认目标屏幕及连接方式。运行 `display-cli displays --json`，从本机输出选择唯一外屏 UUID。下面每条命令都只针对这一块屏；预检不会写硬件。

```bash
python3 scripts/hardware-smoke.py --display uuid:<UUID> --control brightness --preflight
python3 scripts/hardware-smoke.py --display uuid:<UUID> --control contrast --preflight
python3 scripts/hardware-smoke.py --display uuid:<UUID> --control volume --preflight
```

预期：受支持的控制项会读到 0–100% 基线；不支持的项明确失败。每次运行打印本机私有 `commands.jsonl` 和 `report.json` 路径。前者记录命令、退出码、耗时、stdout、stderr 和超时；后者记录阶段、基线、目标、写入回读、恢复回读及失败原因。出现失败时保留该目录，再提供报告与日志供分析；分享前检查其中的设备身份与路径。

只在确认预检成功、接受屏幕亮度／对比度／音量短暂改变后，逐项运行写入阶段：

```bash
python3 scripts/hardware-smoke.py --display uuid:<UUID> --control brightness --allow-write
python3 scripts/hardware-smoke.py --display uuid:<UUID> --control contrast --allow-write
python3 scripts/hardware-smoke.py --display uuid:<UUID> --control volume --allow-write
```

脚本先保存基线，仅改变约 3 个百分点，随后用独立命令回读并恢复，再回读原值。每次保留私有 `hardware-recovery.json`。若恢复失败，停止后续项目，保留日志和恢复文件；不要继续运行下一个控制项。亮度以外的控制项用保存的基线值回写。脚本不测试输入切换、关机或断开重连。

脚本已用内建屏负例验证：预检失败、`report.json` 记为 `failed`，无外屏写入；并用模拟 DDC CLI 验证预检及 50% → 47% → 50% 的报告流程。模拟恢复失败时，脚本非零退出、报告记为 `failed` 并保留恢复文件和命令日志。模拟结果只证明脚本控制流，不是实际外屏成功。

### 报告填写项

| 项目 | 记录 |
| --- | --- |
| 版本、commit、macOS | 待设备实测 |
| 屏幕型号与连接方式 | 待设备实测；公开报告隐藏序列号及 UUID |
| brightness 预检／写入／恢复 | 待设备实测 |
| contrast 预检／写入／恢复 | 待设备实测 |
| volume 预检／写入／恢复 | 待设备实测；无扬声器可记不适用 |
| 画面和显示器 OSD 的实际变化 | 待用户观察 |
| commands.jsonl 路径、失败命令与错误码 | 待设备实测；日志私下传递 |
| report.json、hardware-recovery.json | 待设备实测；日志私下传递 |

显示模式切换与多屏回退另做专门验收，因为失败可能使窗口不可见；本脚本不会触发它们。
