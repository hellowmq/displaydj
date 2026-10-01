<div align="center">

# DisplayDJ

**Control brightness, switch modes, and take a display off your Mac desktop without unplugging it.**

A macOS menu bar app and standalone CLI for hands-on display control and automation.

**English** | [简体中文](README.zh-CN.md)

[![macOS checks](https://github.com/hellowmq/displaydj/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/hellowmq/displaydj/actions/workflows/ci.yml)

`macOS 13+ target` · `Swift 6` · `Apple Silicon DDC/CI` · `MIT`

[Download latest release](https://github.com/hellowmq/displaydj/releases/latest) · [Quick start](#quick-start) · [CLI / HTTP reference](docs/API.md)

</div>

DisplayDJ treats display connection as a control, not a cable chore. Disconnect one display and it disappears from the macOS desktop layout, so windows move to the displays that remain online. Reconnect it later from the menu bar or `display-cli`. This is different from dimming the panel or sending a DDC sleep command.

The same app also controls brightness, contrast, monitor volume, display modes, and named brightness profiles. Its standalone CLI works without opening the app or running a daemon; an optional local HTTP service is available when an automation needs persistent state.

<p align="center">
  <img src="Assets/DisplayDJIcon.svg" alt="DisplayDJ icon" width="160">
</p>

## Why DisplayDJ

- **Disconnect without unplugging:** take one display out of the macOS desktop and bring it back later. DisplayDJ records the target, verifies the topology change, and refuses unsafe requests involving multiple displays, mirror sets, or the last online display.
- **Control more than brightness:** use native backlight control for built-in panels, DDC brightness/contrast/volume for supported external displays, explicit per-display Gamma dimming, display modes, profiles, shortcuts, and optional percentage-based brightness sync.
- **Use the interface you need:** work from the menu bar, run `display-cli` by itself in scripts, or start the token-protected loopback HTTP service only when persistent automation needs it.
- **Make writes observable:** DDC operations use stable display identity, baseline reads, independent readback, restoration attempts, and a shared interprocess lock rather than treating a requested value as success.

Connection switching uses private macOS APIs and is hardware/system dependent. DisplayDJ exposes support when the required system entry point is available; see [Compatibility](#compatibility) for the tested boundary.

## Ways to use DisplayDJ

| Entry point | Best for | Implemented capabilities |
| --- | --- | --- |
| **DisplayDJ.app** | Everyday desktop use | Brightness cards, scroll-wheel control, optional shortcuts, aliases and sorting, disconnect/reconnect; a display settings window with per-display Gamma, display modes, external-display volume and contrast, brightness profiles, and optional hardware-brightness synchronization |
| **display-cli** | Terminal users, scripts, and coding agents | Display discovery, brightness, restore, disconnect/reconnect, keep-awake, task lifecycle, diagnostics, and service management; no app or background service required |
| **Optional local service** | Automations that need HTTP access or state that persists across commands | Bearer-token authentication, Gamma, keep-awake leases, sessions, and heartbeats; started and stopped through the CLI |

The `displaydj` compatibility command is also retained, so existing `get brightness` and `set brightness` scripts continue to work. It preserves the legacy JSON schema and exit codes rather than mixing them with the new CLI contract.

## Quick start

### Download the app

Download the arm64 ZIP or DMG from the [latest release](https://github.com/hellowmq/displaydj/releases/latest). The bundle includes `DisplayDJ.app`, the standalone `display-cli`, and the legacy-compatible `displaydj` command.

The current downloads are for Apple Silicon only. They use ad-hoc signing and are not Developer ID signed or Apple-notarized, so macOS may block the first launch. Control-click DisplayDJ in Finder and choose **Open**, or allow it in **System Settings → Privacy & Security**. Global shortcuts require Accessibility permission; if they do not work immediately after authorization, quit and reopen DisplayDJ. See the [release notes](docs/RELEASE-NOTES-1.0.1.md) for the complete installation and compatibility notes.

### Install the command-line tool

The ZIP and DMG contain the CLI inside the app bundle; they do not install it on your PATH. After placing `DisplayDJ.app` in `/Applications`, you can run it directly:

```bash
/Applications/DisplayDJ.app/Contents/MacOS/display-cli doctor --json
```

To use `display-cli` from any directory, copy the bundled executable into your user directory. Opening the app is not required:

```bash
mkdir -p "$HOME/.local/bin"
cp /Applications/DisplayDJ.app/Contents/MacOS/display-cli "$HOME/.local/bin/display-cli"
export PATH="$HOME/.local/bin:$PATH"
display-cli version --json
display-cli doctor --json
```

Add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` for future terminals. Copy the executable again after updating the app to update the CLI. For legacy scripts, also copy `Contents/MacOS/displaydj`. CLI-only users can copy the executable directly out of the ZIP's app bundle without installing or opening the menu bar app. macOS download security checks still apply on first execution.

### Everyday CLI use

These examples use `display-cli` installed on your PATH. Replace `UUID` and `MODE_ID` with actual values from the discovery commands.

```bash
display-cli doctor --json
display-cli displays --json

# Copy a target UUID from the displays output; brightness is 0…1 or an explicit percentage
display-cli brightness set 60% --display 'uuid:<UUID>'
display-cli brightness set +5% --display 'uuid:<UUID>'
display-cli brightness restore

# Keep the system awake only while one command is running
display-cli keepawake run -- make test

# Let the task lifecycle manage start, running, completion, and restoration
# The default configuration changes display brightness, so inspect it first
display-cli config show
display-cli agent run --label 'test suite' -- make test
```

### Optional background service

Ordinary CLI operations do not require the service. Start it only when you need HTTP access, Gamma dimming or leases that persist after a command exits, or agent sessions managed across commands. The settings window also provides an explicit start button, and the CLI can stop the service afterward. Install the login item only if you explicitly want the service to start after login.

```bash
display-cli serve --detach
display-cli daemon status
display-cli daemon stop

# Optional: start after login; run daemon uninstall to disable autostart
display-cli daemon install
display-cli daemon uninstall
```

Run the background service only when persistent state or HTTP access is needed; the app does not automatically install a login item or start the service. If you installed the login item with `daemon install`, the service will restart after `daemon stop`; use `daemon uninstall` to disable autostart. See the [architecture documentation](docs/ARCHITECTURE.md) for module relationships and migration notes.

## Connection control, from the app or CLI

Each online display card includes a disconnect control when the operation is available and safe. Displays taken offline by DisplayDJ remain listed in a dedicated section with a **Reconnect** action. The CLI exposes the same workflow with structured output for scripts:

```bash
# Find the stable UUID of the target display
display-cli displays --json

# Remove one display from the macOS desktop, then bring it back
display-cli disconnect --display 'uuid:<UUID>'
display-cli connect --display 'uuid:<UUID>'
```

Disconnecting is intentionally limited to one stable target at a time. DisplayDJ will not disconnect a mirrored display or the last online display. A saved reconnect record is retained when verification fails, so a later reconnect can still recover the target.

## More display controls

DisplayDJ supports external-display contrast and volume, selection among display modes already exposed by macOS, and named brightness profiles. These capabilities are available through the main CLI and HTTP API, while the menu bar app opens a **Display Settings & Profiles** window. Related write operations support `--dry-run` previews. On one current HP D27k connection, v1.0.0 completed small DDC brightness and contrast writes, independent readback, and restoration. This result does not generalize to other displays or connection paths.

```bash
# Use the CLI by itself; the menu bar app does not need to be running
display-cli volume get --display external --json
display-cli contrast set 60% --display 'uuid:<UUID>' --dry-run --json
display-cli modes list --display main --json
display-cli modes set MODE_ID --display 'uuid:<UUID>' --dry-run --json

# Save current brightness, preview the change, then apply it
# Applying a profile that contains Gamma settings requires the local service
display-cli profile save work
display-cli profile apply work --dry-run --json
display-cli profile apply work

# Open the installed app’s display settings window
open -a DisplayDJ --args --display-tools
```

## Reliability guarantees and limits

- **Identity matching:** DDC associates DisplayDJ services with display identities instead of pairing two enumerated lists by position. Legacy `ddcServiceIndex` configuration is rejected to avoid controlling the wrong display.
- **Write verification:** DisplayDJ reads a baseline before a DDC write and independently verifies the value afterward. If verification fails, it attempts restoration and reports the result instead of presenting the requested value as readback.
- **Cross-process coordination:** DDC operations from the app, main CLI, and compatibility CLI share a per-user lock. The lock is released automatically when a process exits; timeout returns a busy result instead of forcing hardware access.
- **Retryable restoration:** Snapshots remain available when a display is disconnected or restoration fails. DisplayDJ 1.0.1 also retires an Agent's old restore point when you take manual control of that display.
- **Local interface:** HTTP listens only on loopback interfaces and requires a token by default. Configuration and tokens are stored under `~/.displaydj/` by default.
- **Disconnect safeguards:** DisplayDJ rejects batch disconnects, disconnecting mirrored displays, and disconnecting the last online display.

Restoration is not an absolute guarantee. `SIGKILL` prevents cleanup, although saved snapshots can be restored explicitly later. DDC and private system APIs may hang or become unavailable depending on the device, cable, adapter, or macOS version. Gamma is software dimming that requires a running process; it is not hardware backlight control.

## Compatibility

| Capability | Current boundary |
| --- | --- |
| Apple Silicon external-display DDC | Uses DisplayDJ's shared read/write implementation; on one current HP D27k connection, v1.0.0 verified brightness and contrast writes, readback, and restoration. That display does not support DDC volume control |
| Built-in display brightness | Uses the DisplayServices backend in the main CLI and HTTP API; v1.0.0 completed a small write, independent readback, and restoration |
| Intel external-display DDC | No production read/write path; software Gamma may be available |
| macOS 13/14 | Deployment target starts at macOS 13; v1.0.0 was physically tested only on this machine running macOS 27, without minimum-version installation or hardware acceptance testing |
| Display disconnect/reconnect | Depends on private APIs; v1.0.0 previously completed disconnect, reconnect, and topology readback on one current Dell connection. Other devices do not yet have equivalent evidence |
| App and agent dimming at the same time | DisplayDJ 1.0.1 gives manual brightness changes priority per display; existing Agent sessions skip further changes and restoration on that display. This requires matching app/CLI/service versions sharing the same state directory; v1.0.0 does not provide this behavior |
| Distribution | arm64 ZIP, DMG, and SHA-256 files; ad-hoc signed and not notarized, with no universal build or Developer ID validation yet |

## Development and packaging

### Build from source

You need macOS 13+, a Swift 6.0+ toolchain, and Python 3 for packaging and smoke tests only. The first build fetches Apple's `swift-argument-parser`; the main CLI, hardware core, and HTTP layer do not themselves use that dependency.

#### Menu bar app

```bash
swift build
bash scripts/build-app.sh
open '.build/DisplayDJ.app'
```

#### Standalone CLI

```bash
swift build -c release --product display-cli
bin_dir="$(swift build -c release --show-bin-path)"
mkdir -p "$HOME/.local/bin"
cp "$bin_dir/display-cli" "$HOME/.local/bin/display-cli"
export PATH="$HOME/.local/bin:$PATH"
display-cli version --json
```

GitHub Actions runs the same core checks on `macos-15` for every push and pull request:

```bash
swift build
swift test
python3 scripts/smoke.py
bash scripts/build-app.sh

# Optional: produce ad-hoc-signed ZIP or DMG archives for the host architecture
bash scripts/package.sh
bash scripts/package-dmg.sh
```

Tests cover both original test suites and their integration boundaries. The smoke test uses an isolated state directory, probes real displays read-only, and verifies service authentication and shutdown. `package.sh` and `package-dmg.sh` write `outputs/displaydj-<version>-macos-<architecture>.*` plus checksums by default. They refuse to overwrite an existing file; set `DISPLAYDJ_OUTPUT_DIR` to choose a fresh destination. These scripts do not upload to GitHub or modify Applications.

- [CLI and HTTP reference](docs/API.md)
- [Agent integration](docs/AGENT-INTEGRATION.md)
- [Architecture and migration](docs/ARCHITECTURE.md)
- [Provenance and licensing](docs/PROVENANCE.md)
- [Validation results](docs/VALIDATION.md)
- [1.0.1 release notes](docs/RELEASE-NOTES-1.0.1.md)
- [1.0 acceptance checklist](docs/RELEASE-1.0-CHECKLIST.md)
- [Staged device validation](docs/DEVICE-VALIDATION.md)
- [Dual-display UI acceptance procedure](docs/GUI-ACCEPTANCE-1.0.md)
- [Dell D2720DS probe record](docs/HARDWARE.md)
- [Future milestones](docs/ROADMAP.md)

## License and acknowledgements

DisplayDJ is licensed under the MIT License; see [LICENSE](LICENSE) and [LICENSES](LICENSES). Portions of the implementation are derived from MonitorControl, and the project retains the **MonitorControl Contributors** copyright and license notice. See [provenance and licensing](docs/PROVENANCE.md) for module-level details.

Maintainer: [@hellowmq](https://github.com/hellowmq). Repository: [hellowmq/displaydj](https://github.com/hellowmq/displaydj).
