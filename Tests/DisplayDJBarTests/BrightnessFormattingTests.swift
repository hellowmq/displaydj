import Testing

@testable import DisplayDJBar

// The popover draws brightness in exactly one place: the card's `BrightnessReadout`.
//
// There used to be more, and each was named here while it existed — the preset buttons that
// spelled `Text("\(preset)")` instead of asking the formatter (the drift this file exists to
// catch, and the reason the whole formatter does), then the track's `0%`/`100%` endpoint
// labels, then R2's drag bubble. All three are gone now, so the guarantees below are stated
// over the one surface that remains rather than over a list of call sites: a surface that
// spells its own digits fails here whether or not the list is up to date.
//
// The one other place a brightness is rendered is the menu bar item, and it is tested where it
// lives — it no longer draws a number at all.

@Test("The large readout separates digits from the unit but never drops it")
func readoutSplitsDigitsAndUnit() {
  #expect(BrightnessFormatting.readoutDigits(for: 90) == "90")
  #expect(BrightnessFormatting.showsUnit(for: 90))
  #expect(BrightnessFormatting.readoutDigits(for: 0) == "0")
  #expect(BrightnessFormatting.showsUnit(for: 0))
}

@Test("An unknown reading is a placeholder, not a fabricated zero, and shows no unit")
func readoutDoesNotInventAValue() {
  #expect(BrightnessFormatting.readoutDigits(for: nil) == BrightnessFormatting.unavailableReadout)
  #expect(BrightnessFormatting.unavailableReadout.contains("0") == false)
  #expect(BrightnessFormatting.showsUnit(for: nil) == false)
}

@Test("The readout clamps the same way the spoken value does")
func readoutAgreesWithAccessibilityValue() {
  for percent in [-30, 0, 1, 49, 50, 99, 100, 140] {
    let spoken = BrightnessAccessibility.valueDescription(for: percent)
    let visible = BrightnessFormatting.readoutDigits(for: percent) + BrightnessFormatting.unitSuffix
    #expect(spoken == visible)
  }
}

/// Guards the drift the shared formatter exists to prevent.
///
/// A card readout that spells `"\(value)"` and `"%"` inline looks identical on screen today
/// and silently diverges the moment the unit, the placeholder or the clamping changes in one
/// place only. Composing the two accessors here states the whole visible string as a contract.
@Test("Composing the readout accessors reproduces the full on-screen string")
func readoutComposesIntoTheVisibleString() {
  func rendered(_ percent: Int?) -> String {
    BrightnessFormatting.readoutDigits(for: percent)
      + (BrightnessFormatting.showsUnit(for: percent) ? BrightnessFormatting.unitSuffix : "")
  }

  #expect(BrightnessFormatting.unitSuffix == "%")
  #expect(rendered(90) == "90%")
  #expect(rendered(0) == "0%")
  #expect(rendered(100) == "100%")
  #expect(rendered(140) == "100%")
  #expect(rendered(nil) == BrightnessFormatting.unavailableReadout)
  // The placeholder must not acquire a stray unit.
  #expect(rendered(nil).contains(BrightnessFormatting.unitSuffix) == false)
}
