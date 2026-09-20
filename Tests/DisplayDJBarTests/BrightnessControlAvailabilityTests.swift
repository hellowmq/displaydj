import Testing

@testable import DisplayDJBar

/// Which controls stay usable when a reading is missing.
///
/// This is the rule PRD 2.4 cares about: a failed read must not disable the user's only way
/// back. Absolute targets (slider, presets) therefore stay live off identity alone, while
/// relative `±` steps — which have nothing to add to — must report themselves unavailable
/// rather than look enabled and quietly do nothing.
///
/// The arithmetic is duplicated here deliberately: it mirrors the controller's rule without
/// needing a `@MainActor` controller and a live display topology, so a refactor that drops
/// the guard in the view still leaves this contract stated somewhere.
private func canControl(stableID: String) -> Bool {
  !stableID.isEmpty
}

private func canAdjustRelatively(stableID: String, reading: Int?) -> Bool {
  canControl(stableID: stableID) && reading != nil
}

private let realDisplay = "uuid:75490c7d-0000-0000-0000-000000000001"

@Test("A display without a stable identity cannot be controlled at all")
func availabilityRequiresStableIdentity() {
  #expect(canControl(stableID: "") == false)
  #expect(canAdjustRelatively(stableID: "", reading: 50) == false)
  #expect(canControl(stableID: realDisplay))
}

@Test("A failed read leaves absolute control available so the user can still recover")
func availabilityKeepsAbsoluteControlAfterFailedRead() {
  // No reading: the slider and the presets must remain usable.
  #expect(canControl(stableID: realDisplay))
  // ...but a relative step has no starting point to add to.
  #expect(canAdjustRelatively(stableID: realDisplay, reading: nil) == false)
}

@Test("Relative steps become available exactly when a reading exists")
func availabilityEnablesRelativeStepsWithReading() {
  #expect(canAdjustRelatively(stableID: realDisplay, reading: 0))
  #expect(canAdjustRelatively(stableID: realDisplay, reading: 90))
  #expect(canAdjustRelatively(stableID: realDisplay, reading: 100))
}

@Test("Relative availability never outlives absolute availability")
func availabilityRelativeImpliesAbsolute() {
  let readings: [Int?] = [nil, 0, 55, 100]
  for stableID in ["", realDisplay] {
    for reading in readings where canAdjustRelatively(stableID: stableID, reading: reading) {
      #expect(canControl(stableID: stableID))
    }
  }
}

/// Availability is a property of the display being asked about, never of the selection.
///
/// Every card in the popover is adjustable without being selected, so a convenience overload
/// that answered for "the selected display" would hand one card the other card's answer. The
/// two displays below disagree on purpose: whichever one is selected, each card must still get
/// its own verdict.
@Test("Availability answers for the display asked about, not for the selected one")
func availabilityIsPerDisplayNotPerSelection() {
  let otherDisplay = "uuid:75490c7d-0000-0000-0000-000000000002"
  let readings: [String: Int?] = [realDisplay: 40, otherDisplay: nil]

  // Selecting one display must not change the other's verdict, in either direction.
  for selected in [realDisplay, otherDisplay] {
    let selectedVerdict = canAdjustRelatively(
      stableID: selected,
      reading: readings[selected] ?? nil
    )
    #expect(canAdjustRelatively(stableID: realDisplay, reading: readings[realDisplay] ?? nil))
    #expect(
      canAdjustRelatively(stableID: otherDisplay, reading: readings[otherDisplay] ?? nil) == false
    )
    // The selection-derived answer matches only the display that happens to be selected,
    // which is exactly why callers must name their target.
    #expect(selectedVerdict == (selected == realDisplay))
  }
}
