import DisplayDJCore
import Foundation
import Testing

@testable import DisplayDJBar

/// How a failed connect or disconnect is phrased for the person looking at the
/// popover.
///
/// Keyed off the stable error code rather than off message text, and every
/// branch has to leave the user with something to do: a notice that only
/// announces a failure is a complaint, not a way out.
@Suite("Explaining a connection failure")
struct DisplayConnectionNoticeTests {
  private func notice(
    for code: DisplayDJErrorCode,
    intent: DisplayConnectionState = .disconnected,
    displayName: String = "HP D27k",
    targetKey: String = "uuid-1"
  ) -> DisplayConnectionNotice {
    DisplayConnectionNoticePresenter.notice(
      for: DisplayDJError(code: code, message: "engineering text", operation: .write),
      intent: intent,
      displayName: displayName,
      targetKey: targetKey
    )
  }

  @Test func noticeIsFiledUnderTheDisplayItHappenedTo() {
    let notice = self.notice(for: .conflict, targetKey: "uuid-9")

    #expect(notice.id == "uuid-9")
  }

  @Test func conflictSaysNothingWouldBeLeftToLookAt() {
    let notice = self.notice(for: .conflict, displayName: "HP D27k")

    #expect(notice.summary.contains("不能断开"))
    #expect(notice.summary.contains("HP D27k"))
    #expect(!notice.suggestion.isEmpty)
  }

  @Test func aMissingEntryPointIsReportedAsUnsupported() {
    let notice = self.notice(for: .unsupported)

    #expect(notice.summary.contains("无法断开"))
    #expect(!notice.suggestion.isEmpty)
  }

  /// Disconnecting and reconnecting fail the same way but need different advice:
  /// one leaves a display on that should be off, the other leaves it off.
  @Test func verificationFailureAdviceDependsOnWhichWayItWasGoing() {
    let disconnecting = self.notice(for: .verificationFailed, intent: .disconnected)
    let reconnecting = self.notice(for: .verificationFailed, intent: .connected)

    #expect(disconnecting.summary.contains("断开"))
    #expect(reconnecting.summary.contains("恢复"))
    #expect(disconnecting.suggestion != reconnecting.suggestion)
  }

  @Test func anErrorThePresenterDoesNotKnowStillOffersSomething() {
    let notice = DisplayConnectionNoticePresenter.notice(
      for: NSError(domain: "displaydj.test", code: 42),
      intent: .connected,
      displayName: "PHL 278B1",
      targetKey: "runtime:5"
    )

    #expect(notice.summary.contains("PHL 278B1"))
    #expect(!notice.suggestion.isEmpty)
  }

  /// The engineering text is kept for the tooltip rather than put on screen.
  @Test func technicalDetailCarriesTheUnderlyingMessage() {
    let notice = self.notice(for: .transportFailure)

    #expect(notice.technicalDetail == "engineering text")
  }

  @Test func spokenDescriptionCarriesBothHalves() {
    let notice = self.notice(for: .conflict)

    #expect(notice.spokenDescription.contains(notice.summary))
    #expect(notice.spokenDescription.contains(notice.suggestion))
  }
}
