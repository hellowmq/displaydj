import ArgumentParser
import Darwin
import DisplayDJCore
import Foundation

struct ReportedCLIError {
  let error: DisplayDJError
  let exitCode: CLIExitCode
}

enum CLIErrorReporter {
  static func terminate(_ error: Error, arguments: [String]) -> Never {
    let parserExitCode = DisplayDJCommand.exitCode(for: error)

    if parserExitCode.isSuccess {
      write(
        DisplayDJCommand.fullMessage(for: error),
        to: .standardOutput
      )
      Darwin.exit(parserExitCode.rawValue)
    }

    let reportedError = report(for: error)
    if arguments.contains("--json") {
      do {
        FileHandle.standardOutput.write(try jsonData(for: reportedError))
        FileHandle.standardOutput.write(Data("\n".utf8))
      } catch {
        write(
          "error [internal-failure]: Failed to encode the JSON error response.",
          to: .standardError
        )
        Darwin.exit(CLIExitCode.internalFailure.rawValue)
      }
    } else {
      write(text(for: reportedError.error), to: .standardError)
    }

    Darwin.exit(reportedError.exitCode.rawValue)
  }

  static func report(for error: Error) -> ReportedCLIError {
    if let displayError = error as? DisplayDJError {
      return ReportedCLIError(
        error: displayError,
        exitCode: displayError.code.cliExitCode
      )
    }

    let parserExitCode = DisplayDJCommand.exitCode(for: error)
    if parserExitCode == .validationFailure {
      let parserMessage = DisplayDJCommand.message(for: error)
      return ReportedCLIError(
        error: DisplayDJError(
          code: .invalidArguments,
          message: parserMessage.isEmpty ? "Invalid command-line arguments." : parserMessage,
          details: ["argumentParserExitCode": String(parserExitCode.rawValue)]
        ),
        exitCode: .usage
      )
    }

    return ReportedCLIError(
      error: DisplayDJError(
        code: .internalFailure,
        message: "An unexpected internal error occurred.",
        details: ["underlyingError": String(describing: error)]
      ),
      exitCode: .internalFailure
    )
  }

  static func jsonData(for reportedError: ReportedCLIError) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(CLIErrorResponse(reportedError))
  }

  private static func text(for error: DisplayDJError) -> String {
    var lines = [
      "error [\(error.code.rawValue)]: \(CLITextSanitizer.sanitize(error.message))"
    ]

    if let operation = error.operation {
      lines.append("operation: \(operation.rawValue)")
    }
    if let displayID = error.displayID {
      lines.append("display: \(CLITextSanitizer.sanitize(displayID))")
    }
    if let backend = error.backend {
      lines.append("backend: \(backend.rawValue)")
    }
    for key in error.details.keys.sorted() {
      if let value = error.details[key] {
        lines.append(
          "\(CLITextSanitizer.sanitize(key)): \(CLITextSanitizer.sanitize(value))"
        )
      }
    }

    return lines.joined(separator: "\n")
  }

  private static func write(_ text: String, to handle: FileHandle) {
    guard !text.isEmpty else {
      return
    }

    let terminatedText = text.hasSuffix("\n") ? text : text + "\n"
    handle.write(Data(terminatedText.utf8))
  }
}

private struct CLIErrorResponse: Encodable {
  let schemaVersion = 1
  let isSuccess = false
  let exitCode: Int32
  let error: CLIErrorItem

  init(_ reportedError: ReportedCLIError) {
    exitCode = reportedError.exitCode.rawValue
    error = CLIErrorItem(reportedError.error)
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case isSuccess = "ok"
    case exitCode
    case error
  }
}

/// A frozen schema-v1 DTO with explicit nulls for unavailable context.
private struct CLIErrorItem: Encodable {
  let code: DisplayDJErrorCode
  let message: String
  let operation: ControlOperation?
  let displayID: String?
  let backend: BackendKind?
  let details: [String: String]

  init(_ error: DisplayDJError) {
    code = error.code
    message = error.message
    operation = error.operation
    displayID = error.displayID
    backend = error.backend
    details = error.details
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(code, forKey: .code)
    try container.encode(message, forKey: .message)
    try encode(operation, forKey: .operation, into: &container)
    try encode(displayID, forKey: .displayID, into: &container)
    try encode(backend, forKey: .backend, into: &container)
    try container.encode(details, forKey: .details)
  }

  private func encode<Value: Encodable>(
    _ value: Value?,
    forKey key: CodingKeys,
    into container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    if let value {
      try container.encode(value, forKey: key)
    } else {
      try container.encodeNil(forKey: key)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case code
    case message
    case operation
    case displayID
    case backend
    case details
  }
}
