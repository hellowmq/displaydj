import Foundation
import Testing
@testable import DisplayDJUI

@Suite("Refresh feedback request ownership")
struct RefreshFeedbackStateTests {
  private func begin(_ state: inout RefreshFeedbackState) throws -> UUID {
    let request = state.begin(isDisabled: false, isRefreshing: false)
    return try #require(request)
  }

  @Test func acceptedInputImmediatelyOwnsFeedbackAndBlocksDuplicateInput() throws {
    var state = RefreshFeedbackState()
    state.setVisible(true)
    let id = try begin(&state)
    #expect(state.isRequestInFlight && state.isActive)
    let duplicate = state.begin(isDisabled: false, isRefreshing: false)
    #expect(duplicate == nil)
    #expect(state.requestID == id)
    state.finish(id, accepted: true)
    #expect(!state.isRequestInFlight)
    #expect(state.completionID == id)
  }

  @Test func rejectedOrDisabledRequestsDoNotClaimCompletion() throws {
    var state = RefreshFeedbackState()
    state.setVisible(true)
    let disabled = state.begin(isDisabled: true, isRefreshing: false)
    let refreshing = state.begin(isDisabled: false, isRefreshing: true)
    #expect(disabled == nil && refreshing == nil)
    #expect(!state.isActive)
    let id = try begin(&state)
    state.finish(id, accepted: false)
    #expect(!state.isActive && state.completionID == nil)
  }

  @Test func oldCompletionTimerCannotClearTheNextRequest() throws {
    var state = RefreshFeedbackState()
    state.setVisible(true)
    let old = try begin(&state)
    state.finish(old, accepted: true)
    let next = try begin(&state)
    state.finish(next, accepted: true)
    state.expire(old)
    #expect(state.completionID == next)
    state.expire(next)
    #expect(!state.isActive)
  }

  @Test func oldResultCannotStopANewerRequest() throws {
    var state = RefreshFeedbackState()
    state.setVisible(true)
    let old = try begin(&state)
    state.finish(old, accepted: true)
    let next = try begin(&state)
    state.finish(old, accepted: false)
    #expect(state.isRequestInFlight && state.requestID == next)
    state.finish(next, accepted: true)
    #expect(state.completionID == next)
  }

  @Test func hidingCleansVisualFeedbackAndHiddenResultsDoNotRestartIt() throws {
    var state = RefreshFeedbackState()
    state.setVisible(true)
    let id = try begin(&state)
    state.setVisible(false)
    #expect(state.isRequestInFlight)
    state.finish(id, accepted: true)
    #expect(!state.isActive)
    state.setVisible(true)
    #expect(!state.isActive)
    let next = try begin(&state)
    state.finish(next, accepted: true)
    state.setVisible(false)
    #expect(state.completionID == nil)
  }

  @Test func quickReadFinishesWithoutFlashingPendingText() throws {
    var state = RefreshFeedbackState()
    state.setVisible(true)
    let id = try begin(&state)
    #expect(state.pendingLabelID == nil)
    state.finish(id, accepted: true)
    state.revealPendingLabel(id)
    #expect(state.pendingLabelID == nil)
  }

  @Test func delayedPendingTextBelongsOnlyToVisibleCurrentRequest() throws {
    var state = RefreshFeedbackState()
    state.setVisible(true)
    let old = try begin(&state)
    state.revealPendingLabel(old)
    #expect(state.pendingLabelID == old)
    state.finish(old, accepted: true)
    let next = try begin(&state)
    state.revealPendingLabel(old)
    #expect(state.pendingLabelID == nil)
    state.revealPendingLabel(next)
    #expect(state.pendingLabelID == next)
    state.setVisible(false)
    #expect(state.pendingLabelID == nil)
    state.revealPendingLabel(next)
    #expect(state.pendingLabelID == nil)
  }
}
