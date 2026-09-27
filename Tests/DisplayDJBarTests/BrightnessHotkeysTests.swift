import AppKit
import Foundation
import DisplayDJCore
import Testing

@testable import DisplayDJBar

// MARK: - Hotkey resolution

@Test("Plain Command plus zoom keys are left to whichever app owns them")
func hotkeyIgnoresBareCommandZoomKeys() {
  #expect(BrightnessHotkey.resolve(characters: "=", modifiers: .command) == nil)
  #expect(BrightnessHotkey.resolve(characters: "+", modifiers: .command) == nil)
  #expect(BrightnessHotkey.resolve(characters: "-", modifiers: .command) == nil)
  #expect(BrightnessHotkey.resolve(characters: "_", modifiers: .command) == nil)
}

@Test("The opt-in combination resolves to a brightness change")
func hotkeyResolvesControlCommandCombination() {
  let modifiers = BrightnessHotkey.requiredModifiers

  #expect(BrightnessHotkey.resolve(characters: "=", modifiers: modifiers) == .increase)
  #expect(BrightnessHotkey.resolve(characters: "+", modifiers: modifiers) == .increase)
  #expect(BrightnessHotkey.resolve(characters: "-", modifiers: modifiers) == .decrease)
  #expect(BrightnessHotkey.resolve(characters: "_", modifiers: modifiers) == .decrease)

  #expect(BrightnessHotkey.increase.delta == 5)
  #expect(BrightnessHotkey.decrease.delta == -5)
}

@Test("Extra modifiers or unrelated characters never match")
func hotkeyRequiresExactModifiersAndKeys() {
  let exact = BrightnessHotkey.requiredModifiers

  #expect(BrightnessHotkey.resolve(characters: "=", modifiers: exact.union(.shift)) == nil)
  #expect(BrightnessHotkey.resolve(characters: "=", modifiers: exact.union(.option)) == nil)
  #expect(BrightnessHotkey.resolve(characters: "=", modifiers: .control) == nil)
  #expect(BrightnessHotkey.resolve(characters: "=", modifiers: []) == nil)
  #expect(BrightnessHotkey.resolve(characters: "a", modifiers: exact) == nil)
  #expect(BrightnessHotkey.resolve(characters: nil, modifiers: exact) == nil)
}

@Test("The advertised combination avoids the system zoom shortcuts")
func hotkeyAvoidsSystemZoomSemantics() {
  let required = BrightnessHotkey.requiredModifiers

  #expect(required != .command)
  #expect(required != [.option, .command])
  #expect(required.contains(.control))
  #expect(BrightnessHotkey.displayName.contains("⌃⌘"))
}

// MARK: - Opt-in preference

private func makeIsolatedDefaults(_ name: String) -> UserDefaults {
  let defaults = UserDefaults(suiteName: name)!
  defaults.removePersistentDomain(forName: name)
  return defaults
}

@Test("Hotkeys are disabled when the user has never made a choice")
func hotkeyPreferenceDefaultsToDisabled() {
  let suite = "DisplayDJBarTests.hotkeyDefault"
  let defaults = makeIsolatedDefaults(suite)
  defer { defaults.removePersistentDomain(forName: suite) }

  let preference = BrightnessHotkeyPreference(defaults: defaults)

  #expect(preference.isEnabled == false)
  #expect(defaults.object(forKey: BrightnessHotkeyPreference.defaultsKey) == nil)
}

@Test("An explicit opt-in round-trips and can be revoked")
func hotkeyPreferencePersistsExplicitChoice() {
  let suite = "DisplayDJBarTests.hotkeyPersistence"
  let defaults = makeIsolatedDefaults(suite)
  defer { defaults.removePersistentDomain(forName: suite) }

  let preference = BrightnessHotkeyPreference(defaults: defaults)

  preference.isEnabled = true
  #expect(BrightnessHotkeyPreference(defaults: defaults).isEnabled)

  preference.isEnabled = false
  #expect(BrightnessHotkeyPreference(defaults: defaults).isEnabled == false)
}

private func hotkeyDisplay(_ runtimeID: UInt32, _ stableID: String?) -> DisplayDescriptor {
  DisplayDescriptor(
    runtimeID: runtimeID,
    stableID: stableID,
    name: "Display \(runtimeID)",
    vendorID: 1,
    productID: 2,
    serialNumber: 3,
    isBuiltIn: runtimeID == 1,
    isVirtual: false,
    isMirrored: false
  )
}

@Test("Hotkey target defaults to the selected display and persists the pointer choice")
func hotkeyTargetPreferenceRoundTrips() {
  let suite = "DisplayDJBarTests.hotkeyTarget"
  let defaults = makeIsolatedDefaults(suite)
  defer { defaults.removePersistentDomain(forName: suite) }

  let preference = BrightnessHotkeyTargetPreference(defaults: defaults)
  #expect(preference.target == .selected)
  preference.target = .mouse
  #expect(BrightnessHotkeyTargetPreference(defaults: defaults).target == .mouse)
  defaults.set("unrecognised", forKey: BrightnessHotkeyTargetPreference.defaultsKey)
  #expect(preference.target == .selected)
}

@Test("Pointer target follows screen runtime identity, not the selected card")
func hotkeyPointerTargetUsesScreen() {
  let displays = [hotkeyDisplay(1, "built-in"), hotkeyDisplay(2, "hp")]
  #expect(BrightnessHotkeyTargetResolver.stableID(
    for: .selected, selectedStableID: "built-in", mouseScreenRuntimeID: 2,
    displays: displays
  ) == "built-in")
  #expect(BrightnessHotkeyTargetResolver.stableID(
    for: .mouse, selectedStableID: "built-in", mouseScreenRuntimeID: 2,
    displays: displays
  ) == "hp")
}

@Test("Unknown pointer screen or unstable identity never redirects to another display")
func hotkeyPointerTargetFailsClosed() {
  let displays = [hotkeyDisplay(1, "built-in"), hotkeyDisplay(2, nil)]
  for screenID in [UInt32?(nil), UInt32?(2), UInt32?(3)] {
    #expect(BrightnessHotkeyTargetResolver.stableID(
      for: .mouse, selectedStableID: "built-in", mouseScreenRuntimeID: screenID,
      displays: displays
    ) == nil)
  }
  #expect(BrightnessHotkeyTargetResolver.stableID(
    for: .selected, selectedStableID: "detached", mouseScreenRuntimeID: 1,
    displays: displays
  ) == nil)
}

@Test("Accessibility prompt follows only a fresh explicit opt-in without trust")
func accessibilityPromptFollowsFreshOptIn() {
  #expect(
    BrightnessHotkeyPermissionRequest.shouldPrompt(
      wasEnabled: false, isEnabled: true, isTrusted: false))
  #expect(
    BrightnessHotkeyPermissionRequest.shouldPrompt(
      wasEnabled: false, isEnabled: true, isTrusted: true) == false)
  #expect(
    BrightnessHotkeyPermissionRequest.shouldPrompt(
      wasEnabled: true, isEnabled: true, isTrusted: false) == false)
  #expect(
    BrightnessHotkeyPermissionRequest.shouldPrompt(
      wasEnabled: true, isEnabled: false, isTrusted: false) == false)
}
