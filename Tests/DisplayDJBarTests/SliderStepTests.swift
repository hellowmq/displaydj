import Testing

@testable import DisplayDJBar

// What a keyboard or VoiceOver step is allowed to do when no reading exists.
//
// A keyboard step requires a measured starting value. The card also disables pointer input
// while the value is unknown, leaving an empty track until a read succeeds.
//
// The card's `±` buttons already made this distinction through `canAdjustRelatively`. The
// slider was handed only `canControl`, so its keyboard path stepped from `sliderValue`: a
// `@State` that starts at 50 and is only ever synced from readings that exist. On a display
// with no reading it therefore stepped from a number nothing had measured and sent the result
// to the hardware.

// MARK: - The defect

@Test("A step is refused when nothing is known to step from")
func stepRefusedWithoutReading() {
  // The regression: a控制得了的显示器，读数缺失时仍然会被步进。
  #expect(SliderStep.resolve(isEnabled: true, currentValue: nil) == .unavailable)
}

@Test("A step is refused on a display that cannot be controlled at all")
func stepRefusedWhenDisabled() {
  #expect(SliderStep.resolve(isEnabled: false, currentValue: 50) == .unavailable)
  #expect(SliderStep.resolve(isEnabled: false, currentValue: nil) == .unavailable)
}

@Test("A step proceeds from the reading when there is one")
func stepUsesTheReadingAsItsBaseline() {
  #expect(SliderStep.resolve(isEnabled: true, currentValue: 0) == .apply(from: 0))
  #expect(SliderStep.resolve(isEnabled: true, currentValue: 87) == .apply(from: 87))
  #expect(SliderStep.resolve(isEnabled: true, currentValue: 100) == .apply(from: 100))
}

// MARK: - Guards against over-correction

@Test("The baseline is never fabricated from the slider's drawn position")
func stepNeverInventsABaseline() {
  // `sliderValue` defaults to 50, so a fabricated baseline would show up as a step computed
  // from 50 on a display that never reported anything. Refusing is the only correct answer;
  // any `.apply` here would be that bug.
  let resolved = SliderStep.resolve(isEnabled: true, currentValue: nil)
  #expect(resolved != .apply(from: 50))
  #expect(resolved == .unavailable)
}

@Test("Enablement and a reading are both required, neither alone suffices")
func stepRequiresBothConditions() {
  // Stated as a truth table so dropping either half of the condition fails here rather than
  // silently restoring the fabricated baseline.
  struct Case {
    let isEnabled: Bool
    let reading: Int?
    let expectsApply: Bool
  }
  let cases = [
    Case(isEnabled: true, reading: 42, expectsApply: true),
    Case(isEnabled: true, reading: nil, expectsApply: false),
    Case(isEnabled: false, reading: 42, expectsApply: false),
    Case(isEnabled: false, reading: nil, expectsApply: false),
  ]
  for testCase in cases {
    let resolved = SliderStep.resolve(
      isEnabled: testCase.isEnabled,
      currentValue: testCase.reading
    )
    #expect((resolved != .unavailable) == testCase.expectsApply)
  }
}

@Test("The slider's rule agrees with the buttons' rule beside it")
func stepMatchesRelativeButtonAvailability() {
  // The `±` buttons use `canAdjustRelatively` = identity && reading exists. The slider's
  // keyboard path must answer identically, otherwise the same card offers two different
  // opinions about whether a relative change is possible — which is exactly what it did.
  for stableID in ["", "uuid:75490c7d-0000-0000-0000-000000000001"] {
    for reading: Int? in [nil, 0, 55, 100] {
      let canControl = !stableID.isEmpty
      let buttonsAllow = canControl && reading != nil
      let sliderAllows =
        SliderStep.resolve(isEnabled: canControl, currentValue: reading) != .unavailable
      #expect(buttonsAllow == sliderAllows)
    }
  }
}
