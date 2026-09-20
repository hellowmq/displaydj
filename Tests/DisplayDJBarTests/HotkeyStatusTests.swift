import Testing

@testable import DisplayDJBar

// MARK: - Resolution

// The regression: the hotkey switch's spoken value was the constant `hotkeyDisplayName`. On a
// `Toggle`, `accessibilityValue` replaces the on/off state VoiceOver would otherwise speak, so
// the one thing a switch exists to convey was the one thing it never said — and in the
// untrusted state it announced a shortcut that does not fire, an inch above the visible line
// explaining that it does not fire.
//
// Defect family ⑫ sub-criterion C, raised from "several renderings of one control" to "several
// controls describing one state": the switch, its announcement and the notice below it are three
// renderings of the same question, and they were decided by three different rules. These tests
// pin them to one.

@Test("Trust is irrelevant until the user has opted in")
func hotkeyStatusIsOffWhateverTheTrustWhenDisabled() {
  #expect(HotkeyStatus.resolve(hotkeysEnabled: false, isTrusted: false) == .off)
  #expect(HotkeyStatus.resolve(hotkeysEnabled: false, isTrusted: true) == .off)
}

@Test("An opt-in without trust is neither off nor working")
func hotkeyStatusSeparatesAwaitingTrustFromBothOtherStates() {
  let awaiting = HotkeyStatus.resolve(hotkeysEnabled: true, isTrusted: false)

  #expect(awaiting == .awaitingTrust)
  #expect(awaiting != .off)
  #expect(awaiting != .active)
}

@Test("An opt-in with trust is active")
func hotkeyStatusIsActiveWhenTrusted() {
  #expect(HotkeyStatus.resolve(hotkeysEnabled: true, isTrusted: true) == .active)
}

// MARK: - The notice and the state it explains

@Test("The permission notice appears exactly when the shortcut is opted into but untrusted")
func hotkeyNoticeTracksAwaitingTrustAlone() {
  #expect(HotkeyStatus.awaitingTrust.showsPermissionNotice)
  #expect(HotkeyStatus.off.showsPermissionNotice == false)
  #expect(HotkeyStatus.active.showsPermissionNotice == false)
}

// MARK: - The announcement and the state it announces

@Test("The switch announces its state rather than restating the key combination")
func hotkeyToggleValueStatesTheStateNotTheShortcut() {
  let off = BrightnessAccessibility.hotkeyToggleValue(for: .off)
  let active = BrightnessAccessibility.hotkeyToggleValue(for: .active)

  // The exact defect: the value was `BrightnessHotkey.displayName` in every state, so the two
  // read identically and neither said whether the switch was on.
  #expect(off != active)
  #expect(off != BrightnessHotkey.displayName)
  #expect(active != BrightnessHotkey.displayName)
  #expect(off.contains("关"))
  #expect(active.contains("开"))
}

@Test("An untrusted opt-in is not announced as a working shortcut")
func hotkeyToggleValueDoesNotClaimAnUntrustedShortcutWorks() {
  let awaiting = BrightnessAccessibility.hotkeyToggleValue(for: .awaitingTrust)

  // It must not read as plain "on": the row says in visible text that the shortcut will not
  // fire, and the switch above it must not contradict that.
  #expect(awaiting != BrightnessAccessibility.hotkeyToggleValue(for: .active))
  #expect(awaiting != BrightnessAccessibility.hotkeyToggleValue(for: .off))
  #expect(awaiting.contains("授权"))
}

@Test("Every state is spoken, and no two states share a sentence")
func hotkeyToggleValueIsDistinctAndNonEmptyForEveryState() {
  // Stated over the same truth table `HotkeyStatus.resolve` is asserted on, so reintroducing a
  // constant — or a second rule beside the status — collapses two of these and fails here.
  var spoken: Set<String> = []
  for hotkeysEnabled in [true, false] {
    for isTrusted in [true, false] {
      let status = HotkeyStatus.resolve(hotkeysEnabled: hotkeysEnabled, isTrusted: isTrusted)
      let value = BrightnessAccessibility.hotkeyToggleValue(for: status)
      #expect(value.trimmingCharacters(in: .whitespaces).isEmpty == false)
      spoken.insert(value)
    }
  }
  // Three reachable states, three distinct sentences.
  #expect(spoken.count == 3)
}

@Test("The announcement agrees with the notice for every state")
func hotkeyToggleValueAgreesWithTheNotice() {
  // The contradiction that existed: a notice saying the shortcut will not work while the
  // switch announced it as working. Whenever the notice is shown, the spoken value must carry
  // the same reservation.
  for status in [HotkeyStatus.off, .active, .awaitingTrust] {
    let value = BrightnessAccessibility.hotkeyToggleValue(for: status)
    if status.showsPermissionNotice {
      #expect(value.contains("授权"))
    } else {
      #expect(value.contains("授权") == false)
    }
  }
}

@Test("The switch keeps a non-empty label distinct from its value")
func hotkeyToggleLabelIsPresent() {
  #expect(
    BrightnessAccessibility.hotkeyToggleLabel.trimmingCharacters(in: .whitespaces).isEmpty == false)
  #expect(BrightnessAccessibility.hotkeyToggleLabel != BrightnessHotkey.displayName)
}
