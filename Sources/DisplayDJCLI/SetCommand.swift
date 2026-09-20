import ArgumentParser
import DisplayDJCore
import Foundation

struct SetCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "set",
    abstract: "Write a display control value. Sends a Set VCP request, "
      + "reads back to verify, repeats the frame if the display ignored it, "
      + "and restores the baseline on failure.",
    subcommands: [SetBrightnessCommand.self]
  )

  mutating func run() async throws {
    throw CleanExit.helpRequest(self)
  }
}

struct SetBrightnessCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "brightness",
    abstract: "Set external-display brightness through DDC/CI.",
    discussion: """
      This command sends one Set VCP feature 0x10 request through the Apple
      Silicon IOAV DDC transport, reads back to verify, and restores the
      original baseline on failure. A display that ignores an isolated Set
      frame gets that frame repeated once. Select a display with a stable ID or
      a `runtime:` ID from 'displaydj list'. Runtime IDs are valid only for the
      current topology. The value must be an integer between 0 and 100.
      """
  )

  @Option(
    name: .customLong("display"),
    help: "Stable ID or runtime:<id> from 'displaydj list'."
  )
  var displayID: String

  @Argument(help: "Brightness percentage (0–100).")
  var value: Int

  @Flag(name: .long, help: "Emit a versioned JSON response.")
  var json = false

  mutating func run() async throws {
    guard (0...100).contains(value) else {
      throw DisplayDJError(
        code: .invalidArguments,
        message: "Brightness value must be between 0 and 100, got \(value).",
        operation: .write,
        displayID: displayID
      )
    }

    let result = try await AppleSiliconDDCBrightnessWriter().write(
      percent: Double(value),
      toStableID: displayID
    )

    if json {
      FileHandle.standardOutput.write(try SetBrightnessOutput.jsonData(for: result))
      FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
      FileHandle.standardOutput.write(Data((SetBrightnessOutput.text(for: result) + "\n").utf8))
    }
  }
}

enum SetBrightnessOutput {
  static func jsonData(for result: ControlWriteResult) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(SetBrightnessResponse(result))
  }

  static func text(for result: ControlWriteResult) -> String {
    "\(result.appliedValue.percent)"
  }
}

private struct SetBrightnessResponse: Encodable {
  let schemaVersion = 1
  let isSuccess = true
  let exitCode = CLIExitCode.success.rawValue
  let readOnly = false
  let display: SetBrightnessDisplayItem
  let backend: BackendKind
  let control: DisplayControl
  let requestedValue: Double
  let appliedValue: Double
  let wasVerified: Bool
  let unit = "percent"

  init(_ result: ControlWriteResult) {
    display = SetBrightnessDisplayItem(result.display)
    backend = result.backend
    control = result.control
    requestedValue = result.requestedValue.percent
    appliedValue = result.appliedValue.percent
    wasVerified = result.wasVerified
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case isSuccess = "ok"
    case exitCode
    case readOnly
    case display
    case backend
    case control
    case requestedValue
    case appliedValue
    case wasVerified
    case unit
  }
}

/// A frozen schema-v1 identity snapshot with explicit nulls.
private struct SetBrightnessDisplayItem: Encodable {
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
