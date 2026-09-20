import AppKit
import ApplicationServices
import Foundation

/// A brightness hotkey the user can explicitly opt into.
///
/// The combination deliberately avoids `⌘=` / `⌘-`, which nearly every mac app uses for
/// zooming, and `⌥⌘=` / `⌥⌘-`, which macOS reserves for the accessibility zoom. Silently
/// stealing those would change page zoom or font size into a brightness change the user
/// never asked for.
enum BrightnessHotkey: Equatable {
  case increase
  case decrease

  /// Percentage points applied per key press.
  var delta: Int {
    switch self {
    case .increase:
      return 5
    case .decrease:
      return -5
    }
  }

  /// The exact modifier set an event must carry to be one of ours.
  static let requiredModifiers: NSEvent.ModifierFlags = [.control, .command]

  /// Human readable form used in the settings row.
  static let displayName = "⌃⌘=  /  ⌃⌘-"

  /// Resolves a key event to a hotkey, or `nil` when the event does not belong to us.
  ///
  /// The modifier comparison is an exact match, so any extra modifier (including a stray
  /// shift or option) leaves the event untouched for whichever app owns it.
  static func resolve(
    characters: String?,
    modifiers: NSEvent.ModifierFlags
  ) -> BrightnessHotkey? {
    guard modifiers.intersection(.deviceIndependentFlagsMask) == requiredModifiers else {
      return nil
    }
    switch characters {
    case "=", "+":
      return .increase
    case "-", "_":
      return .decrease
    default:
      return nil
    }
  }
}

/// Persisted opt-in for the brightness hotkeys.
///
/// An absent preference means disabled: the app never observes the keyboard until the
/// user turns it on in the popover.
struct BrightnessHotkeyPreference {
  static let defaultsKey = "DisplayDJBar.BrightnessHotkeysEnabled"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Hotkeys stay off until the user explicitly enables them.
  var isEnabled: Bool {
    get { defaults.bool(forKey: Self.defaultsKey) }
    nonmutating set { defaults.set(newValue, forKey: Self.defaultsKey) }
  }
}

/// Owns the keyboard observers so they exist only while the user has opted in.
///
/// No monitor is installed at launch. `setEnabled(false)` removes every monitor, so a
/// disabled app observes nothing at all rather than observing and then ignoring events.
@MainActor
final class BrightnessHotkeyCoordinator {
  private nonisolated(unsafe) var globalMonitor: Any?
  private nonisolated(unsafe) var localMonitor: Any?
  private var preference: BrightnessHotkeyPreference
  private let onTrigger: (BrightnessHotkey) -> Void
  /// Whether accessibility trust was in force when the current global observer was created.
  ///
  /// Recorded because it cannot be recovered afterwards. A global key observer created without
  /// trust is a perfectly valid object that never fires, so neither the observer nor `NSEvent`
  /// can be asked whether it works — the only way to know is to remember the conditions it was
  /// built under and compare them against the conditions now.
  private var globalMonitorHasTrust = false

  private(set) var isEnabled: Bool

  init(
    preference: BrightnessHotkeyPreference = BrightnessHotkeyPreference(),
    onTrigger: @escaping (BrightnessHotkey) -> Void
  ) {
    self.preference = preference
    self.onTrigger = onTrigger
    self.isEnabled = preference.isEnabled
  }

  /// Installs monitors only when the persisted choice is already an opt-in.
  func activateStoredPreference() {
    isEnabled = preference.isEnabled
    if isEnabled {
      installMonitors()
    }
  }

  func setEnabled(_ enabled: Bool) {
    preference.isEnabled = enabled
    isEnabled = enabled
    if enabled {
      installMonitors()
    } else {
      removeMonitors()
    }
  }

  /// Whether macOS grants the accessibility trust a global observer needs.
  /// Read-only: it never raises a system prompt on the user's behalf.
  func hasAccessibilityPermission() -> Bool {
    AXIsProcessTrusted()
  }

  /// Re-creates the global observer if it was created before trust was granted.
  ///
  /// Called whenever the app re-reads the trust, because that read is the only moment it can
  /// discover the change. `NSEvent` does not report it, the observer does not fail visibly, and
  /// the grant happens in System Settings while this app is not even frontmost.
  ///
  /// Returns the trust it observed so the caller can publish the same value it acted on, rather
  /// than reading `AXIsProcessTrusted()` a second time and possibly getting a different answer.
  @discardableResult
  func reconcileObservers() -> Bool {
    let isTrustedNow = hasAccessibilityPermission()
    switch HotkeyObservers.action(
      hotkeysEnabled: isEnabled,
      installedWithTrust: globalMonitorHasTrust,
      isTrustedNow: isTrustedNow
    ) {
    case .keepExisting:
      // Trust that has *fallen* is still recorded, even though nothing is reinstalled. The
      // record describes the observer, so leaving it claiming a trust that no longer holds
      // would make the eventual re-grant look like no change at all — and the dead observer
      // would then never be replaced.
      globalMonitorHasTrust = globalMonitorHasTrust && isTrustedNow
    case .reinstallGlobalObserver:
      // Only the global one. The local observer needs no trust and has been working all along;
      // tearing it down would introduce a gap for the sake of symmetry.
      removeGlobalMonitor()
      installMonitors()
    }
    return isTrustedNow
  }

  func openAccessibilitySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  private func installMonitors() {
    if globalMonitor == nil {
      globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
        self?.handle(event)
      }
      // Stamped at the moment of creation, because that is when the observer's privileges are
      // decided. Reading the trust later says what the *app* is allowed to do, not what this
      // particular observer was granted when it was made.
      globalMonitorHasTrust = hasAccessibilityPermission()
    }
    if localMonitor == nil {
      localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        self?.handle(event)
        return event
      }
    }
  }

  private func removeGlobalMonitor() {
    if let globalMonitor {
      NSEvent.removeMonitor(globalMonitor)
      self.globalMonitor = nil
    }
    globalMonitorHasTrust = false
  }

  private func removeMonitors() {
    removeGlobalMonitor()
    if let localMonitor {
      NSEvent.removeMonitor(localMonitor)
      self.localMonitor = nil
    }
  }

  private func handle(_ event: NSEvent) {
    guard isEnabled else { return }
    guard
      let hotkey = BrightnessHotkey.resolve(
        characters: event.charactersIgnoringModifiers,
        modifiers: event.modifierFlags
      )
    else { return }
    onTrigger(hotkey)
  }

  deinit {
    if let globalMonitor {
      NSEvent.removeMonitor(globalMonitor)
    }
    if let localMonitor {
      NSEvent.removeMonitor(localMonitor)
    }
  }
}
