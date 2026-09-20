import ArgumentParser
import DisplayDJCore
import Foundation

struct CapabilitiesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "capabilities",
    abstract: "Report display capabilities without changing display state.",
    discussion: """
      Missing probe coverage is reported as unavailable, never unsupported.
      The DDC probe checks transport entry points, associates a per-display I/O
      Registry service, and settles brightness with a read-only Get VCP 0x10.
      Every other capability stays unknown rather than supported, because no
      request is sent for it. No Set frame is ever sent, so display state cannot
      change.
      """
  )

  @Flag(name: .long, help: "Emit a versioned JSON response.")
  var json = false

  mutating func run() async throws {
    let reports = try await DisplayCapabilityAggregator(
      discovery: CoreGraphicsDisplayDiscovery(),
      probes: [DDCBackendAvailabilityProbe()]
    ).run()

    if json {
      FileHandle.standardOutput.write(try CapabilitiesOutput.jsonData(for: reports))
      FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
      FileHandle.standardOutput.write(Data((CapabilitiesOutput.text(for: reports) + "\n").utf8))
    }
  }
}

enum CapabilitiesOutput {
  static func jsonData(for reports: [DisplayCapabilitiesReport]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(CapabilitiesResponse(reports))
  }

  static func text(for reports: [DisplayCapabilitiesReport]) -> String {
    var lines: [String] = []

    for report in reports {
      let display = report.display
      let selector = display.stableID ?? "runtime:\(display.runtimeID)"
      lines.append(
        [
          CLITextSanitizer.sanitize(selector),
          CLITextSanitizer.sanitize(display.name),
          "runtime:\(display.runtimeID)",
        ].joined(separator: "\t")
      )

      for assessment in report.capabilities {
        let sourceSummary: String
        if assessment.sources.isEmpty {
          sourceSummary = "no-probe-registered"
        } else {
          sourceSummary = assessment.sources.map(sourceText).joined(separator: ",")
        }
        lines.append(
          "  \(assessment.capability.rawValue)\t\(assessment.state.rawValue)\t\(sourceSummary)"
        )
      }
    }

    lines.append("read-only: no display control value was changed")
    return lines.joined(separator: "\n")
  }

  private static func sourceText(_ source: DisplayCapabilitySource) -> String {
    var value = "\(source.backend.rawValue)=\(source.state.rawValue)"
    if let errorCode = source.errorCode {
      value += ":\(errorCode.rawValue)"
    }
    if let reason = source.reason {
      value += ":\(CLITextSanitizer.sanitize(reason))"
    }
    return value
  }
}

private struct CapabilitiesResponse: Encodable {
  let schemaVersion = 1
  let readOnly = true
  let displays: [CapabilitiesDisplayItem]

  init(_ reports: [DisplayCapabilitiesReport]) {
    displays = reports.map(CapabilitiesDisplayItem.init)
  }
}

private struct CapabilitiesDisplayItem: Encodable {
  let runtimeID: UInt32
  let stableID: String?
  let name: String
  let isBuiltIn: Bool
  let isVirtual: Bool?
  let isMirrored: Bool
  let capabilities: [CapabilityItem]

  init(_ report: DisplayCapabilitiesReport) {
    runtimeID = report.display.runtimeID
    stableID = report.display.stableID
    name = report.display.name
    isBuiltIn = report.display.isBuiltIn
    isVirtual = report.display.isVirtual
    isMirrored = report.display.isMirrored
    capabilities = report.capabilities.map(CapabilityItem.init)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(runtimeID, forKey: .runtimeID)
    try encode(stableID, forKey: .stableID, into: &container)
    try container.encode(name, forKey: .name)
    try container.encode(isBuiltIn, forKey: .isBuiltIn)
    try encode(isVirtual, forKey: .isVirtual, into: &container)
    try container.encode(isMirrored, forKey: .isMirrored)
    try container.encode(capabilities, forKey: .capabilities)
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
    case runtimeID
    case stableID
    case name
    case isBuiltIn
    case isVirtual
    case isMirrored
    case capabilities
  }
}

private struct CapabilityItem: Encodable {
  let capability: DisplayCapability
  let state: DisplayCapabilityState
  let sources: [CapabilitySourceItem]

  init(_ assessment: DisplayCapabilityAssessment) {
    capability = assessment.capability
    state = assessment.state
    sources = assessment.sources.map(CapabilitySourceItem.init)
  }
}

private struct CapabilitySourceItem: Encodable {
  let backend: BackendKind
  let state: DisplayCapabilityState
  let reason: String?
  let errorCode: DisplayDJErrorCode?

  init(_ source: DisplayCapabilitySource) {
    backend = source.backend
    state = source.state
    reason = source.reason
    errorCode = source.errorCode
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(backend, forKey: .backend)
    try container.encode(state, forKey: .state)
    try encode(reason, forKey: .reason, into: &container)
    try encode(errorCode, forKey: .errorCode, into: &container)
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
    case backend
    case state
    case reason
    case errorCode
  }
}
