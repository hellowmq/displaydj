# CLI 与 HTTP

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

`displaydj` 兼容 CLI 保留自己的 schemaVersion 1 和 0/2/3/4/5/6/7/8/9/70 退出码。它的 `set brightness 60` 使用 0–100，而主 CLI 的裸数使用 0–1；迁移时建议统一写 `60%`。

## v0.3.0 预览版显示控制与预设

三类能力同时提供 CLI 和 HTTP；App 的“显示设置与预设”窗口调用内置 `display-cli`。`displaydj` 兼容命令没有新增这些子命令。

| CLI | HTTP |
| --- | --- |
| `contrast get --display external` | `GET /v1/controls/contrast?selector=external` |
| `volume get --display uuid:X` | `GET /v1/controls/volume?selector=uuid%3AX` |
| `contrast set 60% --display uuid:X --dry-run` | `POST /v1/controls/contrast`，`{"selector":"uuid:X","target":"60%","dryRun":true}` |
| `volume set -5% --display uuid:X` | `POST /v1/controls/volume`，`{"selector":"uuid:X","target":"-5%"}` |
| `modes list --display main` | `GET /v1/modes?selector=main` |
| `modes set <mode-id> --display uuid:X --dry-run` | `POST /v1/modes`，`{"selector":"uuid:X","modeID":123,"dryRun":true}` |
| `profile list` | `GET /v1/profiles` |
| `profile show work` | `GET /v1/profiles/work` |
| `profile save work --display all` | `POST /v1/profiles/work`，`{"selector":"all","replace":false}` |
| `profile apply work --dry-run` | `POST /v1/profiles/work/apply`，`{"dryRun":true}` |
| `profile delete work` | `DELETE /v1/profiles/work` |

对比度/音量使用 0…1、显式百分比、±100% 范围内相对增量；不接受 `restore`。设置必须显式给出 selector；`external` 表示有意批量操作外屏。它控制显示器自己的 VCP，不控制 macOS 系统输出音量。`data.results` 每项包含 `displayUUID`、`slug`、`control`、`value`、`requested`、`ok`、`verified`、`dryRun`、`error`（可空字段会省略）。数值为 0…1；相对实际写入的 `requested` 省略，`value` 是事务确认后的读值；预演显示当前 `value` 与计划 `requested`，`verified=false`。一次失败不意味着所有显示器都不支持该功能。

模式列表返回 `data.displays[]`，含 `current` 与 `modes`，每个模式包括 `id`、逻辑尺寸、像素尺寸、`refreshRate`、`hiDPI`、`usable`。0 Hz 表示系统没有报告固定刷新率。只能选择当前系统枚举出的 desktop 模式，`modeID` 不能跨会话使用。实际设置返回 `previous/requested/observed` 与 `verified`；失败时尝试恢复并在错误消息中报告恢复状态。使用 `.forSession`，没有倒计时自动确认或永久布局持久化。

亮度预设保存在 `DISPLAYDJ_HOME/profiles.json`，按稳定 UUID 保存亮度和 transport，仅包含亮度，不包含模式/音量/布局。名称限定 1–64 个字符，可使用中文等文字、数字、`-`、`_`。保存仅读取，覆盖已有名称需要 `--replace`。文件损坏会报错，旧文件保留。应用时所有目标须在线、可读且 transport 与保存时一致；任一预检失败则不写任何屏幕。Gamma 实际应用要求 daemon，预演无需 daemon。预设失败退出 1；`data.results` 和 `data.rollback` 分别保留原操作与逆序回退结果。回退失败不会被隐藏，跨屏操作不承诺原子性。

`--dry-run` 仅支持新控制的 `set`、`modes set`、`profile apply`；其他命令传入此标志会报参数错误。预演仍会读取显示器并可能发送 DDC Get VCP，但不会发送 Set VCP、切换模式或保存恢复快照。

批量控制沿用 v1 envelope：HTTP 200 / 外层 `ok:true` 不代表逐屏成功；检查 `results[].ok`，预设检查 `data.ok`。CLI 已据此退出 1，预检错误仍使用上文的稳定错误码。新增参数检查还拒绝未知标志、重复值选项、遗漏值、无效整数、冲突选择器与新命令多余位置参数。亮度读取失败现在返回错误，写入无法取得基线或回读时报告失败。
