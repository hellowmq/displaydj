import Foundation

/// Parses the selector strings printed by `displaydj list`.
///
/// A `runtime:` prefix is reserved for the current topology's CoreGraphics ID.
/// Everything else is a stable selector, typically a ColorSync UUID.
public enum DisplayCLISelector {
  private static let runtimePrefix = "runtime:"

  public static func parse(_ value: String) throws -> DisplaySelector {
    let normalizedValue = try DisplayStableSelector.normalizeInput(value)
    if let runtimeID = try runtimeID(from: normalizedValue) {
      return .runtimeID(runtimeID)
    }
    return .stableID(normalizedValue)
  }

  private static func runtimeID(from value: String) throws -> UInt32? {
    let prefixLength = runtimePrefix.count
    guard value.count >= prefixLength else {
      return nil
    }

    let prefix = value.prefix(prefixLength)
    guard prefix.lowercased() == runtimePrefix else {
      return nil
    }

    let remainder = value.dropFirst(prefixLength)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let runtimeID = UInt32(remainder), remainder.allSatisfy(\.isNumber) else {
      throw DisplayDJError(
        code: .invalidSelector,
        message: "A runtime display selector must be 'runtime:' followed by a 32-bit decimal ID.",
        operation: .discover,
        displayID: value,
        details: ["reason": "invalid-runtime-selector"]
      )
    }
    return runtimeID
  }
}
