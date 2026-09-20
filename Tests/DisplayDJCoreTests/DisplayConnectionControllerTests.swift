import Foundation
import Testing

@testable import DisplayDJCore

// These tests never touch the private entry point. The transaction is always
// injected, so a failure here cannot change what any real display is doing.

// MARK: - Fakes

/// Shared fake state standing in for the window server's online display set.
private final class ConnectionWorld: @unchecked Sendable {
  private let lock = NSLock()
  private var online: Set<UInt32>
  private(set) var appliedCalls: [(runtimeID: UInt32, enabled: Bool)] = []

  init(online: Set<UInt32>) {
    self.online = online
  }

  func isOnline(_ runtimeID: UInt32) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return online.contains(runtimeID)
  }

  func apply(_ runtimeID: UInt32, _ enabled: Bool, mutate: Bool) {
    lock.lock()
    defer { lock.unlock() }
    appliedCalls.append((runtimeID, enabled))

    guard mutate else { return }
    if enabled {
      online.insert(runtimeID)
    } else {
      online.remove(runtimeID)
    }
  }

  var calls: [(runtimeID: UInt32, enabled: Bool)] {
    lock.lock()
    defer { lock.unlock() }
    return appliedCalls
  }
}

private struct WorldDiscovery: DisplayDiscovering {
  let world: ConnectionWorld
  let descriptors: [DisplayDescriptor]

  func discoverDisplays() async throws -> [DisplayDescriptor] {
    descriptors.filter { world.isOnline($0.runtimeID) }
  }
}

private struct WorldTransaction: DisplayConfigurationTransactionApplying {
  let world: ConnectionWorld
  let mutatesWorld: Bool
  let thrownError: DisplayDJError?

  init(
    world: ConnectionWorld,
    mutatesWorld: Bool = true,
    thrownError: DisplayDJError? = nil
  ) {
    self.world = world
    self.mutatesWorld = mutatesWorld
    self.thrownError = thrownError
  }

  func setEnabled(_ enabled: Bool, forRuntimeID runtimeID: UInt32) throws {
    if let thrownError {
      throw thrownError
    }
    world.apply(runtimeID, enabled, mutate: mutatesWorld)
  }
}

// MARK: - Helpers

private func makeDisplay(
  runtimeID: UInt32,
  stableID: String? = nil,
  name: String = "Display",
  isMirrored: Bool = false
) -> DisplayDescriptor {
  DisplayDescriptor(
    runtimeID: runtimeID,
    stableID: stableID,
    name: name,
    vendorID: nil,
    productID: nil,
    serialNumber: nil,
    isBuiltIn: false,
    isVirtual: false,
    virtualDetectionSource: .coreDisplay,
    isMirrored: isMirrored,
    mirrorSourceRuntimeID: nil
  )
}

private func makeController(
  world: ConnectionWorld,
  displays: [DisplayDescriptor],
  store: any DisplayConnectionRecordStoring = NoOpDisplayConnectionRecordStore(),
  mutatesWorld: Bool = true,
  thrownError: DisplayDJError? = nil
) -> DisplayConnectionController {
  DisplayConnectionController(
    discovery: WorldDiscovery(world: world, descriptors: displays),
    transaction: WorldTransaction(
      world: world,
      mutatesWorld: mutatesWorld,
      thrownError: thrownError
    ),
    store: store
  )
}

private func displayError(
  from body: () async throws -> Void
) async -> DisplayDJError? {
  do {
    try await body()
    Issue.record("Expected the operation to fail.")
    return nil
  } catch let error as DisplayDJError {
    return error
  } catch {
    Issue.record("Expected a DisplayDJError, got \(error).")
    return nil
  }
}

// MARK: - Symbol resolution

@Test("A missing private entry point is reported instead of being skipped")
func missingPrivateEntryPointIsUnsupported() {
  do {
    _ = try CGSConnectionTransaction(
      resolver: MissingDisplayConnectionSymbolResolver()
    )
    Issue.record("Expected initialization to fail when the symbol is missing.")
  } catch let error as DisplayDJError {
    #expect(error.code == .unsupported)
    #expect(error.details["phase"] == "symbol-resolution")
  } catch {
    Issue.record("Expected a DisplayDJError, got \(error).")
  }
}

// MARK: - Disconnect

@Test("Disconnecting one of two displays removes it from the online topology")
func disconnectRemovesOneDisplay() async throws {
  let first = makeDisplay(runtimeID: 1, stableID: "uuid:first", name: "First")
  let second = makeDisplay(runtimeID: 2, stableID: "uuid:second", name: "Second")
  let world = ConnectionWorld(online: [1, 2])
  let store = InMemoryDisplayConnectionRecordStore()
  let controller = makeController(
    world: world,
    displays: [first, second],
    store: store
  )

  let outcome = try await controller.setState(.disconnected, for: .runtimeID(1))

  #expect(outcome.requestedState == .disconnected)
  #expect(outcome.observedState == .disconnected)
  #expect(outcome.wasVerified)
  #expect(outcome.display.runtimeID == 1)
  #expect(world.isOnline(1) == false)
  #expect(world.isOnline(2))
  #expect(world.calls.count == 1)
  #expect(world.calls.first?.enabled == false)
  #expect(try store.loadRecords().count == 1)
  #expect(try store.loadRecords().first?.stableID == "uuid:first")
}

@Test("The last online display is never disconnected")
func lastOnlineDisplayIsRefused() async {
  let only = makeDisplay(runtimeID: 1, stableID: "uuid:only", name: "Only")
  let world = ConnectionWorld(online: [1])
  let controller = makeController(world: world, displays: [only])

  let error = await displayError {
    try await controller.setState(.disconnected, for: .runtimeID(1))
  }

  #expect(error?.code == .conflict)
  #expect(error?.details["reason"] == "last-online-display")
  #expect(world.calls.isEmpty)
  #expect(world.isOnline(1))
}

@Test("A mirrored display is refused instead of altering the mirror set")
func mirroredDisplayIsRefused() async {
  let mirrored = makeDisplay(
    runtimeID: 1,
    stableID: "uuid:mirrored",
    isMirrored: true
  )
  let other = makeDisplay(runtimeID: 2, stableID: "uuid:other")
  let world = ConnectionWorld(online: [1, 2])
  let controller = makeController(world: world, displays: [mirrored, other])

  let error = await displayError {
    try await controller.setState(.disconnected, for: .stableID("uuid:mirrored"))
  }

  #expect(error?.code == .unsupported)
  #expect(error?.details["reason"] == "mirrored-display")
  #expect(world.calls.isEmpty)
}

@Test("Multi-display selectors are refused")
func multiDisplaySelectorsAreRefused() async {
  let first = makeDisplay(runtimeID: 1, stableID: "uuid:first")
  let second = makeDisplay(runtimeID: 2, stableID: "uuid:second")
  let world = ConnectionWorld(online: [1, 2])
  let controller = makeController(world: world, displays: [first, second])

  let error = await displayError {
    try await controller.setState(.disconnected, for: .all)
  }

  #expect(error?.code == .invalidSelector)
  #expect(error?.details["reason"] == "multi-display-selector")
  #expect(world.calls.isEmpty)
}

@Test("A display that stays online after a disconnect is a verification failure")
func disconnectThatDoesNotTakeEffectFails() async {
  let first = makeDisplay(runtimeID: 1, stableID: "uuid:first")
  let second = makeDisplay(runtimeID: 2, stableID: "uuid:second")
  let world = ConnectionWorld(online: [1, 2])
  let controller = makeController(
    world: world,
    displays: [first, second],
    mutatesWorld: false
  )

  let error = await displayError {
    try await controller.setState(.disconnected, for: .runtimeID(1))
  }

  #expect(error?.code == .verificationFailed)
  #expect(world.calls.count == 1)
  #expect(world.isOnline(1))
}

@Test("A rejected transaction is reported instead of being swallowed")
func transactionFailureIsPropagated() async {
  let first = makeDisplay(runtimeID: 1, stableID: "uuid:first")
  let second = makeDisplay(runtimeID: 2, stableID: "uuid:second")
  let world = ConnectionWorld(online: [1, 2])
  let controller = makeController(
    world: world,
    displays: [first, second],
    thrownError: DisplayDJError(
      code: .internalFailure,
      message: "The window server rejected the change.",
      operation: .write
    )
  )

  let error = await displayError {
    try await controller.setState(.disconnected, for: .runtimeID(1))
  }

  #expect(error?.code == .internalFailure)
}

@Test("Disconnecting an absent display is a lookup failure")
func disconnectingAbsentDisplayIsNotFound() async {
  let present = makeDisplay(runtimeID: 2, stableID: "uuid:second")
  let world = ConnectionWorld(online: [2])
  let controller = makeController(world: world, displays: [present])

  let error = await displayError {
    try await controller.setState(.disconnected, for: .runtimeID(99))
  }

  #expect(error?.code == .displayNotFound)
  #expect(world.calls.isEmpty)
}

// MARK: - Connect

@Test("Connecting a display that is already online changes nothing")
func connectingOnlineDisplayIsANoOp() async throws {
  let first = makeDisplay(runtimeID: 1, stableID: "uuid:first", name: "First")
  let world = ConnectionWorld(online: [1])
  let controller = makeController(world: world, displays: [first])

  let outcome = try await controller.setState(.connected, for: .runtimeID(1))

  #expect(outcome.observedState == .connected)
  #expect(outcome.wasVerified)
  #expect(world.calls.isEmpty)
}

@Test("An offline display is reconnected by runtime ID")
func offlineDisplayIsReconnectedByRuntimeID() async throws {
  let first = makeDisplay(runtimeID: 1, stableID: "uuid:first", name: "First")
  let world = ConnectionWorld(online: [])
  let store = InMemoryDisplayConnectionRecordStore(
    records: [
      DisplayConnectionRecord(runtimeID: 1, stableID: "uuid:first", name: "First")
    ]
  )
  let controller = makeController(
    world: world,
    displays: [first],
    store: store
  )

  let outcome = try await controller.setState(.connected, for: .runtimeID(1))

  #expect(outcome.observedState == .connected)
  #expect(outcome.wasVerified)
  #expect(world.isOnline(1))
  #expect(world.calls.first?.enabled == true)
  #expect(try store.loadRecords().isEmpty)
}

@Test("A saved record lets a stable ID reconnect an offline display")
func offlineDisplayIsReconnectedByStableID() async throws {
  let first = makeDisplay(runtimeID: 7, stableID: "uuid:first", name: "First")
  let world = ConnectionWorld(online: [])
  let store = InMemoryDisplayConnectionRecordStore(
    records: [
      DisplayConnectionRecord(runtimeID: 7, stableID: "uuid:first", name: "First")
    ]
  )
  let controller = makeController(
    world: world,
    displays: [first],
    store: store
  )

  let outcome = try await controller.setState(.connected, for: .stableID("uuid:first"))

  #expect(outcome.observedState == .connected)
  #expect(outcome.display.runtimeID == 7)
  #expect(world.isOnline(7))
}

@Test("An offline stable ID without a saved record is a lookup failure")
func offlineStableIDWithoutRecordIsNotFound() async {
  let world = ConnectionWorld(online: [])
  let controller = makeController(world: world, displays: [])

  let error = await displayError {
    try await controller.setState(.connected, for: .stableID("uuid:gone"))
  }

  #expect(error?.code == .displayNotFound)
  #expect(error?.details["reason"] == "no-saved-record")
}

@Test("A connect that does not bring the display back is a verification failure")
func connectThatDoesNotRestoreFails() async {
  let first = makeDisplay(runtimeID: 1, stableID: "uuid:first")
  let world = ConnectionWorld(online: [])
  let controller = makeController(
    world: world,
    displays: [first],
    mutatesWorld: false
  )

  let error = await displayError {
    try await controller.setState(.connected, for: .runtimeID(1))
  }

  #expect(error?.code == .verificationFailed)
}
