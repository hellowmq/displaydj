import AppKit
import ApplicationServices
import Foundation
import DisplayDJCore

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
  static let displayName = "⌃⌘-  /  ⌃⌘="

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

/// The screen a hotkey controls. The existing selected-display behaviour stays the default.
enum BrightnessHotkeyTarget: String, CaseIterable {
  case selected
  case mouse

  var title: String {
    switch self {
    case .selected: "选中的显示器"
    case .mouse: "鼠标所在显示器"
    }
  }
}

struct BrightnessHotkeyTargetPreference {
  static let defaultsKey = "DisplayDJBar.BrightnessHotkeyTarget"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var target: BrightnessHotkeyTarget {
    get {
      guard let raw = defaults.string(forKey: Self.defaultsKey) else { return .selected }
      return BrightnessHotkeyTarget(rawValue: raw) ?? .selected
    }
    nonmutating set { defaults.set(newValue.rawValue, forKey: Self.defaultsKey) }
  }
}

/// Decides when enabling the opt-in should ask macOS for Accessibility access.
///
/// A stored opt-in at launch must not raise a surprise system prompt, and repeatedly writing
/// `true` must not nag. The prompt is tied only to the user's off-to-on action while trust is
/// still missing.
enum BrightnessHotkeyPermissionRequest {
  static func shouldPrompt(
    wasEnabled: Bool,
    isEnabled: Bool,
    isTrusted: Bool
  ) -> Bool {
    !wasEnabled && isEnabled && !isTrusted
  }
}

/// Resolve an event against a snapshot of the topology; never fall back to another display
/// when the pointer is on an unknown or recently disconnected screen.
enum BrightnessHotkeyTargetResolver {
  static func stableID(
    for target: BrightnessHotkeyTarget,
    selectedStableID: String?,
    mouseScreenRuntimeID: UInt32?,
    displays: [DisplayDescriptor]
  ) -> String? {
    let candidate: String?
    switch target {
    case .selected:
      candidate = selectedStableID
    case .mouse:
      candidate = displays.first(where: { $0.runtimeID == mouseScreenRuntimeID })?.stableID
    }
    guard let candidate, !candidate.isEmpty,
      displays.contains(where: { $0.stableID == candidate }) else { return nil }
    return candidate
  }
}

/// Keeps ownership until release, including when modifiers are released before the key.
/// A repeat without an observed initial press must stay with the original application.
struct BrightnessHotkeyRouting {
  private enum Owner { case application, brightness(BrightnessHotkey) }
  private var pressed: [UInt16: Owner] = [:]

  mutating func handle(keyCode: UInt16, isDown: Bool, isRepeat: Bool,
                       characters: String?, modifiers: NSEvent.ModifierFlags)
    -> (consume: Bool, hotkey: BrightnessHotkey?) {
    if !isDown {
      if case .brightness = pressed.removeValue(forKey: keyCode) {
        return (true, nil)
      }
      return (false, nil)
    }
    if !isRepeat {
      if let hotkey = BrightnessHotkey.resolve(characters: characters, modifiers: modifiers) {
        pressed[keyCode] = .brightness(hotkey)
      } else {
        pressed[keyCode] = .application
      }
    }
    guard case .brightness(let hotkey) = pressed[keyCode] else { return (false, nil) }
    // Continue swallowing the captured press, but stop changing brightness if modifiers change.
    return (true, modifiers.intersection(.deviceIndependentFlagsMask)
      == BrightnessHotkey.requiredModifiers ? hotkey : nil)
  }

  mutating func reset() { pressed.removeAll() }
}

/// An active event tap consumes shortcuts before they reach the foreground application.
/// The local monitor is a fallback when global interception is unavailable, never a second handler.
@MainActor
final class BrightnessHotkeyCoordinator {
  private nonisolated(unsafe) var port: CFMachPort?
  private nonisolated(unsafe) var source: CFRunLoopSource?
  private nonisolated(unsafe) var localMonitor: Any?
  private nonisolated(unsafe) var permissionTimer: Timer?
  private var routing = BrightnessHotkeyRouting()
  private var preference: BrightnessHotkeyPreference
  private let onTrigger: (BrightnessHotkey) -> Void
  private(set) var isEnabled: Bool

  init(preference: BrightnessHotkeyPreference = BrightnessHotkeyPreference(),
       onTrigger: @escaping (BrightnessHotkey) -> Void) {
    self.preference = preference
    self.onTrigger = onTrigger
    self.isEnabled = preference.isEnabled
  }

  func activateStoredPreference() {
    isEnabled = preference.isEnabled
    updateMonitors()
  }

  func setEnabled(_ enabled: Bool) {
    preference.isEnabled = enabled
    isEnabled = enabled
    updateMonitors()
  }

  func hasAccessibilityPermission() -> Bool { AXIsProcessTrusted() }

  @discardableResult
  func requestAccessibilityPermission() -> Bool {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  @discardableResult
  func reconcileObservers() -> Bool {
    let trusted = hasAccessibilityPermission()
    guard isEnabled, trusted else {
      if port != nil { stopTap() }
      return trusted
    }
    let active = port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
    if HotkeyObservers.action(hotkeysEnabled: isEnabled,
                             installedWithTrust: active, isTrustedNow: trusted)
      == .reinstallGlobalObserver {
      stopTap()
      installTap()
    }
    return trusted
  }

  func openAccessibilitySettings() {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    ) else { return }
    NSWorkspace.shared.open(url)
  }

  private func updateMonitors() {
    guard isEnabled else {
      permissionTimer?.invalidate()
      permissionTimer = nil
      stopTap()
      if let localMonitor { NSEvent.removeMonitor(localMonitor) }
      localMonitor = nil
      return
    }
    if localMonitor == nil {
      localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
        [weak self] event in
        guard let self else { return event }
        // A functioning tap has already decided whether this event belongs to us.
        if let port = self.port, CGEvent.tapIsEnabled(tap: port) { return event }
        return self.handle(event) ? nil : event
      }
    }
    if permissionTimer == nil {
      let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { _ = self?.reconcileObservers() }
      }
      RunLoop.main.add(timer, forMode: .common)
      permissionTimer = timer
    }
    reconcileObservers()
  }

  private func installTap() {
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
      | CGEventMask(1 << CGEventType.keyUp.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, context in
      guard let context else { return Unmanaged.passUnretained(event) }
      let consumed = MainActor.assumeIsolated {
        let owner = Unmanaged<BrightnessHotkeyCoordinator>.fromOpaque(context).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
          owner.resetPressedKeys()
          return false
        }
        guard owner.hasAccessibilityPermission(),
              let nsEvent = NSEvent(cgEvent: event) else { return false }
        return owner.handle(nsEvent)
      }
      return consumed ? nil : Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: mask, callback: callback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else { return }
    guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      CFMachPortInvalidate(tap)
      return
    }
    port = tap
    source = runLoopSource
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  private func handle(_ event: NSEvent) -> Bool {
    guard isEnabled, event.type == .keyDown || event.type == .keyUp else { return false }
    let decision = routing.handle(keyCode: event.keyCode, isDown: event.type == .keyDown,
                                  isRepeat: event.type == .keyDown && event.isARepeat,
                                  characters: event.charactersIgnoringModifiers,
                                  modifiers: event.modifierFlags)
    if let hotkey = decision.hotkey { onTrigger(hotkey) }
    return decision.consume
  }

  func resetPressedKeys() { routing.reset() }

  private func stopTap() {
    if let source { CFRunLoopSourceInvalidate(source) }
    if let port { CFMachPortInvalidate(port) }
    source = nil
    port = nil
    routing.reset()
  }

  deinit {
    permissionTimer?.invalidate()
    if let source { CFRunLoopSourceInvalidate(source) }
    if let port { CFMachPortInvalidate(port) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
  }
}
