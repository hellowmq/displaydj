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
