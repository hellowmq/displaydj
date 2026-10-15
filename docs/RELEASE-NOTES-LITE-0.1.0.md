# DisplayDJ Lite 0.1.0 — local release candidate

2026-10-16. Not published. Full remains at 1.0.2.

Lite is a separate menu-bar app for taking one external display out of the Mac desktop and reconnecting it later. It preserves its own recovery records, verifies connection results and keeps recovery available after failures. It does not turn off display power, switch inputs, preserve a disconnected desktop preview, or provide Full brightness/CLI/service features.

The candidate includes the approved Lite icon, a compact native panel, explicit disconnect confirmation with a safe cancel default, stable display rows, inline progress/errors, keyboard refresh/quit, and restore-before-quit choices. A saved recovery entry is labelled as a record, not as proof that a device is currently connected.

Safety update: normal quit now requires verified restoration; there is no keep-disconnected exit option. New Lite disconnects use the application's CoreGraphics lifetime (`forAppOnly`), while reconnection is committed to the login session to clear legacy session-scoped disables. Another disconnect is blocked while recovery records remain. This uses the OS configuration lifetime, not an uninstall hook or a permanent helper. The connection entry point is private; process-termination rollback still needs physical-device validation. See [recovery and uninstall instructions](LITE-RECOVERY.md).

Full and Lite use one packaging implementation with separate identities, executable sets and versions. ZIP is the default; `--format all` produces ZIP/DMG from the same App and verifies each archive and checksum.

Distribution scope: arm64; macOS 13 deployment target. The current local build is ad-hoc signed and unnotarized. This is not evidence of clean first install, minimum-OS execution or broad monitor compatibility. Install Lite separately as `DisplayDJLite.app`; do not replace Full's `DisplayDJ.app`. Recovery/diagnostic evidence and remaining hardware acceptance are recorded in [DISPLAYDJ-LITE.md](DISPLAYDJ-LITE.md).

Publication requires a fixed source commit/tag, package checks, the maintenance checklist and explicit release authorization. Do not treat this draft as an available download or a paid offer.

## Verification status / 验证状态

- 712 tests passed in a verified isolated Foundation user directory; actual user recovery files, the intent ledger and Full installed binary remained unchanged during the full suite.
- Installed Lite was replaced at `/Applications/DisplayDJLite.app`; bundle identity/signature/bytes and the running process path were checked. The old bundle is backed up and the recovery file was preserved.
- Native quit offers only restore-and-quit or cancel. Escape cancellation leaves the process and recovery entry available.
- The system currently enumerates only the built-in display. A reconnect attempt for the exact saved HP D27k target failed and retained its record. This is not a successful physical recovery test or proof of permanent damage.
- **Public-release gate remains open:** validate a newly disconnected external display returning on normal quit and process termination, plus successful legacy-record recovery. The CoreGraphics scope tests prove the selected API calls, not WindowServer behavior on every device. This candidate should remain a draft until that device evidence is resolved.

远端应用仓库原来只有 Full 图标，本次新增 Lite 图标与真实安装实例截图；网站上原有 Full 1.0.2 设置预览仍对应完整版，未被 Lite 图片覆盖。图片维护清单见 [PREVIEW-ASSETS.md](PREVIEW-ASSETS.md)。
