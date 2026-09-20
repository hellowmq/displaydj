/// Visible number formatting for the brightness UI.
///
/// The readout used to be a bare `90` in 52pt — 90 of what is left to the reader. Every place
/// a brightness appears on screen goes through here so the unit can never be dropped in one
/// spot and kept in another, and so the "no reading yet" case is a placeholder rather than a
/// fabricated zero.
enum BrightnessFormatting {
  /// Brightness is expressed as a percentage of the display's own range, not in nits.
  static let unitSuffix = "%"

  /// Shown where a reading is expected but none is available yet.
  static let unavailableReadout = "--"

  /// The bare number for the large readout, which renders the unit as a separate smaller
  /// glyph so the digits keep their optical weight.
  static func readoutDigits(for percent: Int?) -> String {
    guard let percent else { return unavailableReadout }
    return String(BrightnessAccessibility.clamp(percent))
  }

  /// Whether the unit glyph should be drawn next to the readout.
  static func showsUnit(for percent: Int?) -> Bool {
    percent != nil
  }
}
