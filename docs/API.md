# CLI 与 HTTP

安装步骤见 [README](../README.zh-CN.md#安装命令行工具)。

主入口：`display-cli help`。使用 `--json` 获取 `{ "ok": true, "data": ... }` 或错误 envelope。退出码：0 成功，1 后端/IO 等失败，2 参数或配置问题，3 未找到，4 不支持，5 daemon 问题，6 未授权。批量亮度结果还需检查 `data.results[].ok`；HTTP 200 或外层 `ok` 不代表每块显示器都成功。

| CLI | HTTP |
| --- | --- |
| `displays` | `GET /v1/displays` |
| `brightness get --display <selector>` | `GET /v1/displays/<selector>/brightness` |
| `brightness set 60% --display <selector>` | `POST /v1/brightness`，`{"selector":"…","target":"60%"}` |
| `brightness restore` | `POST /v1/brightness/restore` |
| `doctor` / `capabilities` | `GET /v1/capabilities` |
| `agent list` | `GET /v1/agent/sessions` |
| `agent begin --label <text>` | `POST /v1/agent/sessions` |
| `agent phase <id> running` | `POST /v1/agent/sessions/<id>/phase` |
| `agent beat <id>` | `POST /v1/agent/sessions/<id>/heartbeat` |
| `agent end <id>` | `DELETE /v1/agent/sessions/<id>` |
| `keepawake list` | `GET /v1/keepawake` |
| `panic` | `POST /v1/panic-restore` |
| `connect / disconnect --display uuid:<UUID>` | 当前仅 CLI 和 App |

完整路由以 `Sources/VibeDisplayServer/APIRouter.swift` 为准。

```bash
display-cli serve --detach
curl -fsS -H "Authorization: Bearer $(display-cli token show)" \
  http://127.0.0.1:7643/v1/health
display-cli daemon stop
```

默认端口 7643，实际服务描述在 `~/.displaydj/daemon.json`。令牌属于本机凭据，不应提交 Git。`--no-token` 是保留的显式选项，不建议用于日常集成。

### 手动亮度优先（1.0.1）

CLI `agent begin/phase/end --json` 保留原有 `data.session`，并返回完整 `brightness`、`keepAwake` 和 `warnings`；跳过提示也会输出到 stderr，方便脚本检查实际逐屏结果。

菜单栏滑块、滚轮、快捷键、同步调节、亮度预设实际应用，以及直接 `brightness set` / HTTP 亮度写入均表示新的手动意图。即使由普通脚本发出，直接写入也会接管目标屏幕；需要按任务生命周期自动恢复时使用 Agent 会话接口。已存在的会话随后在该屏的阶段变化、结束或超时中跳过亮度写入，其他屏幕不受影响。保活租约和任务状态仍按会话生命周期处理。新建会话以当时亮度建立新的恢复点。

`PhaseApplyReport.brightness[]` 新增可选 `skippedReason`：`manual_override` 表示用户已接管，`another_session_active` 表示还有共享恢复点的活动会话，`unclaimed_display` 表示该会话未取得目标（含旧版会话），`recovery_not_owned` 表示该恢复点不属于当前自动化。此时 `ok:true` 表示已遵守控制规则，`applied` 缺失表示未发送写入，不能把它解释为亮度已经改变；`warnings[]` 同时解释跳过原因。会话 JSON 的可选 `brightnessRevisions` 保存逐屏控制声明。

直接 `brightness set` 保留本轮手动修改前的恢复点，只有显式 `brightness restore` / `panic` 才恢复；服务退出不再自动撤销直接写入。菜单栏、兼容 CLI 和显式 Gamma 设置/关闭会退役该屏被接管的旧恢复点。预设保存和 `--dry-run` 不接管显示器。重叠的 Agent 会话共享恢复点，由最后一个仍持有控制权的会话恢复。默认终止阶段的 `restore` 覆盖本会话开始时捕获的各阶段目标；明确配置的终止阶段 selector 仍只作用于该选择器。

新旧版本混用时应先结束任务并以已安装的新 CLI 执行 `daemon restart`。旧状态仍可读取；缺少所有权的旧恢复点只允许显式恢复，新的 Agent 会话会要求先恢复或手动接管。状态损坏、锁冲突或服务版本不同会拒绝写入。各进程必须使用相同 `DISPLAYDJ_HOME`；系统设置、显示器实体按键和其他应用的修改不在本轮接管检测范围内。Gamma 色表仍会随驻留进程退出而释放。

### 显式软件调光

`display-cli dimming get --display builtin`、`dimming set 97% --display builtin`、`dimming off --display builtin` 分别对应 `GET /v1/software-dimming?selector=builtin`、`POST /v1/software-dimming`（`{"selector":"builtin","target":"97%"}`）和 `DELETE /v1/software-dimming?selector=builtin`。这条路径需要驻留服务，设置值只接受绝对的 8%–100%；`off` 恢复系统色表。它更改 Gamma，不改变背光，不需要辅助功能权限。`get` 的 100% 也可能表示当前没有软件调光。写入响应表示 CoreGraphics 接受请求并且服务保存了该数值，不能证明用户肉眼看到预期效果。服务退出时会释放色表。

`displaydj` 兼容 CLI 保留自己的 schemaVersion 1 和 0/2/3/4/5/6/7/8/9/70 退出码。它的 `set brightness 60` 使用 0–100，而主 CLI 的裸数使用 0–1；迁移时建议统一写 `60%`。

## 显示控制与预设

三类能力同时提供 CLI 和 HTTP；App 的“显示设置与预设”窗口调用内置 `display-cli`。`displaydj` 兼容命令没有新增这些子命令。

| CLI | HTTP |
| --- | --- |
| `contrast get --display external` | `GET /v1/controls/contrast?selector=external` |
| `volume get --display uuid:X` | `GET /v1/controls/volume?selector=uuid%3AX` |
| `contrast set 60% --display uuid:X --dry-run` | `POST /v1/controls/contrast`，`{"selector":"uuid:X","target":"60%","dryRun":true}` |
| `volume set -5% --display uuid:X` | `POST /v1/controls/volume`，`{"selector":"uuid:X","target":"-5%"}` |
| `modes list --display main` | `GET /v1/modes?selector=main` |
| `modes set <mode-id> --display uuid:X --dry-run` | `POST /v1/modes`，`{"selector":"uuid:X","modeID":123,"dryRun":true}` |
| `modes preview <mode-id> --display builtin` | 仅 CLI；本进程预览 10 秒，退出后由 macOS 恢复会话模式 |
| `modes guarded-set <mode-id> --display uuid:X` | 仅 CLI，供 App 的 15 秒确认使用；stdin 发送 `keep` 才保留，关闭管道或超时则尝试恢复 |
| `profile list` | `GET /v1/profiles` |
| `profile show work` | `GET /v1/profiles/work` |
| `profile save work --display all` | `POST /v1/profiles/work`，`{"selector":"all","replace":false}` |
| `profile apply work --dry-run` | `POST /v1/profiles/work/apply`，`{"dryRun":true}` |
| `profile delete work` | `DELETE /v1/profiles/work` |

对比度/音量使用 0…1、显式百分比、±100% 范围内相对增量；不接受 `restore`。设置必须显式给出 selector；`external` 表示有意批量操作外屏。它控制显示器自己的 VCP，不控制 macOS 系统输出音量。`data.results` 每项包含 `displayUUID`、`slug`、`control`、`value`、`requested`、`ok`、`verified`、`dryRun`、`error`，失败时还有稳定 `errorCode` 与可选 `errorDetails`（可空字段会省略）。`error` 是给用户的简短说明；排障脚本应使用 `errorCode` 和 `errorDetails`，例如 `featureCode=0x62` 的不支持结果。数值为 0…1；相对实际写入的 `requested` 省略，`value` 是事务确认后的读值；预演显示当前 `value` 与计划 `requested`，`verified=false`。一次失败不意味着所有显示器都不支持该功能。

模式列表返回 `data.displays[]`，含 `current` 与 `modes`，每个模式包括 `id`、逻辑尺寸、像素尺寸、`refreshRate`、`hiDPI`、`usable`。0 Hz 表示系统没有报告固定刷新率。只能选择当前系统枚举出的 desktop 模式，`modeID` 不能跨会话使用。实际设置返回 `previous/requested/observed` 与 `verified`；失败时尝试恢复并在错误消息中报告恢复状态。CLI/HTTP 的正式设置使用 `.forSession`，没有自动确认或永久布局持久化。

`modes preview` 在独立 CLI 进程中使用 CoreGraphics `.forAppOnly`，停留 10 秒后退出；macOS 在进程终止时恢复原有会话模式。预览不会经 daemon 执行，也不会正式保存模式。App 设置窗口不提供额外预览按钮；选择系统枚举出的可用模式后直接“应用并确认”。正式应用使用独立的 `modes guarded-set` 子进程；子进程执行模式切换、回读后保持 15 秒，只有收到 App 经 stdin 发来的 `keep` 才保留。关闭窗口、App 正常退出或崩溃导致管道关闭，以及超时，都会先核对显示器身份和当前模式，再尝试恢复。守护进程自身被强制结束时无法保证恢复；其结果记录在私有 `mode-guard.jsonl`。CLI 的 `modes set` 仍是显式直接设置，不附带自动回退。进程退出后的独立回读是 CLI 预览恢复的验收依据。

亮度预设保存在 `DISPLAYDJ_HOME/profiles.json`，按稳定 UUID 保存亮度和 transport，仅包含亮度，不包含模式/音量/布局。名称限定 1–64 个字符，可使用中文等文字、数字、`-`、`_`。保存仅读取，覆盖已有名称需要 `--replace`。文件损坏会报错，旧文件保留。应用时所有目标须在线、可读且 transport 与保存时一致；任一预检失败则不写任何屏幕。Gamma 实际应用要求 daemon，预演无需 daemon。预设失败退出 1；`data.results` 和 `data.rollback` 分别保留原操作与逆序回退结果。回退失败不会被隐藏，跨屏操作不承诺原子性。

`--dry-run` 仅支持新控制的 `set`、`modes set`、`profile apply`；其他命令传入此标志会报参数错误。预演仍会读取显示器并可能发送 DDC Get VCP，但不会发送 Set VCP、切换模式或保存恢复快照。

批量控制沿用 v1 envelope：HTTP 200 / 外层 `ok:true` 不代表逐屏成功；检查 `results[].ok`，预设检查 `data.ok`。CLI 已据此退出 1，预检错误仍使用上文的稳定错误码。新增参数检查还拒绝未知标志、重复值选项、遗漏值、无效整数、冲突选择器与新命令多余位置参数。亮度读取失败现在返回错误，写入无法取得基线或回读时报告失败。
