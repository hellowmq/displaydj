# Agent 接入

最简单的接入是包裹一个明确的命令：

```bash
display-cli agent run --label 'project checks' -- make test
```

默认行为会调整亮度并保持唤醒；先检查 `display-cli config show`。长任务由包装器维护心跳，结束后传递子进程退出状态。不要把 `agent begin` 当成无需维护的永久会话。

需要工具自己控制阶段时：

```bash
display-cli serve --detach
SID=$(display-cli agent begin --label 'review' --json |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["session"]["id"])')
display-cli agent phase "$SID" running
display-cli agent beat "$SID"
display-cli agent phase "$SID" waiting --note '等待人工决定'
display-cli agent end "$SID" --outcome succeeded
```

上例只展示顺序；实际长任务应定期 `agent beat`，并在失败路径调用 `agent end --outcome failed`。默认会话超时 900 秒，daemon 定期回收失去心跳的会话。daemon 自身被 SIGKILL 时不会执行即时恢复；重启后或显式 `brightness restore` 再恢复。

若只想保持唤醒而不改变显示器亮度：

```bash
display-cli keepawake run -- your-command
```

可编辑 `config init` 生成的配置，将所有阶段的 `brightness` 改为 null，自定义保活范围。只替换部分 `phases` 会让未指定阶段回落到默认值，应检查完整配置。

本项目没有内置 MCP server，也不会自动编辑 Codex、Claude Code 或 Cursor 的配置。任何支持 shell 或本机 HTTP 的工具都可按这里的契约接入。

1.0.1 源码加入逐屏手动亮度优先（尚未发布）：用户在菜单栏或直接 CLI/HTTP 写入亮度后，当前会话仍可心跳、转换阶段和结束，但跳过该屏的调光和自动恢复。请记录 `brightness[].skippedReason` 和 `warnings[]`，不要因 `manual_override` 重试写入或偷偷新建会话。新任务获准开始时，新会话以当时亮度建立恢复点。具体恢复、旧状态和版本要求见 [API 契约](API.md#手动亮度优先101-源码尚未发布)。
