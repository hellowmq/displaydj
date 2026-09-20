import CoreGraphics
import Foundation
import Testing

@testable import DisplayDJCore

// MARK: - Fakes

/// Stands in for both the private entry point and the window server's answers.
///
/// One type rather than two because the two are not independent here: writing
/// an enable is what makes a display report itself active, and a test that has
/// to keep the two in step by hand is a test that can pass for the wrong reason.
private final class FakeDisplayDriver {
  var activeIDs: Set<UInt32> = []
  var mirroredIDs: Set<UInt32> = []
  /// Off to model a change the window server accepts but does not carry out,
  /// which is the case an unverified outcome has to describe honestly.
  var appliesChanges = true
  var errorToThrow: DisplayDJError?

  struct Call: Equatable {
    let runtimeID: UInt32
    let enabled: Bool
  }

  private(set) var enableCalls: [Call] = []
}

// Conformances sit in extensions so the class declaration stays short enough to
// open its brace on the same line, which the formatter and the linter both want.
extension FakeDisplayDriver: DisplayConfigurationTransactionApplying {
  func setEnabled(_ enabled: Bool, forRuntimeID runtimeID: UInt32) throws {
    if let errorToThrow { throw errorToThrow }
    enableCalls.append(Call(runtimeID: runtimeID, enabled: enabled))

    guard appliesChanges else { return }
    if enabled {
      activeIDs.insert(runtimeID)
    } else {
      activeIDs.remove(runtimeID)
    }
  }
}

extension FakeDisplayDriver: DisplayRuntimeStatusQuerying {
  func isActive(runtimeID: UInt32) -> Bool {
    activeIDs.contains(runtimeID)
  }

  func isMirrored(runtimeID: UInt32) -> Bool {
    mirroredIDs.contains(runtimeID)
  }
}

extension FakeDisplayDriver: @unchecked Sendable {}

private final class Clock: @unchecked Sendable {
  var now = Date()
}

@Suite("Physical connection changes release a disable")
struct DisplayConnectionAutoReleaseTests {
  private func makeRelease(
    driver: FakeDisplayDriver,
    records: [DisplayConnectionRecord],
    ledger: DisplayConnectionIntentLedger = DisplayConnectionIntentLedger()
  ) -> DisplayConnectionAutoRelease {
    DisplayConnectionAutoRelease(
      transaction: driver,
      store: InMemoryDisplayConnectionRecordStore(records: records),
      runtimeStatus: driver,
      ledger: ledger
    )
  }

  // MARK: - Decoding

  @Test func announcementDescribesNoChange() {
    #expect(
      DisplayTopologyChangeDecoder.decode(
        runtimeID: 1,
        flags: [.beginConfigurationFlag, .removeFlag]
      ) == nil
    )
  }

  @Test func addFlagDescribesArrival() {
    #expect(
      DisplayTopologyChangeDecoder.decode(runtimeID: 7, flags: [.addFlag])
        == DisplayTopologyChange(runtimeID: 7, kind: .added)
    )
  }

  @Test func removeFlagDescribesDeparture() {
    #expect(
      DisplayTopologyChangeDecoder.decode(runtimeID: 7, flags: [.removeFlag])
        == DisplayTopologyChange(runtimeID: 7, kind: .removed)
    )
  }

  @Test func addAndRemoveTogetherAreNotGuessedAt() {
    #expect(
      DisplayTopologyChangeDecoder.decode(
        runtimeID: 7,
        flags: [.addFlag, .removeFlag]
      ) == nil
    )
  }

  @Test func unrelatedFlagsDescribeNoChange() {
    #expect(
      DisplayTopologyChangeDecoder.decode(runtimeID: 7, flags: [.setModeFlag])
        == nil
    )
  }

  // MARK: - Unplug

  @Test func unpluggingADisabledDisplayClearsItsRecord() throws {
    let driver = FakeDisplayDriver()
    let store = InMemoryDisplayConnectionRecordStore(
      records: [DisplayConnectionRecord(runtimeID: 3, stableID: "uuid:a", name: "Desk")]
    )
    let release = DisplayConnectionAutoRelease(
      transaction: driver,
      store: store,
      runtimeStatus: driver,
      ledger: DisplayConnectionIntentLedger()
    )

    let outcome = try release.handle(DisplayTopologyChange(runtimeID: 3, kind: .removed))

    #expect(outcome?.action == .clearedOnUnplug)
    #expect(outcome?.displayName == "Desk")
    #expect(outcome?.wasVerified == true)
    #expect(try store.loadRecords().isEmpty)
  }

  @Test func unpluggingAnEnabledDisplayChangesNothing() throws {
    let driver = FakeDisplayDriver()
    let release = makeRelease(driver: driver, records: [])

    #expect(try release.handle(DisplayTopologyChange(runtimeID: 3, kind: .removed)) == nil)
    #expect(driver.enableCalls.isEmpty)
  }

  @Test func unpluggingADisplayWeDidNotDisableLeavesOtherRecordsAlone() throws {
    let driver = FakeDisplayDriver()
    let store = InMemoryDisplayConnectionRecordStore(
      records: [DisplayConnectionRecord(runtimeID: 9, stableID: "uuid:z", name: "Other")]
    )
    let release = DisplayConnectionAutoRelease(
      transaction: driver,
      store: store,
      runtimeStatus: driver,
      ledger: DisplayConnectionIntentLedger()
    )

    #expect(try release.handle(DisplayTopologyChange(runtimeID: 3, kind: .removed)) == nil)
    #expect(try store.loadRecords().count == 1)
  }

  // MARK: - Reconnect

  @Test func reconnectingInactiveTurnsOutputBackOn() throws {
    let driver = FakeDisplayDriver()
    // The display is back, but macOS restored it without driving it.
    driver.activeIDs = []
    let release = makeRelease(driver: driver, records: [])

    let outcome = try release.handle(DisplayTopologyChange(runtimeID: 3, kind: .added))

    #expect(outcome?.action == .restoredOnReconnect)
    #expect(outcome?.wasVerified == true)
    #expect(driver.enableCalls == [FakeDisplayDriver.Call(runtimeID: 3, enabled: true)])
  }

  @Test func reconnectingActiveLeavesItAlone() throws {
    let driver = FakeDisplayDriver()
    driver.activeIDs = [3]
    let release = makeRelease(driver: driver, records: [])

    #expect(try release.handle(DisplayTopologyChange(runtimeID: 3, kind: .added)) == nil)
    #expect(driver.enableCalls.isEmpty)
  }

  @Test func mirroredDisplaysAreNeverTouched() throws {
    let driver = FakeDisplayDriver()
    driver.mirroredIDs = [3]
    driver.activeIDs = []
    let release = makeRelease(driver: driver, records: [])

    #expect(try release.handle(DisplayTopologyChange(runtimeID: 3, kind: .added)) == nil)
    #expect(driver.enableCalls.isEmpty)
  }

  @Test func anEnableThatDoesNotTakeEffectIsReportedAsUnverified() throws {
    let driver = FakeDisplayDriver()
    driver.appliesChanges = false
    driver.activeIDs = []
    let release = makeRelease(driver: driver, records: [])

    let outcome = try release.handle(DisplayTopologyChange(runtimeID: 3, kind: .added))

    #expect(outcome?.action == .restoredOnReconnect)
    #expect(outcome?.wasVerified == false)
  }

  /// A runtime ID is reused by whichever display inherits it, so a record left
  /// behind can end up describing a different monitor than the one it named.
  @Test func reconnectingDropsAStaleRecordForTheSameRuntimeID() throws {
    let driver = FakeDisplayDriver()
    driver.activeIDs = []
    let store = InMemoryDisplayConnectionRecordStore(
      records: [DisplayConnectionRecord(runtimeID: 3, stableID: "uuid:old", name: "Old")]
    )
    let release = DisplayConnectionAutoRelease(
      transaction: driver,
      store: store,
      runtimeStatus: driver,
      ledger: DisplayConnectionIntentLedger()
    )

    _ = try release.handle(DisplayTopologyChange(runtimeID: 3, kind: .added))

    #expect(try store.loadRecords().isEmpty)
  }

  @Test func aRejectedEnableIsNotSwallowed() throws {
    let driver = FakeDisplayDriver()
    driver.activeIDs = []
    driver.errorToThrow = DisplayDJError(
      code: .internalFailure,
      message: "rejected",
      operation: .write
    )
    let release = makeRelease(driver: driver, records: [])

    #expect(throws: DisplayDJError.self) {
      try release.handle(DisplayTopologyChange(runtimeID: 3, kind: .added))
    }
  }

  // MARK: - Self-inflicted changes

  /// Our own disable emits the same event as pulling the cable. Reading it as a
  /// physical unplug would release the disable and discard the record needed to
  /// undo it, leaving the display off with no way back by stable ID.
  @Test func ourOwnChangeIsNotReadAsAPhysicalUnplug() throws {
    let driver = FakeDisplayDriver()
    let store = InMemoryDisplayConnectionRecordStore(
      records: [DisplayConnectionRecord(runtimeID: 3, stableID: "uuid:a", name: "Desk")]
    )
    let ledger = DisplayConnectionIntentLedger()
    let release = DisplayConnectionAutoRelease(
      transaction: driver,
      store: store,
      runtimeStatus: driver,
      ledger: ledger
    )
    ledger.noteIntent(runtimeID: 3)

    #expect(try release.handle(DisplayTopologyChange(runtimeID: 3, kind: .removed)) == nil)
    #expect(try store.loadRecords().count == 1)
  }

  @Test func suppressionExpiresSoLaterPhysicalChangesAreStillSeen() throws {
    let clock = Clock()
    let ledger = DisplayConnectionIntentLedger(graceInterval: 2, now: { clock.now })
    let driver = FakeDisplayDriver()
    let store = InMemoryDisplayConnectionRecordStore(
      records: [DisplayConnectionRecord(runtimeID: 3, stableID: "uuid:a", name: "Desk")]
    )
    let release = DisplayConnectionAutoRelease(
      transaction: driver,
      store: store,
      runtimeStatus: driver,
      ledger: ledger
    )

    ledger.noteIntent(runtimeID: 3)
    #expect(try release.handle(DisplayTopologyChange(runtimeID: 3, kind: .removed)) == nil)

    clock.now += 5
    #expect(
      try release.handle(DisplayTopologyChange(runtimeID: 3, kind: .removed))?.action
        == .clearedOnUnplug
    )
  }
}
