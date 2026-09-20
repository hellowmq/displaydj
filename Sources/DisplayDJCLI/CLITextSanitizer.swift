import Foundation

enum CLITextSanitizer {
  static func sanitize(_ value: String) -> String {
    value.unicodeScalars.map { scalar in
      CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
    }.joined()
  }
}
