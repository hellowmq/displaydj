import AppKit
import ApplicationServices

/// Only brightness events are decoded. Ordinary F-keys and audio keys pass through.
/// Event encoding cross-checked against IOKit ev_keymap.h and MediaKeyTap (see PROVENANCE).
struct BrightnessMediaKeyEvent {
  let key: Int
  let direction: BrightnessHotkey
  let isDown: Bool
  let isRepeat: Bool
  let modifiers: NSEvent.ModifierFlags

  static func decode(_ event: NSEvent) -> Self? {
    switch event.type {
    case .systemDefined:
      return systemDefined(subtype: event.subtype.rawValue, data: event.data1,
                           modifiers: event.modifierFlags)
    case .keyDown, .keyUp:
      return functionKey(code: Int(event.keyCode), isDown: event.type == .keyDown,
                         isRepeat: event.type == .keyDown && event.isARepeat,
                         modifiers: event.modifierFlags)
    default: return nil
    }
  }

  static func systemDefined(subtype: Int16, data: Int,
                            modifiers: NSEvent.ModifierFlags) -> Self? {
    guard subtype == 8 else { return nil } // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    let code = (data >> 16) & 0xffff
    guard code == 2 || code == 3 else { return nil }
    let state = (data >> 8) & 0xff
    guard state == 0x0a || state == 0x0b else { return nil }
    return Self(key: code, direction: code == 2 ? .increase : .decrease,
                isDown: state == 0x0a, isRepeat: data & 1 != 0, modifiers: modifiers)
  }

  static func functionKey(code: Int, isDown: Bool, isRepeat: Bool,
                          modifiers: NSEvent.ModifierFlags) -> Self? {
    guard code == 144 || code == 145 else { return nil }
    return Self(key: code, direction: code == 144 ? .increase : .decrease,
                isDown: isDown, isRepeat: isRepeat, modifiers: modifiers)
  }
}

struct BrightnessMediaKeyDecision: Equatable {
  var consume = false
  var target: String?
  var delta = 0
}

/// Keep both handled and passed-through presses stable until release. In particular,
/// moving the pointer during a hold cannot turn a system press into an app press.
struct BrightnessMediaKeyRouting {
  private enum Press { case system, display(String) }
  private var presses: [Int: Press] = [:]

  mutating func handle(_ event: BrightnessMediaKeyEvent, target: String?) -> BrightnessMediaKeyDecision {
    if !event.isDown {
      if case .display = presses.removeValue(forKey: event.key) {
        return BrightnessMediaKeyDecision(consume: true)
      }
      return BrightnessMediaKeyDecision()
    }
    if !event.isRepeat {
      let modified = !event.modifiers.intersection([.command, .control, .option, .shift]).isEmpty
      if let target, !target.isEmpty, !modified {
        presses[event.key] = .display(target)
      } else {
        presses[event.key] = .system
      }
    }
    guard case .display(let id) = presses[event.key] else { return BrightnessMediaKeyDecision() }
    return BrightnessMediaKeyDecision(consume: true, target: id, delta: event.direction.delta)
  }

  mutating func reset() { presses.removeAll() }
}

enum BrightnessMediaKeyStatus: Equatable {
  case disabled, permissionRequired, active, unavailable

  var message: String {
    switch self {
    case .disabled: "使用键盘上的亮度键调节目标显示器"
    case .permissionRequired: "需要辅助功能权限，授权后自动重试"
    case .active: "亮度键已启用；长按期间固定目标显示器"
    case .unavailable: "亮度键监听未启动，请检查权限或重新启用"
    }
  }
}

/// An active tap is necessary to prevent macOS adjusting its own target a second time.
/// Its callback only resolves the target and queues work; no hardware I/O runs in the tap.
@MainActor
final class BrightnessMediaKeyCoordinator {
  static let defaultsKey = "DisplayDJBar.BrightnessMediaKeysEnabled"
  private let defaults: UserDefaults
  private let isTrusted: () -> Bool
  private let target: () -> String?
  private let trigger: (String, Int) -> Void
  private let statusChanged: (BrightnessMediaKeyStatus) -> Void
  private nonisolated(unsafe) var port: CFMachPort?
  private nonisolated(unsafe) var source: CFRunLoopSource?
  private nonisolated(unsafe) var permissionTimer: Timer?
  private var routing = BrightnessMediaKeyRouting()
  private(set) var status: BrightnessMediaKeyStatus = .disabled
  private(set) var isEnabled = false

  init(defaults: UserDefaults = .standard, target: @escaping () -> String?,
       trigger: @escaping (String, Int) -> Void,
       statusChanged: @escaping (BrightnessMediaKeyStatus) -> Void,
       isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
    self.defaults = defaults
    self.target = target
    self.trigger = trigger
    self.statusChanged = statusChanged
    self.isTrusted = isTrusted
  }

  func activateStoredPreference() {
    updateEnabled(defaults.bool(forKey: Self.defaultsKey))
  }

  func setEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: Self.defaultsKey)
    updateEnabled(enabled)
  }

  private func updateEnabled(_ enabled: Bool) {
    isEnabled = enabled
    if enabled, permissionTimer == nil {
      // Grants/revocations also matter while another application has focus.
      let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.reconcile() }
      }
      RunLoop.main.add(timer, forMode: .common)
      permissionTimer = timer
    } else if !enabled {
      permissionTimer?.invalidate()
      permissionTimer = nil
    }
    reconcile()
  }

  func reconcile() {
    guard isEnabled else { stopTap(); updateStatus(.disabled); return }
    guard isTrusted() else { stopTap(); updateStatus(.permissionRequired); return }
    if let port, CGEvent.tapIsEnabled(tap: port) {
      updateStatus(.active)
      return
    }
    stopTap()
    let mask = CGEventMask(1 << NSEvent.EventType.systemDefined.rawValue)
      | CGEventMask(1 << CGEventType.keyDown.rawValue)
      | CGEventMask(1 << CGEventType.keyUp.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, context in
      guard let context else { return Unmanaged.passUnretained(event) }
      // The source is registered exclusively on the main run loop.
      let consumed = MainActor.assumeIsolated {
        Unmanaged<BrightnessMediaKeyCoordinator>.fromOpaque(context)
          .takeUnretainedValue().consumes(type: type, event: event)
      }
      return consumed ? nil : Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else { updateStatus(.unavailable); return }
    guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      CFMachPortInvalidate(tap)
      updateStatus(.unavailable)
      return
    }
    port = tap
    source = runLoopSource
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    updateStatus(CGEvent.tapIsEnabled(tap: tap) ? .active : .unavailable)
  }

  private func consumes(type: CGEventType, event: CGEvent) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      routing.reset()
      // Reconciliation outside the callback repairs the tap and publishes its status.
      updateStatus(.unavailable)
      return false
    }
    guard isEnabled, let nsEvent = NSEvent(cgEvent: event),
          let key = BrightnessMediaKeyEvent.decode(nsEvent), isTrusted() else {
      return false
    }
    let decision = routing.handle(key, target: key.isDown && !key.isRepeat ? target() : nil)
    if let id = decision.target { trigger(id, decision.delta) }
    return decision.consume
  }

  func resetPressedKeys() { routing.reset() }

  private func updateStatus(_ next: BrightnessMediaKeyStatus) {
    guard status != next else { return }
    status = next
    statusChanged(next)
  }

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
  }
}
