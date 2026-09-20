import DisplayDJCore
import Foundation
import Testing

@testable import DisplayDJBar

/// The popover's list of displays this tool switched off.
///
/// The interesting case is not what is shown but what is dropped: a record can
/// outlive the state it describes, and runtime IDs are reassigned, so a stale
/// record offers a "reconnect" aimed at one monitor that drives another.
@Suite("The list of disconnected displays")
struct DisplayConnectionListTests {
  private func record(
    _ runtimeID: UInt32,
    name: String = "Display",
    at moment: TimeInterval
  ) -> DisplayConnectionRecord {
    DisplayConnectionRecord(
      runtimeID: runtimeID,
      stableID: "uuid-\(runtimeID)",
      name: name,
      disconnectedAt: Date(timeIntervalSince1970: moment)
    )
  }

  @Test func aDisplayThatCameBackOnlineIsNotOffered() {
    let resolved = DisplayConnectionList.resolve(
      records: [record(3, at: 20), record(4, at: 10)],
      onlineRuntimeIDs: [3]
    )

    #expect(resolved.map(\.runtimeID) == [4])
  }

  @Test func anEmptyTopologyKeepsEveryRecord() {
    let resolved = DisplayConnectionList.resolve(
      records: [record(3, at: 20), record(4, at: 10)],
      onlineRuntimeIDs: []
    )

    #expect(resolved.count == 2)
  }

  /// Oldest first, so the list does not reshuffle under the pointer between
  /// refreshes.
  @Test func theFirstDisconnectedDisplayIsListedFirst() {
    let resolved = DisplayConnectionList.resolve(
      records: [record(4, at: 30), record(3, at: 10), record(5, at: 20)],
      onlineRuntimeIDs: []
    )

    #expect(resolved.map(\.runtimeID) == [3, 5, 4])
  }

  /// The key has to match whatever the reconnect act files its outcome under,
  /// otherwise a failed reconnect shows no explanation anywhere.
  @Test func runtimeKeyIsNamespacedLikeEveryOtherRuntimeIdentity() {
    #expect(DisplayConnectionList.key(for: 42) == "runtime:42")
  }

  @Test func aRecordForADisplayThatReturnedIsDroppedEvenWithNoStableID() {
    let stray = DisplayConnectionRecord(
      runtimeID: 7,
      stableID: nil,
      name: "Stray",
      disconnectedAt: Date(timeIntervalSince1970: 5)
    )

    let resolved = DisplayConnectionList.resolve(
      records: [stray],
      onlineRuntimeIDs: [7]
    )

    #expect(resolved.isEmpty)
  }
}
