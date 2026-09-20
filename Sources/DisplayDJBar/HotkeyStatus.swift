/// What state the brightness hotkeys are actually in — one decision, read by every surface
/// that describes them.
///
/// The settings row draws three things about the shortcut, and until now they were decided by
/// three different rules:
///
/// * the switch itself, drawn from `hotkeysEnabled`;
/// * the permission notice below it, drawn from `hotkeysEnabled && !hasAccessibilityPermission`;
/// * the switch's spoken value, drawn from **nothing at all** — it was
///   `.accessibilityValue(controller.hotkeyDisplayName)`, and `hotkeyDisplayName` is the
///   constant `"⌃⌘=  /  ⌃⌘-"`.
///
/// That third one is the defect, and it is worse than a missing description, because
/// `accessibilityValue` on a `Toggle` does not *add* to the state VoiceOver speaks — it
/// replaces it. So the one thing a switch exists to convey was the one thing it stopped
/// conveying: VoiceOver read "亮度快捷键，⌃⌘= / ⌃⌘-" whether the shortcut was on or off, and a
/// user who could not see the switch had no way to find out which. The key combination is
/// already on screen as a label beside it; the state was not anywhere.
///
/// It also repeats round 39's mistake one control over. There the slider's hint was a constant
/// promising arrow keys that `SliderStep` would refuse; here the switch's value is a constant
/// naming a shortcut that, without accessibility trust, does not fire. In the `awaitingTrust`
/// state the row already says so in visible text — and the switch, an inch above it, went on
/// announcing the shortcut as though it worked.
///
/// Split out as a plain value for the same reason as `SliderStep`, `SliderTrack`, `SliderSync`,
/// `ReadPass`, `ReadTrigger`, `TargetedRead` and `HotkeyObservers`, and with the addition
/// `SliderTrack` established: the thing being described and the description of it are the same
/// question, so they are answered here once and both consumers read the answer.
enum HotkeyStatus: Equatable {
  /// The user has not opted in. Nothing observes the keyboard.
  ///
  /// Deliberately not named `none`: as `HotkeyStatus?` it would collide with `Optional.none`
  /// and silently swallow a branch in every `switch`, the same trap `SliderTrack.unknown`,
  /// `SliderStep.unavailable`, `SliderSync.keep` and `RefreshScope.nothing` are named around.
  case off
  /// Opted in, and macOS grants the trust a global observer needs. The shortcut works.
  case active
  /// Opted in, but without accessibility trust the global observer never fires.
  ///
  /// Kept distinct from `off` rather than folded into it. The switch really is on, and saying
  /// otherwise would invite the user to turn on something already turned on; what is missing
  /// is outside the app, and only the user can grant it.
  case awaitingTrust

  /// Resolves the state the shortcut is really in.
  ///
  /// Trust is only consulted once the user has opted in. With the hotkeys off no observer
  /// exists, so whether the app *could* have installed a working one says nothing the user
  /// needs — and reporting a permission problem against a feature that is switched off is how
  /// an opt-in starts reading like a prerequisite.
  static func resolve(hotkeysEnabled: Bool, isTrusted: Bool) -> HotkeyStatus {
    guard hotkeysEnabled else { return .off }
    return isTrusted ? .active : .awaitingTrust
  }

  /// Whether the row explains the missing authorisation.
  ///
  /// Shared with the spoken value above on purpose: the notice and the announcement are two
  /// renderings of one state, and deciding them separately is exactly how the switch came to
  /// announce a working shortcut directly above a line saying it would not work.
  var showsPermissionNotice: Bool {
    switch self {
    case .awaitingTrust: true
    case .off, .active: false
    }
  }
}
