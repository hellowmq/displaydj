import ArgumentParser
import DisplayDJCore
import Foundation

struct ListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List online displays without changing display state.",
    discussion: """
      The first column is the selector for --display. Prefer the stable ID;
      `runtime:` IDs from this snapshot are also accepted by get and set, but
      they are valid only for the current topology and can change or be reused
      after display reconfiguration.
      """
  )

  @Flag(name: .long, help: "Emit a versioned JSON response.")
  var json = false

  mutating func run() async throws {
    let displays = try await CoreGraphicsDisplayDiscovery().discoverDisplays()

    if json {
      try writeJSON(displays)
    } else {
      writeText(displays)
    }
  }

  private func writeJSON(_ displays: [DisplayDescriptor]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(DisplayListResponse(displays: displays))

    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }

  private func writeText(_ displays: [DisplayDescriptor]) {
    guard !displays.isEmpty else {
      print("No online displays.")
      return
    }

    for display in displays {
      let selector = display.stableID ?? "runtime:\(display.runtimeID)"
      let virtualState =
        switch display.isVirtual {
        case .some(true):
          "virtual"
        case .some(false):
          "physical"
        case nil:
          "virtual-unknown"
        }
      var flags = [display.isBuiltIn ? "built-in" : "external", virtualState]

      if display.isMirrored {
        if let sourceID = display.mirrorSourceRuntimeID {
          flags.append("mirrors-runtime:\(sourceID)")
        } else {
          flags.append("mirror-set-member")
        }
      }

      let fields = [
        selector,
        CLITextSanitizer.sanitize(display.name),
        "runtime:\(display.runtimeID)",
        flags.joined(separator: ","),
      ]
      print(fields.joined(separator: "\t"))
    }
  }
}

private struct DisplayListResponse: Encodable {
  let schemaVersion = 1
  let displays: [DisplayListItem]

  init(displays: [DisplayDescriptor]) {
    self.displays = displays.map(DisplayListItem.init)
  }
}

/// A frozen schema-v1 DTO. Domain model changes must not silently alter JSON.
private struct DisplayListItem: Encodable {
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
