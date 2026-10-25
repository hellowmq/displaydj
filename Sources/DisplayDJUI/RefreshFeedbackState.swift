import Foundation

/// Request ownership is separate from the system symbol's animation lifecycle.
struct RefreshFeedbackState {
  static let completionDuration = Duration.milliseconds(650)
  static let pendingLabelDelay = Duration.milliseconds(150)
  private(set) var requestID = UUID()
  private(set) var isRequestInFlight = false
  private(set) var completionID: UUID?
  private(set) var isVisible = false
  private(set) var pendingLabelID: UUID?

  var isActive: Bool { isRequestInFlight || completionID != nil }

  mutating func begin(isDisabled: Bool, isRefreshing: Bool) -> UUID? {
    guard !isDisabled, !isRefreshing, !isRequestInFlight else { return nil }
    requestID = UUID()
    completionID = nil
    pendingLabelID = nil
    isRequestInFlight = true
    return requestID
  }

  mutating func finish(_ id: UUID, accepted: Bool) {
    guard id == requestID else { return }
    isRequestInFlight = false
    pendingLabelID = nil
    completionID = accepted && isVisible ? id : nil
  }

  mutating func expire(_ id: UUID) {
    guard completionID == id else { return }
    completionID = nil
  }

  mutating func revealPendingLabel(_ id: UUID) {
    guard isVisible, isRequestInFlight, requestID == id else { return }
    pendingLabelID = id
  }

  mutating func setVisible(_ visible: Bool) {
    isVisible = visible
    if !visible { completionID = nil; pendingLabelID = nil }
  }
}
