# Changelog

## 0.2.0 — DisplayDJ visual identity

- Add the DisplayDJ application icon: a rounded display frame, vertical fader, brightness knob and restrained active cue, authored as a source SVG and packaged as an `.icns` bundle asset.
- Replace the menu-bar generic sun with the corresponding monochrome display-and-fader status mark, preserving macOS light/dark appearance behavior and accessibility labels.
- Include the app icon in the locally built application bundle and advance the unified product version to 0.2.0.

This entry describes local code and packaging assets, not a published GitHub release or a notarized distribution.

## 0.1.0 — New DisplayDJ project

- Start an independent product version and repository history; name the app DisplayDJ and the primary CLI display-cli.
- Combine DisplayDJ and VibeDisplay into one Swift package, with a DisplayDJ menu bar app, the main `display-cli` CLI and compatible `displaydj` CLI.
- Replace enumeration-order DDC pairing with DisplayDJ's identity-matched, read-back-verified hardware engine.
- Coordinate DDC transactions across app, CLI and daemon using a user-local process lock.
- Add connect/disconnect commands to the main CLI and an authenticated service status/start section to the app.
- Retain recovery snapshots when displays are unplugged or restoration fails; reject non-finite brightness expressions.
- Fix first-write atomic state persistence; validate HTTP loopback host and port bounds.
- Recognize the legacy M1 bare dcpext node only with matching external endpoint and complete framebuffer identity evidence.
- Add integration tests, isolated daemon smoke checks, app/ZIP packaging and GitHub Actions workflow.
- Preserve DisplayDJ, VibeDisplay and MonitorControl license provenance.

This entry describes local code, not a published GitHub release or a notarized distribution.
