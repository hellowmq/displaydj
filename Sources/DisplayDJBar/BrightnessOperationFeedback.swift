import Foundation

enum BrightnessOperationFeedback: Equatable {
  case confirming
  case confirmed
  case failed
  var message: String {
    switch self {
    case .confirming: "正在确认"
    case .confirmed: "已确认"
    case .failed: "未确认本次调节"
    }
  }
  var isFailure: Bool { self == .failed }
}

extension DisplayBarController {
  func beginBrightnessFeedback(for id: String) {
    brightnessFeedbackTasks[id]?.cancel()
    brightnessFeedbackTasks[id] = nil
    brightnessFeedback[id] = .confirming
  }
  func confirmBrightnessFeedback(for id: String) {
    brightnessFeedback[id] = .confirmed
    brightnessFeedbackTasks[id]?.cancel()
    brightnessFeedbackTasks[id] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(1200))
      guard !Task.isCancelled, let self else { return }
      self.brightnessFeedback[id] = nil
      self.brightnessFeedbackTasks[id] = nil
    }
  }
}
