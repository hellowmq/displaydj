import Foundation

// MARK: - Hotkey opt-in

extension DisplayBarController {
  var hotkeyDisplayName: String {
    BrightnessHotkey.displayName
  }

  /// Turns the keyboard observers on or off and persists the choice.
  func setHotkeysEnabled(_ enabled: Bool) {
    hotkeys.setEnabled(enabled)
    hotkeysEnabled = hotkeys.isEnabled
    refreshAccessibilityPermission()
  }

  /// Re-reads the accessibility trust state without triggering a system prompt.
  ///
  /// Repairing the observer is part of *this* call rather than a separate step, because every
  /// caller re-reads the trust for the same reason — the user may have changed it while the app
  /// was not looking — and that reason is exactly when a global observer created under the old
  /// trust has become dead. Splitting the two apart is how the notice came to be updated while
  /// the shortcut it described was left broken: the app knew trust had been granted, said so by
  /// removing its own explanation, and did the one thing that would have acted on it nowhere.
  func refreshAccessibilityPermission() {
    hasAccessibilityPermission = hotkeys.reconcileObservers()
  }

  /// Opens the accessibility pane so the user can grant trust deliberately.
  func openAccessibilitySettings() {
    hotkeys.openAccessibilitySettings()
  }
}

// MARK: - Recovery

extension DisplayBarController {
  /// Runs the way out that a specific failure offered.
  ///
  /// The failure is named by the caller rather than read from a shared slot, for the same
  /// reason the recoveries carry their target: several cards can be showing errors at once,
  /// so "the current failure" is not a thing that exists. A retry is only meaningful if it
  /// repeats the user's *intent* against the display that actually failed — resolving either
  /// from global state would aim it at whichever card happens to be selected now, so the
  /// write case would change an untouched monitor and the read case would leave the failing
  /// one stuck while re-reading its neighbour.
  func recover(from failure: BrightnessFailure) async {
    switch failure.recovery {
    case .retryRead(let displayStableID):
      clearFailure(for: displayStableID)
      await refreshDisplay(stableID: displayStableID)
    case .retryWrite(let value, let displayStableID):
      clearFailure(for: displayStableID)
      await setBrightness(value, for: displayStableID)
    case .rescan:
      // A rescan answers a topology-level failure; per-display banners are re-evaluated by
      // the scan itself and are not silenced pre-emptively here.
      failures.topology = nil
      await scanAndRefresh()
    case .unavailable:
      break
    }
  }

  /// Visible title of a failure's recovery button, or `nil` when there is nothing to offer.
  func recoveryActionTitle(for failure: BrightnessFailure) -> String? {
    switch failure.recovery {
    case .retryRead: "重新读取"
    case .retryWrite: "重试"
    case .rescan: "重新扫描"
    case .unavailable: nil
    }
  }
}
