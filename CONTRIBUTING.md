# Contributing

Use Swift 6 or newer on macOS. DisplayDJ Full and Lite share a Swift Package. Keep changes focused and preserve unrelated local work. See [maintenance and release standards](docs/MAINTENANCE.md) and the [interaction contract](docs/INTERACTION-CONTRACT.md) before changing product behavior.

## Local checks

```bash
swift build
swift test --filter LiteConnectionTests  # Lite-specific changes
bash scripts/build-lite-app.sh
python3 scripts/smoke-lite.py
```

Run the tests relevant to the changed subsystem; shared-core changes need affected Full and Lite coverage. Full CLI/HTTP smoke uses `python3 scripts/smoke.py`. Some existing core tests use the connection intent ledger: inspect and isolate state before running a broad suite on a daily-use machine. Never run physical display writes as part of CI or a casual smoke check.

For shared changes and release candidates, run the complete `swift test` suite in an isolated user environment or CI in addition to the relevant smoke checks. Keep hardware tests opt-in and target a specific display. Default tests must not change brightness or display topology. Use injectable transports and deterministic failures to exercise write verification, restoration and identity matching. Preserve the notices in LICENSES when moving derived code.

Lite simulation is explicit: `bash scripts/run-lite-app.sh --preview`. It uses fictional in-memory data. Plain `bash scripts/run-lite-app.sh` starts real read-only discovery; clicking a connection control can change the desktop. Do not operate someone else's devices or delete recovery records to make a test pass.

## Pull requests

Explain the concrete problem, changed behavior, affected product(s), checks actually run, and remaining device/installation gaps. Include before/after native screenshots for UI changes; distinguish simulations from physical results. Keep public CLI contracts, bundle identities, user data and licensing notices intact.

Full and Lite versions advance independently. Full retains `v<version>` tags, Lite uses `lite-v<version>`. Existing published assets are immutable: ship a new version for a fix. Packaging commands and the release checklist are documented in [MAINTENANCE.md](docs/MAINTENANCE.md).

The Swift 5 language mode on VibeDisplay targets is intentional until their concurrency migration is complete. Avoid changing public JSON fields or exit codes without documenting the migration. Do not include tokens, state snapshots, personal display inventories, internal repository URLs or account configuration in a contribution.
