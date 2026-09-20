/// Whether the installed keyboard observers still match the trust they were installed under.
///
/// A global key observer is not a subscription that starts working once it is allowed to. It is
/// granted — or refused — its privileges at the moment it is created, and a refused one is
/// indistinguishable from a working one: it is a valid object, it is retained, and it silently
/// never fires. Nothing about it changes when macOS later grants the app accessibility trust.
///
/// So installation is a one-time side effect whose precondition keeps moving afterwards, and
/// the app already knows it moves: `popoverDidShow` re-reads the trust on every open precisely
/// because "the user may have changed it in System Settings while the popover was closed". That
/// re-read updated the *notice* and nothing else. The observer installed a moment earlier, under
/// no trust, stayed exactly as dead as it was.
///
/// The resulting sequence is worse than a plain silent failure, because the app walks the user
/// through it and then withdraws the explanation:
///
/// 1. The user enables the hotkeys before granting trust. A dead global observer is installed.
/// 2. The popover explains this and offers a button to the Accessibility settings.
/// 3. The user grants trust there and comes back.
/// 4. The next open re-reads the trust, sees it, and **removes the notice** — so the one line on
///    screen that accounted for the shortcut not working disappears.
/// 5. The shortcut still does nothing, for the rest of the process's life, and now nothing on
///    screen admits it. Only quitting the app fixes it, and nothing suggests that.
///
/// Re-creating the observer is the remedy: the new one is created under the trust now in force.
/// It is deliberately the *only* remedy applied — see the cases below for what is left alone.
enum HotkeyObserverAction: Equatable {
  /// The installed observers still match the current trust. Leave them alone.
  ///
  /// Not named `none`: as an `Optional` it would collide with `Optional.none` and quietly
  /// swallow a branch in every `switch`, which is the mistake `BrightnessRecovery.unavailable`
  /// and `RefreshScope.nothing` are already named around.
  case keepExisting
  /// Trust has been granted since the global observer was created, so it was created without
  /// it and cannot have picked it up. Replace it with one created under the trust in force.
  case reinstallGlobalObserver
}

/// The rule for keeping the keyboard observers in step with accessibility trust.
///
/// Split out as a plain value for the same reason as `ReadPass`, `ReadTrigger`, `SliderStep`
/// and `TargetedRead`: the decision can then be asserted directly, which matters more here than
/// anywhere else. The behaviour being protected is invisible by construction — a dead observer
/// looks exactly like a live one from inside the process — so a test that cannot inspect the
/// rule itself could not tell the defect from the fix.
enum HotkeyObservers {
  /// Decides what to do with the observers now that trust has been re-observed.
  ///
  /// `installedWithTrust` describes the observer that currently exists, not the app: it is the
  /// trust that was in force at the moment `NSEvent` handed the observer back. Comparing it
  /// against the trust in force now is the whole test, because that is the only comparison
  /// that can reveal an observer which outlived the conditions it was built for.
  ///
  /// Invariant assumed by the caller and stated here so it can be read in one place: observers
  /// exist if and only if `hotkeysEnabled` is true. Disabling removes every one of them rather
  /// than installing them and ignoring their events.
  static func action(
    hotkeysEnabled: Bool,
    installedWithTrust: Bool,
    isTrustedNow: Bool
  ) -> HotkeyObserverAction {
    // Checked first, and it outranks everything. With the hotkeys off there is no observer to
    // repair, and installing one here would be the exact thing PRD 1.2 forbids: observing the
    // keyboard without the user having opted in. Trust rising is not consent.
    guard hotkeysEnabled else { return .keepExisting }
    // Only the rise. Trust falling leaves an observer that no longer works, but a replacement
    // created under no trust would not work either, so replacing it buys nothing — while
    // recording the fall (the caller's job) is what lets a later grant read as a rise and be
    // repaired then.
    guard isTrustedNow, !installedWithTrust else { return .keepExisting }
    return .reinstallGlobalObserver
  }
}
