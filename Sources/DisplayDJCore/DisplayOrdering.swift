import Foundation

/// Pure ordering and naming logic for the display cards, kept free of AppKit so it
/// can be unit-tested without a screen. The controller supplies the physical
/// geometry; this file decides where each card lands.
public enum DisplayOrdering {
  /// Resolves the order the cards should appear in.
  ///
  /// When `manualOrder` is set it pins the leading cards by stable ID; any display
  /// not named there is appended afterwards, sorted by physical position so a newly
  /// plugged monitor still lands in a sensible place. With no manual order the whole
  /// list follows physical position (left to right), which is what users expect from
  /// "the monitors on my desk". Displays whose physical X is unknown trail the rest.
  public static func resolve(
    displays: [DisplayDescriptor],
    manualOrder: [String]?,
    physicalMinXById: [UInt32: Double]
  ) -> [DisplayDescriptor] {
    guard let manualOrder else {
      return displays.sorted { lhs, rhs in
        compareByPhysical(lhs: lhs, rhs: rhs, physicalMinXById: physicalMinXById)
      }
    }

    let byStableID = Dictionary(
      displays.map { ($0.stableID, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    var seen = Set<String>()
    var ordered: [DisplayDescriptor] = []

    for stableID in manualOrder {
      guard let display = byStableID[stableID], !seen.contains(stableID) else { continue }
      ordered.append(display)
      seen.insert(stableID)
    }

    let unplaced = displays.filter { display in
      guard let stableID = display.stableID else { return true }
      return !seen.contains(stableID)
    }
    let remainder = unplaced.sorted { lhs, rhs in
      compareByPhysical(lhs: lhs, rhs: rhs, physicalMinXById: physicalMinXById)
    }

    ordered.append(contentsOf: remainder)
    return ordered
  }

  private static func compareByPhysical(
    lhs: DisplayDescriptor,
    rhs: DisplayDescriptor,
    physicalMinXById: [UInt32: Double]
  ) -> Bool {
    let lhsX = physicalMinXById[lhs.runtimeID]
    let rhsX = physicalMinXById[rhs.runtimeID]

    switch (lhsX, rhsX) {
    case (.some(let leftX), .some(let rightX)):
      if leftX != rightX { return leftX < rightX }
      // Same column: keep a stable tiebreak so the order is deterministic.
      if let lID = lhs.stableID, let rID = rhs.stableID, lID != rID {
        return lID < rID
      }
      return lhs.runtimeID < rhs.runtimeID
    case (.some, .none):
      return true
    case (.none, .some):
      return false
    case (.none, .none):
      if let lID = lhs.stableID, let rID = rhs.stableID, lID != rID {
        return lID < rID
      }
      return lhs.runtimeID < rhs.runtimeID
    }
  }
}

/// Resolves the name a card shows, preferring a user-set alias over the system name.
public enum DisplayAliasResolver {
  /// Returns `alias` when one is set and non-empty for `stableID`, otherwise `name`.
  public static func title(
    for name: String,
    stableID: String?,
    aliases: [String: String]
  ) -> String {
    guard
      let stableID,
      let alias = aliases[stableID],
      !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return name
    }
    return alias
  }

  /// Normalizes an alias input: an empty or whitespace-only string means "no alias".
  public static func normalize(_ alias: String) -> String? {
    let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
