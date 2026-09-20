/// Resolves user-facing selectors against one immutable discovery snapshot.
public struct DisplaySelectorResolver: Sendable {
  public init() {}

  public func resolve(
    _ selector: DisplaySelector,
    among displays: [DisplayDescriptor]
  ) throws -> [DisplayDescriptor] {
    switch selector {
    case .all:
      return displays
    case .builtIn:
      return try requireMatches(
        displays.filter(\.isBuiltIn),
        selectorDescription: "built-in displays",
        allowsMultiple: true
      )
    case .external:
      return try requireMatches(
        displays.filter { !$0.isBuiltIn },
        selectorDescription: "external displays",
        allowsMultiple: true
      )
    case .runtimeID(let runtimeID):
      return try requireMatches(
        displays.filter { $0.runtimeID == runtimeID },
        selectorDescription: "runtime:\(runtimeID)",
        allowsMultiple: false
      )
    case .stableID(let stableID):
      let normalizedID = try DisplayStableSelector.normalizeInput(stableID)
      let normalizedLookupID = normalizedID.lowercased()

      return try requireMatches(
        displays.filter {
          $0.stableID.flatMap(DisplayStableSelector.normalizeDescriptorID)
            == normalizedLookupID
        },
        selectorDescription: normalizedID,
        allowsMultiple: false
      )
    }
  }

  private func requireMatches(
    _ matches: [DisplayDescriptor],
    selectorDescription: String,
    allowsMultiple: Bool
  ) throws -> [DisplayDescriptor] {
    guard !matches.isEmpty else {
      throw DisplayDJError(
        code: .displayNotFound,
        message: "No online display matched '\(selectorDescription)'.",
        operation: .discover,
        displayID: selectorDescription
      )
    }

    guard allowsMultiple || matches.count == 1 else {
      let runtimeIDs =
        matches
        .map(\.runtimeID)
        .sorted()
        .map(String.init)
        .joined(separator: ",")

      throw DisplayDJError(
        code: .ambiguousDisplay,
        message: "Display selector '\(selectorDescription)' matched multiple displays.",
        operation: .discover,
        displayID: selectorDescription,
        details: ["runtimeIDs": runtimeIDs]
      )
    }

    return matches
  }
}
