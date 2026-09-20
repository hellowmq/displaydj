import AppKit
import Foundation
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
