# Contributing

Use Swift 6 or newer on macOS. Before submitting a change:

```bash
swift build
swift test
python3 scripts/smoke.py
```

Keep hardware tests opt-in and target a specific display. Default tests must not change brightness or display topology. Use injectable transports and deterministic failures to exercise write verification, restoration and identity matching. Preserve the notices in LICENSES when moving derived code.

The Swift 5 language mode on VibeDisplay targets is intentional until their concurrency migration is complete. Avoid changing public JSON fields or exit codes without documenting the migration. Do not include tokens, state snapshots, personal display inventories, internal repository URLs or account configuration in a contribution.
