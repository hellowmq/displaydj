# Changelog

## 0.3.0 — Preview

- 新增 DDC 对比度/显示器音量服务、CLI 与 HTTP；继承读回验证、相对变更事务及失败恢复。
- 新增系统显示模式枚举、HiDPI/刷新率、预演与 session 模式切换。
- 新增按 UUID 和 transport 保存的亮度预设、存储锁、全量预检和失败回退。
- 菜单栏新增“显示设置与预设”窗口，调用内置主 CLI。
- 加强参数拒绝与选择器歧义检查；亮度基线/回读失败不再猜测结果。
- 菜单栏移除 Agent 服务入口；README 分开说明 App、独立 CLI 与可选后台服务。
- 唤醒后亮度未确认时显示灰色空轨道并禁用滑块；首次读取失败保持中性状态，重复失败才显示重试入口。
- 补充竞品追赶计划、接口文档、回归测试与本地运行入口。新硬件写入与 GUI 新窗口的验收边界见 VALIDATION；此版本未签名公证。


## 0.2.3 — Brand cyan controls

- Replace the legacy amber brightness fill with Spectral Cyan (`#55D9FF`).
- Share the same runtime color token across the slider, keyboard focus ring and selected-display treatment.
- Keep semantic lime, violet, amber and coral out of ordinary brightness progress.

## 0.2.2 — Signature Gap mark

- Reduce the brand mark to three elements: a rounded channel, a fixed right-side gap and a horizontal fader.
- Remove the central knob, cue, decorative arc, inner border and shadow-dependent detail from the app icon.
- Redraw the 18-point menu-bar template independently with the same silhouette and no circular elements.
- Make the smallest glyph the source of the size system and tighten the brand contract around silhouette-first recognition.

## 0.2.1 — DJ Gate identity system

- Replace the generic display-and-target composition with the asymmetric DisplayDJ DJ Gate: one calibration channel, one fader knob and one state cue.
- Make the same gate shape the menu-bar template mark, so the smallest product surface carries the same signature rather than a generic display outline.
- Add the brand-system rules for size reduction, semantic color use and cross-asset composition.

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
