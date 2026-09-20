import Testing

@testable import DisplayDJBar

private let displayA = "uuid:aaaaaaaa-0000-0000-0000-000000000001"
private let displayB = "uuid:bbbbbbbb-0000-0000-0000-000000000002"

@Test("A submitted intent is queued rather than dropped")
func intentBufferQueuesSubmittedIntent() {
  var buffer = BrightnessIntentBuffer()

  #expect(buffer.hasPending == false)
  #expect(buffer.isDraining == false)

  buffer.submit(BrightnessIntent(value: 70, displayStableID: displayA))

  #expect(buffer.hasPending)
  #expect(buffer.latestValue(for: displayA) == 70)
}

@Test("Only the newest queued intent survives coalescing")
func intentBufferKeepsOnlyLatestPending() {
  var buffer = BrightnessIntentBuffer()

  buffer.submit(BrightnessIntent(value: 30, displayStableID: displayA))
  buffer.submit(BrightnessIntent(value: 45, displayStableID: displayA))
  buffer.submit(BrightnessIntent(value: 62, displayStableID: displayA))

  #expect(buffer.beginNext() == BrightnessIntent(value: 62, displayStableID: displayA))
  #expect(buffer.hasPending == false)
}

@Test("An intent submitted during an active write is applied afterwards")
func intentBufferConvergesToIntentSubmittedWhileWriting() {
  var buffer = BrightnessIntentBuffer()

  buffer.submit(BrightnessIntent(value: 40, displayStableID: displayA))
  #expect(buffer.beginNext()?.value == 40)
  #expect(buffer.isDraining)

  // User keeps interacting while the hardware write is in flight.
  buffer.submit(BrightnessIntent(value: 55, displayStableID: displayA))
  buffer.submit(BrightnessIntent(value: 80, displayStableID: displayA))
  buffer.finishActive()

  #expect(buffer.beginNext()?.value == 80)
  buffer.finishActive()
  #expect(buffer.beginNext() == nil)
  #expect(buffer.isDraining == false)
}

@Test("Latest value prefers the pending intent over the active one")
func intentBufferPrefersPendingOverActive() {
  var buffer = BrightnessIntentBuffer()

  buffer.submit(BrightnessIntent(value: 20, displayStableID: displayA))
  _ = buffer.beginNext()
  #expect(buffer.latestValue(for: displayA) == 20)

  buffer.submit(BrightnessIntent(value: 90, displayStableID: displayA))
  #expect(buffer.latestValue(for: displayA) == 90)
}

@Test("Intents are scoped to the display they were made for")
func intentBufferScopesValuesToDisplay() {
  var buffer = BrightnessIntentBuffer()

  buffer.submit(BrightnessIntent(value: 33, displayStableID: displayA))
  _ = buffer.beginNext()
  buffer.submit(BrightnessIntent(value: 77, displayStableID: displayB))

  #expect(buffer.latestValue(for: displayB) == 77)
  #expect(buffer.latestValue(for: displayA) == 33)
  #expect(buffer.latestValue(for: "uuid:cccccccc-0000-0000-0000-000000000003") == nil)
}

@Test("A drained buffer reports no outstanding intent")
func intentBufferReportsNoValueAfterDraining() {
  var buffer = BrightnessIntentBuffer()

  buffer.submit(BrightnessIntent(value: 61, displayStableID: displayA))
  _ = buffer.beginNext()
  buffer.finishActive()

  #expect(buffer.latestValue(for: displayA) == nil)
  #expect(buffer.hasPending == false)
  #expect(buffer.isDraining == false)
}

// MARK: - Cross-display isolation
//
// Every display has its own card and can be adjusted without being selected, so the user
// can steer two monitors inside one write window. Coalescing must therefore stay scoped to
// a single display: dropping intermediate values of one drag is intended, dropping another
// monitor's target is the silent discard this type exists to prevent.

@Test("An intent for one display never displaces a queued intent for another")
func intentBufferKeepsQueuedIntentsForEveryDisplay() {
  var buffer = BrightnessIntentBuffer()

  buffer.submit(BrightnessIntent(value: 30, displayStableID: displayB))
  buffer.submit(BrightnessIntent(value: 70, displayStableID: displayA))

  #expect(buffer.latestValue(for: displayB) == 30)
  #expect(buffer.latestValue(for: displayA) == 70)

  // Both must actually come out of the queue, not merely be readable.
  var drained: [String: Int] = [:]
  while let intent = buffer.beginNext() {
    drained[intent.displayStableID] = intent.value
    buffer.finishActive()
  }

  #expect(drained == [displayB: 30, displayA: 70])
}

@Test("Coalescing replaces only the same display's pending value")
func intentBufferCoalescesPerDisplay() {
  var buffer = BrightnessIntentBuffer()

  buffer.submit(BrightnessIntent(value: 20, displayStableID: displayA))
  buffer.submit(BrightnessIntent(value: 40, displayStableID: displayB))
  buffer.submit(BrightnessIntent(value: 55, displayStableID: displayA))

  #expect(buffer.latestValue(for: displayA) == 55)
  #expect(buffer.latestValue(for: displayB) == 40)

  // Two displays are queued, so exactly two writes should be issued.
  var count = 0
  while buffer.beginNext() != nil {
    count += 1
    buffer.finishActive()
  }
  #expect(count == 2)
}

@Test("Queued displays are drained in submission order")
func intentBufferDrainsInSubmissionOrder() {
  var buffer = BrightnessIntentBuffer()

  buffer.submit(BrightnessIntent(value: 10, displayStableID: displayB))
  buffer.submit(BrightnessIntent(value: 20, displayStableID: displayA))
  // Re-submitting must refresh the value without moving the display to the back, so a
  // display being actively dragged cannot starve one that is merely waiting.
  buffer.submit(BrightnessIntent(value: 15, displayStableID: displayB))

  let first = buffer.beginNext()
  #expect(first == BrightnessIntent(value: 15, displayStableID: displayB))
  buffer.finishActive()

  let second = buffer.beginNext()
  #expect(second == BrightnessIntent(value: 20, displayStableID: displayA))
}

@Test("An intent submitted for another display while one is writing survives")
func intentBufferKeepsOtherDisplayIntentDuringActiveWrite() {
  var buffer = BrightnessIntentBuffer()

  buffer.submit(BrightnessIntent(value: 45, displayStableID: displayA))
  #expect(buffer.beginNext()?.displayStableID == displayA)
  #expect(buffer.isDraining)

  // The user turns to the second monitor while the first is still being written.
  buffer.submit(BrightnessIntent(value: 88, displayStableID: displayB))
  buffer.finishActive()

  let next = buffer.beginNext()
  #expect(next == BrightnessIntent(value: 88, displayStableID: displayB))
}

// MARK: - Surviving a topology change
//
// A rescan prunes the readings and the banners, but the intents are the one per-display
// store that writes those back: drain a value queued for a display that has since been
// unplugged and it records a reading — and possibly a failure — under a stable ID with no
// card, so the prune undoes itself moments after running. It also sends that value to
// hardware the current topology does not list.

@Test("A queued intent for an unplugged display is dropped")
func intentBufferPrunesQueuedIntentForDepartedDisplay() {
  var buffer = BrightnessIntentBuffer()

  buffer.submit(BrightnessIntent(value: 30, displayStableID: displayA))
  buffer.submit(BrightnessIntent(value: 70, displayStableID: displayB))

  buffer.prune(keeping: [displayB])

  #expect(buffer.latestValue(for: displayA) == nil)
  #expect(buffer.latestValue(for: displayB) == 70)

  // It must be gone from the queue itself, not merely unreadable: anything still drainable
  // would reach hardware for a display that is no longer attached.
  let first = buffer.beginNext()
  #expect(first == BrightnessIntent(value: 70, displayStableID: displayB))
  buffer.finishActive()
  #expect(buffer.beginNext() == nil)
}

@Test("Pruning keeps every attached display's queued intent and its order")
func intentBufferPruneKeepsAttachedDisplays() {
  var buffer = BrightnessIntentBuffer()

  buffer.submit(BrightnessIntent(value: 10, displayStableID: displayB))
  buffer.submit(BrightnessIntent(value: 20, displayStableID: displayA))

  // Nothing was unplugged, so a rescan must change nothing at all — otherwise every routine
  // re-enumeration would silently discard the user's in-flight targets.
  buffer.prune(keeping: [displayA, displayB])

  #expect(buffer.beginNext() == BrightnessIntent(value: 10, displayStableID: displayB))
  buffer.finishActive()
  #expect(buffer.beginNext() == BrightnessIntent(value: 20, displayStableID: displayA))
}

/// The in-flight write is deliberately left alone: it has already been handed to Core, whose
/// single-Set and restore-on-failure semantics own it from that point, and interrupting it
/// could leave the panel holding a value the user never asked for. Flagging it lets the
/// caller discard the *result* without touching the operation.
@Test("An in-flight write to an unplugged display is flagged rather than cancelled")
func intentBufferFlagsOrphanedActiveIntent() {
  var buffer = BrightnessIntentBuffer()

  buffer.submit(BrightnessIntent(value: 45, displayStableID: displayA))
  #expect(buffer.beginNext()?.displayStableID == displayA)
  #expect(buffer.isActiveOrphaned == false)

  buffer.prune(keeping: [displayB])

  // Still active — the write is not recalled — but its result must not be filed.
  #expect(buffer.isDraining)
  #expect(buffer.isActiveOrphaned)
}

@Test("An in-flight write to a still-attached display is not flagged")
func intentBufferKeepsAttachedActiveIntentUnflagged() {
  var buffer = BrightnessIntentBuffer()

  buffer.submit(BrightnessIntent(value: 45, displayStableID: displayA))
  _ = buffer.beginNext()

  buffer.prune(keeping: [displayA, displayB])

  #expect(buffer.isActiveOrphaned == false)
}

/// The flag describes one specific write, so it must not outlive it — otherwise the next
/// display's perfectly valid result would be discarded too.
@Test("The orphan flag is cleared when the write it describes finishes")
func intentBufferClearsOrphanFlagOnFinish() {
  var buffer = BrightnessIntentBuffer()

  buffer.submit(BrightnessIntent(value: 45, displayStableID: displayA))
  _ = buffer.beginNext()
  buffer.prune(keeping: [displayB])
  #expect(buffer.isActiveOrphaned)

  buffer.finishActive()
  #expect(buffer.isActiveOrphaned == false)

  buffer.submit(BrightnessIntent(value: 88, displayStableID: displayB))
  _ = buffer.beginNext()
  #expect(buffer.isActiveOrphaned == false)
}

/// A prune with an empty topology is the unplug-everything case, which the empty state
/// already explains on screen; nothing may remain queued behind it.
@Test("Losing every display leaves no queued intent behind")
func intentBufferPruneToEmptyTopology() {
  var buffer = BrightnessIntentBuffer()

  buffer.submit(BrightnessIntent(value: 30, displayStableID: displayA))
  buffer.submit(BrightnessIntent(value: 70, displayStableID: displayB))

  buffer.prune(keeping: [])

  #expect(buffer.hasPending == false)
  #expect(buffer.beginNext() == nil)
}
