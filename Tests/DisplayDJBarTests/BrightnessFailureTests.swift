import DisplayDJCore
import Foundation
import Testing

@testable import DisplayDJBar

/// Two distinct identities, so a retry aimed at one can be shown not to land on the other.
private let hpDisplay = "uuid:75490c7d-7258-479e-9bce-da9c8c60ac84"
private let philipsDisplay = "uuid:00000000-1111-2222-3333-444444444444"

// MARK: - Retry path stays available

@Test("Every read failure keeps a way to read again")
func readFailuresAlwaysOfferARetry() {
  // A failed read is exactly when the user most needs the recovery path; PRD 2.4 forbids
  // locking it away. Reading again and rescanning both lead back to a reading; only a
  // dead end is unacceptable without an explanation.
  for code in DisplayDJErrorCode.allCases {
    let error = DisplayDJError(code: code, message: "raw")
    let failure = BrightnessFailurePresenter.failure(
      for: error, operation: .read(displayStableID: hpDisplay))
    if failure.isRetryable {
      #expect(
        failure.recovery == .retryRead(displayStableID: hpDisplay)
          || failure.recovery == .rescan)
    } else {
      // Non-retryable cases must still explain what to change instead.
      #expect(failure.suggestion.isEmpty == false)
    }
  }
}

@Test("A retry after a failed read goes back to the display that failed")
func readRetryCarriesTheTargetDisplay() {
  // The polling loop reads every attached display in turn, so a read failure need not
  // belong to the selected card. A retry that resolved its target from the selection would
  // re-read the neighbouring monitor and leave the failing one stuck reporting nothing.
  let error = DisplayDJError(code: .timeout, message: "no reply")
  let failure = BrightnessFailurePresenter.failure(
    for: error, operation: .read(displayStableID: philipsDisplay))

  guard case .retryRead(let displayStableID) = failure.recovery else {
    Issue.record("A failed read must offer a read retry, got \(failure.recovery)")
    return
  }
  #expect(displayStableID == philipsDisplay)
  #expect(displayStableID != hpDisplay)
}

@Test("A recovery names the display it would act on")
func recoveryExposesItsTargetDisplay() {
  // The banner is shared by every card, so it can only be attributed — and dismissed on
  // the right success — if the recovery states whose failure it is.
  let timeout = DisplayDJError(code: .timeout, message: "no reply")

  let readFailure = BrightnessFailurePresenter.failure(
    for: timeout, operation: .read(displayStableID: philipsDisplay))
  let writeFailure = BrightnessFailurePresenter.failure(
    for: timeout, operation: .write(value: 44, displayStableID: hpDisplay))
  let scanFailure = BrightnessFailurePresenter.failure(for: timeout, operation: .scan)

  #expect(readFailure.recovery.targetDisplayStableID == philipsDisplay)
  #expect(writeFailure.recovery.targetDisplayStableID == hpDisplay)
  // A scan is topology-wide and belongs to no single display.
  #expect(scanFailure.recovery.targetDisplayStableID == nil)
}

@Test("A retry after a failed write repeats the user's value, not the display's")
func writeRetryCarriesTheIntendedValue() {
  let error = DisplayDJError(code: .transportFailure, message: "i2c write failed")
  let failure = BrightnessFailurePresenter.failure(
    for: error,
    operation: .write(value: 37, displayStableID: hpDisplay)
  )

  #expect(failure.recovery == .retryWrite(value: 37, displayStableID: hpDisplay))
}

@Test("A retry after a failed write goes back to the display that failed")
func writeRetryCarriesTheTargetDisplay() {
  // Every card can be adjusted without being selected first, so a retry that resolved its
  // target from the current selection would replay one monitor's value onto another —
  // silently changing a display the user never touched.
  let error = DisplayDJError(code: .timeout, message: "no reply")
  let failure = BrightnessFailurePresenter.failure(
    for: error,
    operation: .write(value: 20, displayStableID: philipsDisplay)
  )

  guard case .retryWrite(let value, let displayStableID) = failure.recovery else {
    Issue.record("A failed write must offer a write retry, got \(failure.recovery)")
    return
  }
  #expect(value == 20)
  #expect(displayStableID == philipsDisplay)
  #expect(displayStableID != hpDisplay)
}

@Test("A vanished display sends the user to a rescan rather than a pointless retry")
func missingDisplayOffersRescan() {
  let error = DisplayDJError(code: .displayNotFound, message: "no such display")

  #expect(
    BrightnessFailurePresenter.failure(for: error, operation: .read(displayStableID: hpDisplay))
      .recovery == .rescan)
  #expect(
    BrightnessFailurePresenter.failure(
      for: error, operation: .write(value: 50, displayStableID: hpDisplay)
    ).recovery == .rescan)
}

@Test("Situations the user cannot retry out of are marked as such")
func unrecoverableSituationsDoNotPretendToBeRetryable() {
  let ambiguous = DisplayDJError(code: .ambiguousDisplay, message: "two identical displays")
  let unavailable = DisplayDJError(code: .backendUnavailable, message: "x86 process")

  let ambiguousFailure = BrightnessFailurePresenter.failure(
    for: ambiguous, operation: .read(displayStableID: hpDisplay))
  let unavailableFailure = BrightnessFailurePresenter.failure(
    for: unavailable, operation: .read(displayStableID: hpDisplay))

  #expect(ambiguousFailure.isRetryable == false)
  #expect(ambiguousFailure.recovery == .unavailable)
  #expect(unavailableFailure.isRetryable == false)
}

// MARK: - Wording

@Test("The raw engineering message never reaches the visible text")
func rawErrorTextStaysOutOfTheUserFacingCopy() {
  let raw = "The operation couldn't be completed. (DisplayDJCore.DisplayDJError error 1.)"
  let error = DisplayDJError(code: .timeout, message: raw)
  let failure = BrightnessFailurePresenter.failure(
    for: error, operation: .read(displayStableID: hpDisplay))

  #expect(failure.summary.contains(raw) == false)
  #expect(failure.suggestion.contains(raw) == false)
  #expect(failure.summary.contains("DisplayDJError") == false)
  // It is kept for diagnosis, just not on screen.
  #expect(failure.technicalDetail?.contains(raw) == true)
  #expect(failure.technicalDetail?.contains("timeout") == true)
}

@Test("Every mapped code produces a summary and an actionable suggestion")
func allCodesProduceCompleteCopy() {
  for code in DisplayDJErrorCode.allCases {
    let error = DisplayDJError(code: code, message: "raw")
    for operation in [
      BrightnessOperation.scan, .read(displayStableID: hpDisplay),
      .write(value: 60, displayStableID: hpDisplay),
    ] {
      let failure = BrightnessFailurePresenter.failure(for: error, operation: operation)
      #expect(failure.summary.trimmingCharacters(in: .whitespaces).isEmpty == false)
      #expect(failure.suggestion.trimmingCharacters(in: .whitespaces).isEmpty == false)
      // A suggestion that does not suggest anything is just a second summary.
      #expect(failure.suggestion.count > 6)
    }
  }
}

@Test("A rejected write says the previous brightness was restored")
func failedWriteReassuresAboutRestoration() {
  let error = DisplayDJError(code: .verificationFailed, message: "readback mismatch")
  let failure = BrightnessFailurePresenter.failure(
    for: error, operation: .write(value: 80, displayStableID: hpDisplay))

  #expect(failure.suggestion.contains("恢复"))
  #expect(failure.recovery == .retryWrite(value: 80, displayStableID: hpDisplay))
}

@Test("Errors from outside Core still get human wording instead of leaking through")
func unknownErrorsAreStillTranslated() {
  struct Opaque: Error {}
  let failure = BrightnessFailurePresenter.failure(
    for: Opaque(), operation: .write(value: 10, displayStableID: hpDisplay))

  #expect(failure.summary.contains("调节亮度"))
  #expect(failure.recovery == .retryWrite(value: 10, displayStableID: hpDisplay))
  #expect(failure.isRetryable)
}

@Test("A display with no stable identity explains the refusal and offers a rescan")
func noStableIdentityIsExplainedNotJustRefused() {
  let failure = BrightnessFailurePresenter.noStableIdentity

  #expect(failure.summary.isEmpty == false)
  #expect(failure.recovery == .rescan)
  #expect(failure.technicalDetail == nil)
}

@Test("VoiceOver hears the cause and the remedy as one sentence")
func spokenDescriptionCombinesCauseAndRemedy() {
  let error = DisplayDJError(code: .busy, message: "lane held")
  let failure = BrightnessFailurePresenter.failure(
    for: error, operation: .read(displayStableID: hpDisplay))

  #expect(failure.spokenDescription.contains(failure.summary))
  #expect(failure.spokenDescription.contains(failure.suggestion))
}

@Test("The offered action never contradicts the sentence above it")
func recoveryMatchesTheWordingItAccompanies() {
  // The earlier draft told the user to rescan while offering a "retry" button. A wrong
  // affordance is worse than none, so the two are checked against each other here.
  for code in DisplayDJErrorCode.allCases {
    let error = DisplayDJError(code: code, message: "raw")
    for operation in [
      BrightnessOperation.scan, .read(displayStableID: hpDisplay),
      .write(value: 60, displayStableID: hpDisplay),
    ] {
      let failure = BrightnessFailurePresenter.failure(for: error, operation: operation)
      if failure.suggestion.contains("重新扫描") {
        #expect(failure.recovery == .rescan)
      }
      if failure.recovery == .unavailable {
        // A dead end must not invite the user to try the same thing again.
        #expect(failure.suggestion.contains("再试") == false)
      }
    }
  }
}

@Test("A scan failure sends the user back to scanning, not to a read")
func scanFailuresRetryTheScan() {
  let error = DisplayDJError(code: .transportFailure, message: "enumeration failed")
  let failure = BrightnessFailurePresenter.failure(for: error, operation: .scan)

  #expect(failure.recovery == .rescan)
}

@Test("An operation states which display it acted on")
func operationsNameTheirTargetDisplay() {
  #expect(BrightnessOperation.scan.displayStableID == nil)
  #expect(BrightnessOperation.read(displayStableID: hpDisplay).displayStableID == hpDisplay)
  #expect(
    BrightnessOperation.write(value: 12, displayStableID: philipsDisplay).displayStableID
      == philipsDisplay)
}

// MARK: - Our own cancellation is not a hardware failure

@Test("Cancelling our own in-flight work is recognised as cancellation")
func cancellationIsRecognised() {
  // A superseded read and a popover closing mid-read both cancel deliberately. Neither is
  // something the display did, so neither may be shown to the user as a failure.
  #expect(BrightnessFailurePresenter.isCancellation(CancellationError()))
}

@Test("A real hardware error is never mistaken for a cancellation")
func hardwareErrorsAreNotCancellations() {
  // The guard must be narrow: swallowing a genuine failure would leave the user with a
  // stale number and no banner explaining why the display stopped responding.
  for code in DisplayDJErrorCode.allCases {
    let error = DisplayDJError(code: code, message: "raw")
    #expect(BrightnessFailurePresenter.isCancellation(error) == false)
  }
}

@Test("A cancelled write whose restoration failed is still reported")
func cancelledWriteWithFailedRestorationStillReports() {
  // When a write is cancelled Core restores the baseline first; only if that restoration
  // *also* fails does it raise a DisplayDJError carrying `primaryCode: cancelled`. The
  // display may then be holding a value the user never asked for, so this one must reach
  // the user even though the word "cancelled" appears in it.
  let error = DisplayDJError(
    code: .verificationFailed,
    message: "restoration failed after cancellation",
    details: ["primaryCode": "cancelled"]
  )

  #expect(BrightnessFailurePresenter.isCancellation(error) == false)

  let failure = BrightnessFailurePresenter.failure(
    for: error, operation: .write(value: 60, displayStableID: hpDisplay))
  #expect(failure.summary.isEmpty == false)
  #expect(failure.recovery == .retryWrite(value: 60, displayStableID: hpDisplay))
}
