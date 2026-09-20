import Testing

@testable import DisplayDJBar

// When the card's slider adopts the display's reading.
//
// The regression: `sliderValue` is a `@State Double` starting at 50, and the only thing that
// ever moved it was `.onChange(of: displayedBrightness)`. `onChange` reports *differences*, so
// it is silent about the value a card is born holding — and the reading routinely predates the
// card. The popover is `.transient`, so closing it destroys the SwiftUI content and reopening
// builds fresh `@State` at 50 while `brightnessByID` survives untouched; a hotkey pressed before
// the popover was ever opened reads the hardware first as well. In both cases `displayedBrightness`
// is unchanged from the card's point of view, `onChange` never fires, and the slider draws 50
// beside a readout showing the real number — and steps from50 too, since `SliderTrack` derives
// `steppableValue` from the same bound value.
//
// These assertions are about the resolved decision rather than the view, for the same reason the
// rest of the module's rules are: SwiftUI state cannot be inspected in a test, but the value the
// view acts on can.

private let anyReading = 63

// MARK: - The defect

@Test("An appearing card adopts a reading that already exists")
func appearingCardAdoptsExistingReading() {
  // The regression: nothing fired on appear, so the card kept its 50.
  let resolved = SliderSync.resolve(
    reading: anyReading,
    isDragging: false,
    occasion: .cardAppeared
  )
  #expect(resolved == .adopt(value: 63, animated: false))
}

@Test("Appearing at a value is not animated; a value arriving later is")
func onlyLaterChangesAnimate() {
  // Appearing at a number is not motion the user can perceive as such — animating it slides the
  // thumb in from a position the display never held. A reading that lands while the card is on
  // screen genuinely is motion.
  let appeared = SliderSync.resolve(reading: 40, isDragging: false, occasion: .cardAppeared)
  let changed = SliderSync.resolve(reading: 40, isDragging: false, occasion: .readingChanged)
  #expect(appeared == .adopt(value: 40, animated: false))
  #expect(changed == .adopt(value: 40, animated: true))
}

@Test("Both occasions adopt the same number")
func bothOccasionsAgreeOnTheValue() {
  // The animation is the *only* thing allowed to differ between them. Any other divergence is
  // the two-rules-for-one-question shape that left one of them missing in the first place.
  for reading in [0, 1, 37, 99, 100] {
    let appeared = SliderSync.resolve(
      reading: reading,
      isDragging: false,
      occasion: .cardAppeared
    )
    let changed = SliderSync.resolve(
      reading: reading,
      isDragging: false,
      occasion: .readingChanged
    )
    guard
      case .adopt(let appearedValue, _) = appeared,
      case .adopt(let changedValue, _) = changed
    else {
      Issue.record("both occasions must adopt a reading of \(reading)")
      return
    }
    #expect(appearedValue == changedValue)
  }
}

// MARK: - What must not be adopted

@Test("A drag outranks any reading, on either occasion")
func dragIsNeverInterrupted() {
  // The finger is the authority on where the control sits; a poll landing underneath it would
  // drag the thumb out from under the user. This exclusion was in the original `onChange`
  // guard and must be inherited by the appearing path rather than re-remembered there.
  for occasion in [SliderSync.Occasion.cardAppeared, .readingChanged] {
    #expect(SliderSync.resolve(reading: 20, isDragging: true, occasion: occasion) == .keep)
  }
}

@Test("No reading means nothing to adopt")
func missingReadingIsNotAdopted() {
  // The slider must not fall back to a default here. `SliderTrack` already refuses to draw a
  // position without a reading, so inventing one would only reintroduce the fabricated 50 that
  // round 37 removed from the geometry.
  for occasion in [SliderSync.Occasion.cardAppeared, .readingChanged] {
    #expect(SliderSync.resolve(reading: nil, isDragging: false, occasion: occasion) == .keep)
  }
}

// MARK: - Bounds

@Test("An out-of-range reading cannot be adopted verbatim")
func adoptedValueIsClamped() {
  // The reading comes from hardware this type does not control, and the number it yields is fed
  // straight into the track geometry and the step baseline.
  let high = SliderSync.resolve(reading: 140, isDragging: false, occasion: .cardAppeared)
  let low = SliderSync.resolve(reading: -20, isDragging: false, occasion: .cardAppeared)
  #expect(high == .adopt(value: 100, animated: false))
  #expect(low == .adopt(value: 0, animated: false))
}

// MARK: - Agreement with what gets drawn

@Test("What is adopted is what the track will then draw and step from")
func adoptedValueSurvivesIntoTheTrack() {
  // The point of adopting at all is that the slider stops contradicting the readout. Feeding the
  // adopted number through `SliderTrack` must therefore reproduce the reading exactly — the
  // defect was the track drawing 50 while the readout showed something else.
  for reading in [0, 12, 63, 100] {
    guard
      case .adopt(let value, _) = SliderSync.resolve(
        reading: reading,
        isDragging: false,
        occasion: .cardAppeared
      )
    else {
      Issue.record("a reading of \(reading) must be adopted")
      return
    }
    let track = SliderTrack.resolve(
      isDragging: false,
      dragValue: 50,
      value: value,
      hasReading: true
    )
    #expect(track.steppableValue == reading)
    #expect(track.fillRatio == Double(reading) / 100)
  }
}

@Test("Refusing to adopt leaves the track with nothing to fabricate")
func keepingLeavesNoPositionBehind() {
  // The pairing that matters: when there is no reading, `SliderSync` declines *and* the track
  // refuses to draw — so the untouched `@State` default is never rendered. If either half were
  // dropped, the 50 would surface again.
  #expect(SliderSync.resolve(reading: nil, isDragging: false, occasion: .cardAppeared) == .keep)
  let track = SliderTrack.resolve(
    isDragging: false,
    dragValue: 50,
    value: 50,
    hasReading: false
  )
  #expect(track == .unknown)
  #expect(track.steppableValue == nil)
}
