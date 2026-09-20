import ArgumentParser
import DisplayDJCore
import Foundation

struct DoctorCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "doctor",
    abstract: "Run read-only display discovery, identity, and DDC diagnostics.",
    discussion: """
      Warnings are reported with exit code 0 because the diagnostic completed.
      Discovery and command errors use stable nonzero exit codes. Brightness is
      read back from every externally controllable display to separate a matched
      DDC service from one that actually answers. No Set frame is ever sent, so
      no display control value is changed.
      """
  )

  @Flag(name: .long, help: "Emit a versioned JSON response.")
  var json = false

  mutating func run() async throws {
    let report = try await DisplayDoctor(
      discovery: CoreGraphicsDisplayDiscovery()
    ).run()

    if json {
      try writeJSON(report)
    } else {
      writeText(report)
    }
  }

  private func writeJSON(_ report: DoctorReport) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(DoctorResponse(report))

    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }

  private func writeText(_ report: DoctorReport) {
    print("doctor: \(report.status.rawValue)")
    print("online displays: \(report.displayCount)")

    for check in report.checks {
      print(
        "[\(check.status.rawValue)] \(CLITextSanitizer.sanitize(check.id)): "
          + CLITextSanitizer.sanitize(check.message)
      )
      for key in check.details.keys.sorted() {
        if let value = check.details[key] {
          print(
            "  \(CLITextSanitizer.sanitize(key)): \(CLITextSanitizer.sanitize(value))"
          )
        }
      }
    }

    print("read-only: no display control value was changed")
  }
}

private struct DoctorResponse: Encodable {
  let schemaVersion = 1
  let status: DoctorReportStatus
  let exitCode: Int32 = CLIExitCode.success.rawValue
  let readOnly = true
  let displayCount: Int
  let checks: [DoctorCheckItem]

  init(_ report: DoctorReport) {
    status = report.status
    displayCount = report.displayCount
    checks = report.checks.map(DoctorCheckItem.init)
  }
}

private struct DoctorCheckItem: Encodable {
  let id: String
  let status: DoctorCheckStatus
  let message: String
  let details: [String: String]

  init(_ check: DoctorCheck) {
    id = check.id
    status = check.status
    message = check.message
    details = check.details
  }
}
