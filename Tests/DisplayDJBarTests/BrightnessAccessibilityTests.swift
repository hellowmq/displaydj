import SwiftUI
import Testing

@testable import DisplayDJBar

// MARK: - Spoken value

@Test("A known reading is spoken with its unit, an unknown one is not faked")
func accessibilityValueDescriptionCarriesUnit() {
  #expect(BrightnessAccessibility.valueDescription(for: 0) == "0%")
  #expect(BrightnessAccessibility.valueDescription(for: 42) == "42%")
  #expect(BrightnessAccessibility.valueDescription(for: 100) == "100%")
  #expect(
    BrightnessAccessibility.valueDescription(for: nil) == BrightnessAccessibility.unknownValue)
}

@Test("Out-of-range readings are clamped rather than spoken verbatim")
func accessibilityValueDescriptionClamps() {
  #expect(BrightnessAccessibility.valueDescription(for: -7) == "0%")
  #expect(BrightnessAccessibility.valueDescription(for: 140) == "100%")
}

// MARK: - Keyboard and VoiceOver adjustment

@Test("Arrow directions map to the track's own orientation")
func accessibilityMapsMoveCommandsToDeltas() {
  let step = BrightnessAccessibility.step

  #expect(BrightnessAccessibility.delta(for: .right) == step)
  #expect(BrightnessAccessibility.delta(for: .up) == step)
  #expect(BrightnessAccessibility.delta(for: .left) == -step)
  #expect(BrightnessAccessibility.delta(for: .down) == -step)
  #expect(step > 0)
}

@Test("Stepping stays inside 0...100 and never wraps")
func accessibilityAdjustmentSaturatesAtBounds() {
  let step = BrightnessAccessibility.step

  #expect(BrightnessAccessibility.adjusted(50, by: step) == 50 + step)
  #expect(BrightnessAccessibility.adjusted(50, by: -step) == 50 - step)
  #expect(BrightnessAccessibility.adjusted(BrightnessAccessibility.upperBound, by: step) == 100)
  #expect(BrightnessAccessibility.adjusted(BrightnessAccessibility.lowerBound, by: -step) == 0)
  #expect(BrightnessAccessibility.adjusted(98, by: step) == 100)
  #expect(BrightnessAccessibility.adjusted(2, by: -step) == 0)
}

// MARK: - Labels

@Test("The slider announces a role, a hint and the keyboard step it honours")
func accessibilitySliderLabelsAreDescriptive() {
  let hint = BrightnessAccessibility.sliderHint(for: .apply(from: 50))
  #expect(BrightnessAccessibility.sliderLabel.isEmpty == false)
  #expect(hint.contains("\(BrightnessAccessibility.step)%"))
  #expect(hint.contains("方向键"))
}

// MARK: - The hint and the step it describes

// The regression: the hint was a constant. `SliderStep` had already been corrected to refuse a
// relative step without a starting point, and `valueDescription` already said 未知 in that
// state — but the hint kept telling VoiceOver to press the arrow keys, which then did nothing
// and said nothing. A hand-drawn track has no button to grey out, so the sentence *is* the
// affordance, and it was describing one that had been withdrawn.
//
// Defect family ⑫ sub-criterion C: the explanation and the state it explains were decided by
// two different values. These tests pin them to one.

@Test("A hint is never given for a step that would be refused")
func accessibilityHintNeverPromisesARefusedStep() {
  let refused = BrightnessAccessibility.sliderHint(for: .unavailable)
  #expect(refused.contains("方向键") == false || refused.contains("无法"))
  #expect(refused != BrightnessAccessibility.sliderHint(for: .apply(from: 50)))
}

@Test("A disabled slider describes the missing reading")
func accessibilityHintExplainsUnknownBrightness() {
  let refused = BrightnessAccessibility.sliderHint(for: .unavailable)
  #expect(refused.trimmingCharacters(in: .whitespaces).isEmpty == false)
  #expect(refused.contains("亮度尚未确认"))
}

@Test("The hint agrees with the step rule for every state of it")
func accessibilityHintAgreesWithTheStepRule() {
  // Stated over the same truth table `SliderStep` is asserted on, so re-fabricating either
  // half — a constant hint, or a second `Bool` beside the step — fails here.
  for isEnabled in [true, false] {
    for reading: Int? in [nil, 0, 55, 100] {
      let resolved = SliderStep.resolve(isEnabled: isEnabled, currentValue: reading)
      let hint = BrightnessAccessibility.sliderHint(for: resolved)
      let invitesArrowKeys = hint == BrightnessAccessibility.sliderHint(for: .apply(from: 50))
      #expect(invitesArrowKeys == (resolved != .unavailable))
    }
  }
}

@Test("Every icon-only control carries a non-empty label")
func accessibilityIconControlsAreLabelled() {
  let labels = [
    BrightnessAccessibility.refreshLabel,
    BrightnessAccessibility.rescanLabel,
    BrightnessAccessibility.busyLabel,
    BrightnessAccessibility.displayPickerLabel,
    BrightnessAccessibility.currentBrightnessLabel,
    BrightnessAccessibility.statusItemName,
  ]
  for label in labels {
    #expect(label.trimmingCharacters(in: .whitespaces).isEmpty == false)
  }
}

@Test("The menu bar item is spoken by name and display count, never as a loose number")
func accessibilityStatusItemLabelIsSelfDescribing() {
  // The item sits among other apps' icons, so nothing around it supplies context. It shows the
  // sun icon only, so the label must name the app and the display count itself.
  let single = BrightnessAccessibility.statusItemLabel(displaysCount: 1)
  #expect(single.contains(BrightnessAccessibility.statusItemName))
  #expect(single.contains("1 台显示器"))

  let none = BrightnessAccessibility.statusItemLabel(displaysCount: 0)
  #expect(none.contains(BrightnessAccessibility.statusItemName))
  #expect(none.contains("未连接显示器"))
}

@Test("The menu bar label reports the count and never a single brightness value")
func accessibilityStatusItemLabelSharesNoValueVocabulary() {
  // With no number on screen, the spoken label must not invent one either — a single figure
  // would be ambiguous across displays. It names the app and the count instead.
  for count in [0, 1, 2, 3] {
    let label = BrightnessAccessibility.statusItemLabel(displaysCount: count)
    #expect(label.contains(BrightnessAccessibility.statusItemName))
    #expect(label.contains("%") == false)
  }
}

@Test("The error banner is announced as an error rather than as loose text")
func accessibilityErrorLabelIsPrefixed() {
  let label = BrightnessAccessibility.errorLabel("读取失败")
  #expect(label.contains("错误"))
  #expect(label.contains("读取失败"))
}
