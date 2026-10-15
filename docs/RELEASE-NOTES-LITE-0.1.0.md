# DisplayDJ Lite 0.1.0 — local release candidate

2026-10-16. Not published. Full remains at 1.0.2.

Lite is a separate menu-bar app for taking one external display out of the Mac desktop and reconnecting it later. It preserves its own recovery records, verifies connection results and keeps recovery available after failures. It does not turn off display power, switch inputs, preserve a disconnected desktop preview, or provide Full brightness/CLI/service features.

The candidate includes the approved Lite icon, a compact native panel, explicit disconnect confirmation with a safe cancel default, stable display rows, inline progress/errors, keyboard refresh/quit, and restore-before-quit choices. A saved recovery entry is labelled as a record, not as proof that a device is currently connected.

Safety update: normal quit now requires verified restoration; there is no keep-disconnected exit option. New Lite disconnects use the application's CoreGraphics lifetime (`forAppOnly`), while reconnection is committed to the login session to clear legacy session-scoped disables. Another disconnect is blocked while current recovery is pending. Historical records with a reused runtime ID are retained and cannot operate the replacement screen. A recovery child process must acknowledge its parent-exit monitor before a new disconnect; it restores applicable Lite targets after GUI termination, then exits. This installs no login item or system service. Application scope alone failed on the test device; it is not the recovery guarantee. The connection entry point is private. See [recovery and uninstall instructions](LITE-RECOVERY.md).

Full and Lite use one packaging implementation with separate identities, executable sets and versions. ZIP is the default; `--format all` produces ZIP/DMG from the same App and verifies each archive and checksum.

Distribution scope: arm64; macOS 13 deployment target. The current local build is ad-hoc signed and unnotarized. This is not evidence of clean first install, minimum-OS execution or broad monitor compatibility. Install Lite separately as `DisplayDJLite.app`; do not replace Full's `DisplayDJ.app`. Recovery/diagnostic evidence and remaining hardware acceptance are recorded in [DISPLAYDJ-LITE.md](DISPLAYDJ-LITE.md).

Publication requires a fixed source commit/tag, package checks, the maintenance checklist and explicit release authorization. Do not treat this draft as an available download or a paid offer.

## Verification status / 验证状态

- 717 tests passed in a verified isolated Foundation user directory; tests used fake transactions and isolated storage; physical-device verification is listed separately.
- Installed Lite was replaced at `/Applications/DisplayDJLite.app`; bundle identity/signature/bytes and the running process path were checked. The old bundle is backed up and the recovery file was preserved.
- Native quit offers only restore-and-quit or cancel. Escape cancellation leaves the process and recovery entry available.
- Physical verification on Apple M1/macOS 27.0.1 and Dell D2720DS passed: ordinary reconnect, restore-and-quit, and guardian recovery after SIGKILL of the GUI (~7.3 seconds). The guardian then exited, Dell's record cleared, and the absent HP historical record remained.
- The earlier scope-only SIGKILL attempt failed; the display was explicitly recovered before adding the guardian. See [device evidence and limits](LITE-DEVICE-VERIFICATION.md).
- **Still a draft:** not published. HP physical recovery, visual quality after reconnect, minimum-OS execution, clean first install and wider device compatibility remain unverified. Simultaneous termination of the GUI and guardian is not covered.

远端应用仓库原来只有 Full 图标，本次新增 Lite 图标与真实安装实例截图；网站上原有 Full 1.0.2 设置预览仍对应完整版，未被 Lite 图片覆盖。图片维护清单见 [PREVIEW-ASSETS.md](PREVIEW-ASSETS.md)。
