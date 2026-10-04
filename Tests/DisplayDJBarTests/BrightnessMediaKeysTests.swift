import AppKit
import Testing
@testable import DisplayDJBar

@Suite("Brightness media key routing")
struct BrightnessMediaKeysTests {
  private func event(_ key: Int = 2, down: Bool = true, repeatKey: Bool = false,
                     modifiers: NSEvent.ModifierFlags = []) -> BrightnessMediaKeyEvent {
    BrightnessMediaKeyEvent.systemDefined(subtype: 8,
      data: key << 16 | (down ? 0x0a00 : 0x0b00) | (repeatKey ? 1 : 0), modifiers: modifiers)!
  }

  @Test func decodesOnlyBrightnessAndValidKeyStates() {
    for key in [0, 1, 7, 16, 17, 18, 21] {
      #expect(BrightnessMediaKeyEvent.systemDefined(subtype: 8, data: key << 16 | 0xa00, modifiers: []) == nil)
    }
    #expect(BrightnessMediaKeyEvent.systemDefined(subtype: 7, data: 2 << 16 | 0xa00, modifiers: []) == nil)
    #expect(BrightnessMediaKeyEvent.systemDefined(subtype: 8, data: 2 << 16 | 0xc00, modifiers: []) == nil)
    #expect(event().direction == .increase)
    #expect(event(3).direction == .decrease)
    #expect(event(repeatKey: true).isRepeat)
    #expect(!event(down: false).isDown)
  }

  @Test func ordinaryFunctionKeysAreNotMediaKeys() {
    for code in [0, 122, 120, 107, 113] {
      #expect(BrightnessMediaKeyEvent.functionKey(code: code, isDown: true, isRepeat: false, modifiers: []) == nil)
    }
    #expect(BrightnessMediaKeyEvent.functionKey(code: 144, isDown: true, isRepeat: true, modifiers: [])?.direction == .increase)
    #expect(BrightnessMediaKeyEvent.functionKey(code: 145, isDown: false, isRepeat: false, modifiers: [])?.isDown == false)
  }

  @Test @MainActor func realNSEventPayloadUsesSameDecoder() throws {
    let press = try #require(NSEvent.otherEvent(with: .systemDefined, location: .zero,
      modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
      subtype: 8, data1: 2 << 16 | 0xa00, data2: -1))
    let decoded = try #require(BrightnessMediaKeyEvent.decode(press))
    #expect(decoded.isDown && decoded.direction == .increase)
    let release = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
      isARepeat: false, keyCode: 145))
    #expect(BrightnessMediaKeyEvent.decode(release)?.isDown == false)
  }

  @Test func pressRepeatAndReleaseKeepOriginalTarget() {
    var routing = BrightnessMediaKeyRouting()
    #expect(routing.handle(event(), target: "A") == .init(consume: true, target: "A", delta: 5))
    #expect(routing.handle(event(repeatKey: true), target: "B") == .init(consume: true, target: "A", delta: 5))
    #expect(routing.handle(event(down: false, modifiers: .command), target: "B") == .init(consume: true))
    #expect(routing.handle(event(), target: "B").target == "B")
  }

  @Test func unknownTargetStaysSystemUntilRelease() {
    var routing = BrightnessMediaKeyRouting()
    #expect(!routing.handle(event(), target: nil).consume)
    #expect(!routing.handle(event(repeatKey: true), target: "A").consume)
    #expect(!routing.handle(event(down: false), target: "A").consume)
    #expect(routing.handle(event(), target: "A").consume)
  }

  @Test(arguments: [NSEvent.ModifierFlags.command, .control, .option, .shift])
  func modifiedPressIsNeverClaimed(modifier: NSEvent.ModifierFlags) {
    var routing = BrightnessMediaKeyRouting()
    #expect(!routing.handle(event(modifiers: modifier), target: "A").consume)
    #expect(!routing.handle(event(repeatKey: true), target: "A").consume)
    #expect(!routing.handle(event(down: false), target: "A").consume)
  }

  @Test func fnAndCapsLockDoNotDisableHardwareKeys() {
    var routing = BrightnessMediaKeyRouting()
    #expect(routing.handle(event(modifiers: [.function, .capsLock]), target: "A").consume)
  }

  @Test func enableOrWakeDuringExistingHoldDoesNotStealIt() {
    var routing = BrightnessMediaKeyRouting()
    #expect(!routing.handle(event(repeatKey: true), target: "A").consume)
    #expect(routing.handle(event(), target: "A").consume)
    routing.reset()
    #expect(!routing.handle(event(repeatKey: true), target: "A").consume)
    #expect(!routing.handle(event(down: false), target: "A").consume)
  }

  @Test @MainActor func optInIsIndependentAndDefaultsToDisabled() {
    let suite = "displaydj-media-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: BrightnessHotkeyPreference.defaultsKey)
    let coordinator = BrightnessMediaKeyCoordinator(defaults: defaults,
      target: { Issue.record("Disabled media keys must not resolve targets"); return nil },
      trigger: { _, _ in Issue.record("Disabled media keys must not trigger") }, statusChanged: { _ in })
    coordinator.activateStoredPreference()
    #expect(!coordinator.isEnabled)
    #expect(coordinator.status == .disabled)
    coordinator.setEnabled(false)
    #expect(defaults.bool(forKey: BrightnessHotkeyPreference.defaultsKey))
  }

  @Test @MainActor func storedOptInWithoutPermissionShowsBlockedStateAndCanStop() {
    let suite = "displaydj-media-permission-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: BrightnessMediaKeyCoordinator.defaultsKey)
    var statuses: [BrightnessMediaKeyStatus] = []
    let coordinator = BrightnessMediaKeyCoordinator(defaults: defaults,
      target: { Issue.record("Missing permission must not resolve targets"); return nil },
      trigger: { _, _ in Issue.record("Missing permission must not trigger") },
      statusChanged: { statuses.append($0) }, isTrusted: { false })
    coordinator.activateStoredPreference()
    #expect(coordinator.isEnabled)
    #expect(coordinator.status == .permissionRequired)
    coordinator.reconcile()
    #expect(statuses == [.permissionRequired])
    coordinator.setEnabled(false)
    coordinator.reconcile()
    #expect(statuses == [.permissionRequired, .disabled])
    #expect(!defaults.bool(forKey: BrightnessMediaKeyCoordinator.defaultsKey))
  }
}
