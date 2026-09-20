import Foundation

enum DisplayStableSelector {
  static func normalizeInput(_ value: String) throws -> String {
    let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let containsControlCharacter = normalizedValue.unicodeScalars.contains {
      CharacterSet.controlCharacters.contains($0)
    }

    guard
      !normalizedValue.isEmpty,
      normalizedValue.count <= 256,
      !containsControlCharacter
    else {
      throw DisplayDJError(
        code: .invalidSelector,
        message: "A stable display selector must be 1...256 printable characters.",
        operation: .discover
      )
    }

    return normalizedValue
  }

  static func normalizeDescriptorID(_ value: String) -> String? {
    guard
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      let normalizedValue = try? normalizeInput(value)
    else {
      return nil
    }

    return normalizedValue.lowercased()
  }
}
