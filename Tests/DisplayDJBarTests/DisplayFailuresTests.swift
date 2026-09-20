import DisplayDJCore
import Testing

@testable import DisplayDJBar

/// Failures are filed per display, so one monitor's error can never erase another's.
///
/// Every attached display has its own card on screen and fails on its own schedule. A single
/// shared slot could hold only one failure at a time, so when the polling loop failed on two
/// displays in the same pass the second overwrote the first before it was ever drawn — and
/// with it the retry button that was that display's only way out. Which error the user got
/// told about depended on enumeration order.
private let hpDisplay = "uuid:75490c7d-7258-479e-9bce-da9c8c60ac84"
private let philipsDisplay = "uuid:00000000-1111-2222-3333-444444444444"

private func failure(_ code: DisplayDJErrorCode, for stableID: String) -> BrightnessFailure {
  BrightnessFailurePresenter.failure(
    for: DisplayDJError(code: code, message: "raw"),
    operation: .read(displayStableID: stableID)
  )
}

@Test("Two displays can hold their own failures at the same time")
func failuresAreKeptPerDisplay() {
  var failures = DisplayFailures()
  let hpFailure = failure(.timeout, for: hpDisplay)
  let philipsFailure = failure(.transportFailure, for: philipsDisplay)

  failures[hpDisplay] = hpFailure
  failures[philipsDisplay] = philipsFailure

  // Neither displaced the other: a polling pass that fails on both must report both.
  #expect(failures[hpDisplay] == hpFailure)
  #expect(failures[philipsDisplay] == philipsFailure)
  #expect(failures[hpDisplay] != failures[philipsDisplay])
}

@Test("Resolving one display's failure leaves the other's untouched")
func clearingOneFailureKeepsTheOther() {
  var failures = DisplayFailures()
  failures[hpDisplay] = failure(.timeout, for: hpDisplay)
  let philipsFailure = failure(.busy, for: philipsDisplay)
  failures[philipsDisplay] = philipsFailure

  // A successful read or write on the HP clears the HP's banner only. Clearing globally
  // took the Philips' retry button away before the user had ever pressed it.
  failures[hpDisplay] = nil

  #expect(failures[hpDisplay] == nil)
  #expect(failures[philipsDisplay] == philipsFailure)
}

@Test("A scan failure is kept apart from any single display's failure")
func topologyFailureIsSeparateFromDisplayFailures() {
  var failures = DisplayFailures()
  let scanFailure = BrightnessFailurePresenter.failure(
    for: DisplayDJError(code: .transportFailure, message: "enumeration failed"),
    operation: .scan
  )
  let hpFailure = failure(.timeout, for: hpDisplay)

  failures.topology = scanFailure
  failures[hpDisplay] = hpFailure

  // A scan belongs to no single display, so filing it under one would attach its rescan
  // button to an arbitrary card.
  #expect(failures.topology == scanFailure)
  #expect(failures[hpDisplay] == hpFailure)

  failures.topology = nil
  #expect(failures[hpDisplay] == hpFailure)
}

@Test("Unplugging one display keeps the remaining display's failure")
func pruningKeepsAttachedDisplaysFailures() {
  var failures = DisplayFailures()
  failures[hpDisplay] = failure(.timeout, for: hpDisplay)
  let philipsFailure = failure(.busy, for: philipsDisplay)
  failures[philipsDisplay] = philipsFailure

  // The HP was unplugged; its banner has no card left to live on. The Philips is still
  // attached and its error is still true.
  failures.prune(keeping: [philipsDisplay])

  #expect(failures[hpDisplay] == nil)
  #expect(failures[philipsDisplay] == philipsFailure)
}

@Test("A rescan that finds nothing forgets every failure")
func clearAllDropsDisplayAndTopologyFailures() {
  var failures = DisplayFailures()
  failures[hpDisplay] = failure(.timeout, for: hpDisplay)
  failures.topology = BrightnessFailurePresenter.failure(
    for: DisplayDJError(code: .timeout, message: "raw"), operation: .scan)

  // With no displays attached the empty state explains the situation; a banner attributed
  // to a display that is no longer there would just be a ghost.
  failures.clearAll()

  #expect(failures[hpDisplay] == nil)
  #expect(failures.topology == nil)
}

@Test("A banner's recovery targets the display it is filed under")
func filedFailureAgreesWithItsRecoveryTarget() {
  var failures = DisplayFailures()
  failures[philipsDisplay] = failure(.timeout, for: philipsDisplay)

  // The card draws the banner and the banner carries the retry, so the two must name the
  // same monitor — otherwise the Philips' card would offer a retry aimed at the HP.
  #expect(failures[philipsDisplay]?.recovery.targetDisplayStableID == philipsDisplay)
  #expect(failures[hpDisplay] == nil)
}

@Test("Every retryable read failure files itself under the display it names")
func retryableFailuresFileUnderTheirOwnTarget() {
  // Whatever the error code, a failure that names a display must end up on that display's
  // card. Anything else puts a retry button on a monitor the user never touched.
  for code in DisplayDJErrorCode.allCases {
    let philipsFailure = failure(code, for: philipsDisplay)
    guard let target = philipsFailure.recovery.targetDisplayStableID else {
      // A rescan or a dead end names no display; it is filed under the display that
      // raised it, which is the card the user is looking at.
      continue
    }
    #expect(target == philipsDisplay)
    #expect(target != hpDisplay)
  }
}

@Test("A banner for an unidentifiable display survives the rescan that keeps its card")
func pruningKeepsBannersForDisplaysWithoutStableIDs() {
  // The display this banner is about is precisely the one with no stable ID, so it is filed
  // under its `selectionKey` runtime fallback instead. Pruning banners against the stable IDs
  // alone — as the readings and the intents correctly are — would delete it on the very next
  // rescan, moments after it was written, leaving an inert card with nothing explaining it.
  var failures = DisplayFailures()
  let runtimeKey = DisplaySelection.runtimeKeyPrefix + "7"
  failures[runtimeKey] = BrightnessFailurePresenter.noStableIdentity
  failures[hpDisplay] = failure(.timeout, for: hpDisplay)

  // Both cards are still on screen: one addressable, one not.
  failures.prune(keeping: [hpDisplay, runtimeKey])

  #expect(failures[runtimeKey] == BrightnessFailurePresenter.noStableIdentity)
  #expect(failures[hpDisplay] != nil)
}

@Test("An unidentifiable display's banner is dropped once that display is gone")
func pruningDropsRuntimeKeyedBannerWhenDetached() {
  var failures = DisplayFailures()
  let runtimeKey = DisplaySelection.runtimeKeyPrefix + "7"
  failures[runtimeKey] = BrightnessFailurePresenter.noStableIdentity

  // Surviving a rescan must not mean surviving forever: with the card gone the banner has
  // nowhere to be drawn and would only resurface on some unrelated display later.
  failures.prune(keeping: [hpDisplay])

  #expect(failures[runtimeKey] == nil)
}
