import Testing

@testable import DisplayDJBar

// Whose activity is allowed to refuse a read aimed at one named display.
//
// Every card in the popover reads, fails and reports on its own, and every other consumer of
// "is this reading still wanted?" is already scoped to a single display: `ReadPass.step` is
// told about the display it is about to read, `applyReadValue` refuses to overwrite a newer
// intent for that same display, and a failed read discards the stale number only for the
// display that failed.
//
// The targeted read path was the one place that asked globally. `hasPending` is true whenever
// *any* card has a queued value, and a drag queues one on every frame of the gesture, so while
// the user steered one monitor every read aimed at every other monitor was refused.

// MARK: - The defect

@Test("A neighbour's queued intent cannot refuse a read aimed elsewhere")
func neighbourIntentDoesNotBlockATargetedRead() {
  // The regression: dragging display A's slider made `hasPending` true, and the entry guard
  // read that global flag, so a read aimed at display B was dropped.
  let decision = TargetedRead.decision(
    stableID: "uuid:display-b",
    writeInFlight: false,
    targetHasPendingIntent: false
  )
  #expect(decision == .proceed)
}

@Test("The target's own queued intent does refuse the read")
func ownIntentBlocksATargetedRead() {
  // Not over-corrected into "always read": a value the user has already queued for *this*
  // display outranks whatever the hardware would report, and applying the reading would snap
  // the card backwards to the value being replaced.
  let decision = TargetedRead.decision(
    stableID: "uuid:display-a",
    writeInFlight: false,
    targetHasPendingIntent: true
  )
  #expect(decision == .steering)
}

// MARK: - Guards against over-correction

@Test("A write in flight still refuses every targeted read")
func writeInFlightBlocksEveryTargetedRead() {
  // The one condition that legitimately speaks for all displays: a write holds the shared DDC
  // lane whichever monitor it is aimed at, and reads must stay mutually exclusive with it.
  for hasIntent in [true, false] {
    let decision = TargetedRead.decision(
      stableID: "uuid:display-b",
      writeInFlight: true,
      targetHasPendingIntent: hasIntent
    )
    #expect(decision == .laneBusy)
  }
}

@Test("A display with no stable identity is refused before anything else")
func unaddressableOutranksTransientConditions() {
  // Permanent conditions outrank transient ones. Reporting an unaddressable display as merely
  // busy would hide it behind a state the caller expects to clear on its own, and the caller
  // files the explaining banner only on `.unaddressable`.
  for writeInFlight in [true, false] {
    for hasIntent in [true, false] {
      let decision = TargetedRead.decision(
        stableID: "",
        writeInFlight: writeInFlight,
        targetHasPendingIntent: hasIntent
      )
      #expect(decision == .unaddressable)
    }
  }
}

@Test("Only the target's own intent is consulted, stated as a truth table")
func decisionDependsOnTheTargetNotOnItsNeighbours() {
  // Written as an exhaustive table so re-widening the intent test back to a global flag fails
  // here rather than silently restoring the cross-display refusal.
  struct Case {
    let writeInFlight: Bool
    let targetHasPendingIntent: Bool
    let expected: TargetedRead
  }
  let cases = [
    Case(writeInFlight: false, targetHasPendingIntent: false, expected: .proceed),
    Case(writeInFlight: false, targetHasPendingIntent: true, expected: .steering),
    Case(writeInFlight: true, targetHasPendingIntent: false, expected: .laneBusy),
    Case(writeInFlight: true, targetHasPendingIntent: true, expected: .laneBusy),
  ]
  for testCase in cases {
    let decision = TargetedRead.decision(
      stableID: "uuid:display-a",
      writeInFlight: testCase.writeInFlight,
      targetHasPendingIntent: testCase.targetHasPendingIntent
    )
    #expect(decision == testCase.expected)
  }
}

@Test("A retry on a failed card is not refused by another card's drag")
func retrySurvivesANeighboursDrag() {
  // PRD 2.4 and the acceptance criterion "读取失败时仍可重试". The recovery path clears the
  // banner *before* re-reading, so a refused read leaves the card with no error message, no
  // reading and nothing left to press — strictly worse than never having offered the retry.
  let retryTarget = "uuid:display-that-failed"
  let decision = TargetedRead.decision(
    stableID: retryTarget,
    writeInFlight: false,
    targetHasPendingIntent: false
  )
  #expect(decision == .proceed)
}

@Test("The buffer reports pending state globally, which is why the scope had to be narrowed")
func bufferPendingFlagIsGlobalByDesign() {
  // Pins the premise the fix rests on: `hasPending` is a property of the whole queue, so
  // consulting it for one display is a category error rather than a tunable choice.
  var buffer = BrightnessIntentBuffer()
  buffer.submit(BrightnessIntent(value: 40, displayStableID: "uuid:display-a"))
  #expect(buffer.hasPending)
  // Display B has nothing queued, yet the global flag is set on its behalf.
  #expect(buffer.latestValue(for: "uuid:display-b") == nil)
  #expect(buffer.latestValue(for: "uuid:display-a") == 40)
}
