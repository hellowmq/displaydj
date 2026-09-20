import Foundation

public enum DisplayDJErrorCode: String, Codable, CaseIterable, Sendable {
  case invalidArguments = "invalid-arguments"
  case invalidValue = "invalid-value"
  case invalidSelector = "invalid-selector"
  case displayNotFound = "display-not-found"
  case ambiguousDisplay = "ambiguous-display"
  case unsupported
  case backendUnavailable = "backend-unavailable"
  case timeout
  case busy
  case transportFailure = "transport-failure"
  case verificationFailed = "verification-failed"
  case conflict
  case internalFailure = "internal-failure"
}

public enum ControlOperation: String, Codable, CaseIterable, Sendable {
  case discover
  case probe
  case read
  case write
  case reset
  case restore
}

public enum CLIExitCode: Int32, Codable, Sendable {
  case success = 0
  case usage = 2
  case displayNotFound = 3
  case ambiguousDisplay = 4
  case unsupported = 5
  case backendUnavailable = 6
  case timeout = 7
  case busy = 8
  case operationFailed = 9
  case internalFailure = 70
}

public struct DisplayDJError: Error, Codable, Equatable, Sendable {
  public let code: DisplayDJErrorCode
  public let message: String
  public let operation: ControlOperation?
  public let displayID: String?
  public let backend: BackendKind?
  public let details: [String: String]

  public init(
    code: DisplayDJErrorCode,
    message: String,
    operation: ControlOperation? = nil,
    displayID: String? = nil,
    backend: BackendKind? = nil,
    details: [String: String] = [:]
  ) {
    self.code = code
    self.message = message
    self.operation = operation
    self.displayID = displayID
    self.backend = backend
    self.details = details
  }

  static func invalidControlValue(
    _ value: Double,
    expectedRange: String
  ) -> DisplayDJError {
    DisplayDJError(
      code: .invalidValue,
      message: "Control value must be finite and within \(expectedRange).",
      details: [
        "value": String(describing: value),
        "expectedRange": expectedRange,
      ]
    )
  }
}

extension DisplayDJError: LocalizedError {
  public var errorDescription: String? {
    message
  }
}

extension DisplayDJErrorCode {
  public var cliExitCode: CLIExitCode {
    switch self {
    case .invalidArguments, .invalidValue, .invalidSelector:
      .usage
    case .displayNotFound:
      .displayNotFound
    case .ambiguousDisplay:
      .ambiguousDisplay
    case .unsupported:
      .unsupported
    case .backendUnavailable:
      .backendUnavailable
    case .timeout:
      .timeout
    case .busy, .conflict:
      .busy
    case .transportFailure, .verificationFailed:
      .operationFailed
    case .internalFailure:
      .internalFailure
    }
  }
}
