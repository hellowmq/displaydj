import DisplayDJCore
import Foundation
import Testing

@testable import DisplayDJCLI

@Test("JSON errors expose stable exit codes and explicit null context")
func structuredJSONErrorEnvelope() throws {
  let error = DisplayDJError(
    code: .timeout,
    message: "Display transport timed out.",
    operation: .probe,
    details: ["attempts": "3"]
  )
  let reportedError = CLIErrorReporter.report(for: error)
  let data = try CLIErrorReporter.jsonData(for: reportedError)
  let root = try #require(
    JSONSerialization.jsonObject(with: data) as? [String: Any]
  )
  let errorObject = try #require(root["error"] as? [String: Any])

  #expect(reportedError.exitCode == .timeout)
  #expect(root["schemaVersion"] as? Int == 1)
  #expect(root["ok"] as? Bool == false)
  #expect(root["exitCode"] as? Int == 7)
  #expect(errorObject["code"] as? String == "timeout")
  #expect(errorObject["operation"] as? String == "probe")
  #expect(errorObject["displayID"] is NSNull)
  #expect(errorObject["backend"] is NSNull)
}

@Test("Text output strips terminal control characters")
func textOutputSanitizesControlCharacters() {
  let sanitized = CLITextSanitizer.sanitize("a\u{001B}b\nc\r\td\u{009B}e\u{0007}")

  #expect(sanitized == "a b c  d e ")
  #expect(
    !sanitized.unicodeScalars.contains {
      CharacterSet.controlCharacters.contains($0)
    }
  )
}
