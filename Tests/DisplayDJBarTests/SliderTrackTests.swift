import Testing

@testable import DisplayDJBar

// What the slider is allowed to *draw* when no reading exists.
//
// Round 32 established the rule for the step path: a relative change needs a starting point,
// and a non-optional baseline is what makes "there is no reading" impossible to express, so
// the drawn default (50) stood in for the missing one and the keyboard wrote a fabricated
// number to the hardware.
//
// The geometry was left reading that same non-optional. `trackFillWidth` and `thumbOffset`
// computed from `isDragging ? dragValue : value`, a `Double` that starts at 50 and is only
// synced from readings that exist — the card's re-sync is `guard let brightness = newValue`,
// so a nil reading is skipped and the last drawn position simply stays. A display whose read
// had failed therefore said "no reading" in its readout (`--`), in its spoken value (未知) and
// in its disabled `±` buttons, while the largest element on the card drew a half-filled track
// with the thumb parked mid-way — asserting a brightness nothing had measured, and doing it in
// the one place the user's next gesture is judged against.
//
// These assertions are about the resolved value rather than the view, for the same reason the
// rest of the module's rules are: a SwiftUI geometry cannot be inspected in a test, but the
// decision it draws from can.

// MARK: - The defect

@Test("No reading means no drawn position")
func unknownWhenThereIsNoReading() {
  // The regression: `value` still holds the50 it was initialised with, and the track drew it.
  let resolved = SliderTrack.resolve(
    isDragging: false,
    dragValue: 50,
    value: 50,
    hasReading: false
  )
  #expect(resolved == .unknown)
  #expect(resolved.fillRatio == 0)
  #expect(resolved.showsThumb == false)
}

@Test("An empty track is not a claim of zero")
func emptyTrackWithholdsTheThumb() {
  // Zero fill and zero brightness must not look the same. A real 0% keeps its thumb — that is
  // a measured value — while an unknown withholds it, so the empty track cannot be read as a
  // display sitting at 0.
  let unknown = SliderTrack.resolve(
    isDragging: false,
    dragValue: 50,
    value: 50,
    hasReading: false
  )
  let measuredZero = SliderTrack.resolve(
    isDragging: false,
    dragValue: 0,
    value: 0,
    hasReading: true
  )
  #expect(unknown.fillRatio == measuredZero.fillRatio)
  #expect(unknown.showsThumb == false)
  #expect(measuredZero.showsThumb)
}

@Test("A reading is drawn at the position it reports")
func readingIsDrawnWhereItSays() {
  for percent in [0.0, 1.0, 37.0, 99.0, 100.0] {
    let resolved = SliderTrack.resolve(
      isDragging: false,
      dragValue: 50,
      value: percent,
      hasReading: true
    )
    #expect(resolved == .position(percent: percent))
    #expect(resolved.fillRatio == percent / 100)
    #expect(resolved.showsThumb)
  }
}

// MARK: - The drag exception

@Test("A drag draws the finger's position even with no reading")
func dragOutranksAMissingReading() {
  // Geometry still follows a drag if one is already active; the card prevents a new drag
  // while the reading is unknown.
  let resolved = SliderTrack.resolve(
    isDragging: true,
    dragValue: 72,
    value: 50,
    hasReading: false
  )
  #expect(resolved == .position(percent: 72))
  #expect(resolved.showsThumb)
  #expect(resolved.steppableValue == 72)
}

@Test("A drag renders from the drag value, not the binding")
func dragRendersFromTheDragValue() {
  // The two variables disagree for the length of every gesture; the mode flag decides which
  // one is authoritative, and the geometry must follow the same flag the readout does.
  let resolved = SliderTrack.resolve(
    isDragging: true,
    dragValue: 20,
    value: 80,
    hasReading: true
  )
  #expect(resolved == .position(percent: 20))
}

// MARK: - One rule, two consumers

@Test("What is drawn and what is stepped from are the same number")
func geometryAndStepAgree() {
  // The defect was two parallel answers to "is there a number here that means something?" —
  // the step path said no and the geometry said 50. Any future divergence fails here.
  struct Case {
    let isDragging: Bool
    let dragValue: Double
    let value: Double
    let hasReading: Bool
  }
  let cases = [
    Case(isDragging: false, dragValue: 50, value: 50, hasReading: false),
    Case(isDragging: false, dragValue: 50, value: 63, hasReading: true),
    Case(isDragging: true, dragValue: 12, value: 88, hasReading: false),
    Case(isDragging: true, dragValue: 12, value: 88, hasReading: true),
    Case(isDragging: false, dragValue: 0, value: 0, hasReading: true),
    Case(isDragging: false, dragValue: 100, value: 100, hasReading: true),
  ]
  for testCase in cases {
    let resolved = SliderTrack.resolve(
      isDragging: testCase.isDragging,
      dragValue: testCase.dragValue,
      value: testCase.value,
      hasReading: testCase.hasReading
    )
    // A drawn position must be steppable, and an undrawn one must not be.
    #expect(resolved.showsThumb == (resolved.steppableValue != nil))
    if let steppable = resolved.steppableValue {
      #expect(Double(steppable) == (resolved.fillRatio * 100).rounded())
    } else {
      #expect(resolved.fillRatio == 0)
    }
  }
}

@Test("The drawing rule agrees with the step rule it replaced")
func trackMatchesSliderStep() {
  // `SliderStep` is still the gate the keyboard passes through; this type only supplies its
  // baseline. Feeding one from the other must not change any answer round 32 established.
  for hasReading in [true, false] {
    for isEnabled in [true, false] {
      let resolved = SliderTrack.resolve(
        isDragging: false,
        dragValue: 50,
        value: 50,
        hasReading: hasReading
      )
      let step = SliderStep.resolve(isEnabled: isEnabled, currentValue: resolved.steppableValue)
      #expect((step != .unavailable) == (isEnabled && hasReading))
    }
  }
}

@Test("The baseline is never fabricated from the drawn default")
func neverStepsFromTheDefault() {
  // `value` and `dragValue` both initialise to 50, so a fabricated baseline surfaces as a
  // steppable 50 on a display that never reported anything.
  let resolved = SliderTrack.resolve(
    isDragging: false,
    dragValue: 50,
    value: 50,
    hasReading: false
  )
  #expect(resolved.steppableValue == nil)
}

// MARK: - Bounds

@Test("Out-of-range positions cannot overflow the track")
func fillRatioIsClamped() {
  // The bound value is a `Double` fed by gestures and by hardware readings, neither of which
  // this type controls, so theratio it hands to the layout is clamped rather than trusted.
  let high = SliderTrack.resolve(isDragging: false, dragValue: 0, value: 140, hasReading: true)
  let low = SliderTrack.resolve(isDragging: false, dragValue: 0, value: -20, hasReading: true)
  #expect(high.fillRatio == 1)
  #expect(low.fillRatio == 0)
  #expect(high.steppableValue == 100)
  #expect(low.steppableValue == 0)
}
