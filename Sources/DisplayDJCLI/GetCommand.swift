import ArgumentParser
import DisplayDJCore
import Foundation

struct GetCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "get",
    abstract: "Read a display control value without changing display state.",
    subcommands: [GetBrightnessCommand.self]
  )

  mutating func run() async throws {
    throw CleanExit.helpRequest(self)
  }
}

struct GetBrightnessCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "brightness",
    abstract: "Read external-display brightness through DDC/CI.",
    discussion: """
      This command currently uses the Apple Silicon IOAV DDC transport and sends
      only Get VCP feature 0x10. Select a display with a stable ID or a
      `runtime:` ID from 'displaydj list'. Runtime IDs are valid only for the
      current topology. No Set VCP request is sent.
      """
  )

  @Option(
    name: .customLong("display"),
    help: "Stable ID or runtime:<id> from 'displaydj list'."
  )
  var displayID: String

  @Flag(name: .long, help: "Emit a versioned JSON response.")
  var json = false

  mutating func run() async throws {
    let result = try await AppleSiliconDDCBrightnessReader().read(
      fromStableID: displayID
    )

    if json {
      FileHandle.standardOutput.write(try GetBrightnessOutput.jsonData(for: result))
      FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
      FileHandle.standardOutput.write(Data((GetBrightnessOutput.text(for: result) + "\n").utf8))
    }
  }
}

enum GetBrightnessOutput {
  static func jsonData(for result: ControlReadResult) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(GetBrightnessResponse(result))
  }

  static func text(for result: ControlReadResult) -> String {
    String(result.value.percent)
  }
}

private struct GetBrightnessResponse: Encodable {
  let schemaVersion = 1
  let isSuccess = true
  let exitCode = CLIExitCode.success.rawValue
  let readOnly = true
  let display: GetBrightnessDisplayItem
  let backend: BackendKind
  let control: DisplayControl
  let value: Double
  let unit = "percent"

  init(_ result: ControlReadResult) {
    display = GetBrightnessDisplayItem(result.display)
    backend = result.backend
    control = result.control
    value = result.value.percent
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case isSuccess = "ok"
    case exitCode
    case readOnly
    case display
    case backend
    case control
    case value
    case unit
  }
}

/// A frozen schema-v1 identity snapshot with explicit nulls.
private struct GetBrightnessDisplayItem: Encodable {
  let runtimeID: UInt32
  let stableID: String?
  let name: String
  let vendorID: UInt32?
  let productID: UInt32?
  let serialNumber: UInt32?
  let isBuiltIn: Bool
  let isVirtual: Bool?
  let virtualDetectionSource: VirtualDisplayDetectionSource
  let isMirrored: Bool
  let mirrorSourceRuntimeID: UInt32?

  init(_ display: DisplayDescriptor) {
    runtimeID = display.runtimeID
    stableID = display.stableID
    name = display.name
    vendorID = display.vendorID
    productID = display.productID
    serialNumber = display.serialNumber
    isBuiltIn = display.isBuiltIn
    isVirtual = display.isVirtual
    virtualDetectionSource = display.virtualDetectionSource
    isMirrored = display.isMirrored
    mirrorSourceRuntimeID = display.mirrorSourceRuntimeID
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(runtimeID, forKey: .runtimeID)
    try encode(stableID, forKey: .stableID, into: &container)
    try container.encode(name, forKey: .name)
    try encode(vendorID, forKey: .vendorID, into: &container)
    try encode(productID, forKey: .productID, into: &container)
    try encode(serialNumber, forKey: .serialNumber, into: &container)
    try container.encode(isBuiltIn, forKey: .isBuiltIn)
    try encode(isVirtual, forKey: .isVirtual, into: &container)
    try container.encode(virtualDetectionSource, forKey: .virtualDetectionSource)
    try container.encode(isMirrored, forKey: .isMirrored)
    try encode(mirrorSourceRuntimeID, forKey: .mirrorSourceRuntimeID, into: &container)
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
    case vendorID
    case productID
    case serialNumber
    case isBuiltIn
    case isVirtual
    case virtualDetectionSource
    case isMirrored
    case mirrorSourceRuntimeID
  }
}
