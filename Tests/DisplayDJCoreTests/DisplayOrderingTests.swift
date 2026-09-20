import Foundation
import Testing

@testable import DisplayDJCore

/// Card order and alias resolution are pure and screen-free, so they can be pinned
/// down without a display attached — exactly the kind of rule that used to live only
/// in the running app and bit back on the third monitor.
@Suite("Display card order and alias resolution")
struct DisplayOrderingTests {
  private func makeDisplay(
    runtimeID: UInt32,
    stableID: String? = nil,
    name: String,
    minX: Double? = nil
  ) -> DisplayDescriptor {
    let descriptor = DisplayDescriptor(
      runtimeID: runtimeID,
      stableID: stableID,
      name: name,
      isBuiltIn: false,
      isVirtual: false,
      isMirrored: false
    )
    return descriptor
  }

  private func minXMap(_ pairs: (UInt32, Double)...) -> [UInt32: Double] {
    Dictionary(uniqueKeysWithValues: pairs)
  }

  @Test func physicalOrderFollowsLeftToRight() {
    let left = makeDisplay(runtimeID: 2, stableID: "s-b", name: "PHL", minX: 0)
    let middle = makeDisplay(runtimeID: 3, stableID: "s-c", name: "Dell", minX: 50)
    let right = makeDisplay(runtimeID: 1, stableID: "s-a", name: "HP", minX: 100)

    let result = DisplayOrdering.resolve(
      displays: [right, left, middle],
      manualOrder: nil,
      physicalMinXById: minXMap((1, 100), (2, 0), (3, 50))
    )

    #expect(result.map(\.runtimeID) == [2, 3, 1])
  }

  @Test func manualOrderPinsTheLeadingCards() {
    let first = makeDisplay(runtimeID: 1, stableID: "s-a", name: "HP")
    let second = makeDisplay(runtimeID: 2, stableID: "s-b", name: "PHL")
    let third = makeDisplay(runtimeID: 3, stableID: "s-c", name: "Dell")

    let result = DisplayOrdering.resolve(
      displays: [first, second, third],
      manualOrder: ["s-c", "s-a", "s-b"],
      physicalMinXById: [:]
    )

    #expect(result.map { $0.stableID } == ["s-c", "s-a", "s-b"])
  }

  @Test func displaysMissingFromManualOrderAreAppendedPhysically() {
    let first = makeDisplay(runtimeID: 1, stableID: "s-a", name: "HP")
    let second = makeDisplay(runtimeID: 2, stableID: "s-b", name: "PHL")
    let third = makeDisplay(runtimeID: 3, stableID: "s-c", name: "Dell")

    // `s-c` is not named in the manual order, so it trails the pinned pair.
    let result = DisplayOrdering.resolve(
      displays: [first, second, third],
      manualOrder: ["s-b", "s-a"],
      physicalMinXById: [:]
    )

    #expect(result.map { $0.stableID } == ["s-b", "s-a", "s-c"])
  }

  @Test func staleManualOrderEntriesAreDropped() {
    let first = makeDisplay(runtimeID: 1, stableID: "s-a", name: "HP")
    let second = makeDisplay(runtimeID: 2, stableID: "s-b", name: "PHL")
    let third = makeDisplay(runtimeID: 3, stableID: "s-c", name: "Dell")

    // "s-x" no longer exists, so only "s-a" is pinned and the rest follow.
    let result = DisplayOrdering.resolve(
      displays: [first, second, third],
      manualOrder: ["s-x", "s-a"],
      physicalMinXById: [:]
    )

    #expect(result.map { $0.stableID } == ["s-a", "s-b", "s-c"])
  }

  @Test func aliasResolverPrefersUserAlias() {
    #expect(
      DisplayAliasResolver.title(
        for: "HP D27k",
        stableID: "s1",
        aliases: ["s1": "右屏"]
      ) == "右屏"
    )
  }

  @Test func aliasResolverFallsBackToSystemName() {
    #expect(
      DisplayAliasResolver.title(
        for: "HP D27k",
        stableID: "s1",
        aliases: [:]
      ) == "HP D27k"
    )
    #expect(
      DisplayAliasResolver.title(
        for: "HP D27k",
        stableID: nil,
        aliases: ["s1": "右屏"]
      ) == "HP D27k"
    )
    #expect(
      DisplayAliasResolver.title(
        for: "HP D27k",
        stableID: "s1",
        aliases: ["s1": "   "]
      ) == "HP D27k"
    )
  }

  @Test func normalizeTreatsWhitespaceAsNoAlias() {
    #expect(DisplayAliasResolver.normalize("   ") == nil)
    #expect(DisplayAliasResolver.normalize(" 右屏 ") == "右屏")
  }
}
