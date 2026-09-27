/// Keeps the software dimming editor's values tied to a display identity.
/// A value is absent until that display has been read; showing 100% before a read
/// would make an unknown level look like a confirmed system color state.
struct SoftwareDimmingLevels {
  private var values: [String: Double] = [:]

  func value(for displayUUID: String) -> Double? {
    values[displayUUID]
  }

  mutating func set(_ value: Double, for displayUUID: String) {
    guard !displayUUID.isEmpty else { return }
    values[displayUUID] = value
  }

  mutating func invalidate(_ displayUUID: String) {
    values.removeValue(forKey: displayUUID)
  }
}
