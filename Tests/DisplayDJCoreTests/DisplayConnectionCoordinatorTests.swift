import Darwin
import Foundation
import Testing
@testable import DisplayDJCore

private final class CoordinatedWorld: DisplayDiscovering, DisplayConfigurationTransactionApplying, DisplayRuntimeStatusQuerying, @unchecked Sendable {
  private let lock = NSLock()
  private var online: Set<UInt32> = [1, 2]
  private var changes = 0
  func discoverDisplays() async throws -> [DisplayDescriptor] { snapshot() }
  func snapshot() -> [DisplayDescriptor] {
    lock.lock(); defer { lock.unlock() }
    return online.sorted().map { id in .init(runtimeID: id,
      stableID: "uuid:00000000-0000-0000-0000-00000000000\(id)", name: "Screen",
      isBuiltIn: false, isVirtual: false, isMirrored: false) }
  }
  func setEnabled(_ enabled: Bool, forRuntimeID runtimeID: UInt32) throws {
    lock.lock(); defer { lock.unlock() }
    changes += 1
    if enabled { online.insert(runtimeID) } else { online.remove(runtimeID) }
  }
  func numberOfChanges() -> Int { lock.lock(); defer { lock.unlock() }; return changes }
  func isActive(runtimeID: UInt32) -> Bool { snapshot().contains { $0.runtimeID == runtimeID } }
  func isMirrored(runtimeID: UInt32) -> Bool { false }
}

struct DisplayConnectionCoordinatorTests {
  @Test func delayedRemovalEventFromAnOlderTransactionCannotClearItsRecoveryRecord() async throws {
    let coordinator = try coordinator(); let world = CoordinatedWorld()
    let record = DisplayConnectionRecord(runtimeID: 2,
      stableID: "uuid:00000000-0000-0000-0000-000000000002", name: "Desk", operationID: UUID())
    let store = InMemoryDisplayConnectionRecordStore(records: [record])
    let receivedAt = Date(timeIntervalSince1970: 100)
    try await coordinator.withLock {
      try coordinator.note(stableID: record.stableID!, intent: .init(operationID: record.operationID!,
        runtimeID: 2, updatedAt: receivedAt.addingTimeInterval(10)))
      try world.setEnabled(false, forRuntimeID: 2)
    }
    let release = DisplayConnectionAutoRelease(transaction: world, store: store, runtimeStatus: world,
      ledger: .init(), coordinator: coordinator)
    #expect(try await release.handleCoordinated(.init(runtimeID: 2, kind: .removed), receivedAt: receivedAt) == nil)
    #expect(try store.loadRecords() == [record])
  }

  func coordinator() throws -> DisplayConnectionCoordinator {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return .init(directory: directory)
  }

  @Test func competingDisconnectsRecheckTheLastOnlineScreenInsideTheLock() async throws {
    let coordinator = try coordinator()
    let world = CoordinatedWorld()
    let controller = DisplayConnectionController(discovery: world, transaction: world,
      store: InMemoryDisplayConnectionRecordStore(), ledger: .init(), coordinator: coordinator)
    let outcomes = await withTaskGroup(of: Bool.self) { group in
      for id: UInt32 in [1, 2] {
        group.addTask {
          do { _ = try await controller.setState(.disconnected, for: .runtimeID(id)); return true }
          catch let error as DisplayDJError { #expect(error.code == .conflict); return false }
          catch { Issue.record(error); return false }
        }
      }
      var results: [Bool] = []; for await value in group { results.append(value) }; return results
    }
    #expect(outcomes.filter { $0 }.count == 1)
    #expect(world.snapshot().count == 1 && world.numberOfChanges() == 1)
  }

  @Test func oldRecoveryRecordCannotEnableTargetOwnedByNewerDisconnect() async throws {
    let coordinator = try coordinator(); let world = CoordinatedWorld()
    let oldStore = InMemoryDisplayConnectionRecordStore()
    let newStore = InMemoryDisplayConnectionRecordStore()
    let old = DisplayConnectionController(discovery: world, transaction: world, store: oldStore,
      ledger: .init(), coordinator: coordinator, recoveryOwnerID: UUID())
    let new = DisplayConnectionController(discovery: world, transaction: world, store: newStore,
      ledger: .init(), coordinator: coordinator, recoveryOwnerID: UUID())
    let selector = DisplaySelector.stableID("uuid:00000000-0000-0000-0000-000000000002")
    _ = try await old.setState(.disconnected, for: selector)
    // The system restores output independently; the old store still holds its record.
    try world.setEnabled(true, forRuntimeID: 2)
    _ = try await new.setState(.disconnected, for: selector)
    let changesBefore = world.numberOfChanges()
    do { _ = try await old.setState(.connected, for: selector); Issue.record("Old recovery must be refused") }
    catch let error as DisplayDJError { #expect(error.details["reason"] == "superseded-recovery") }
    #expect(world.numberOfChanges() == changesBefore && world.snapshot().count == 1)
    #expect(try oldStore.loadRecords().count == 1)
    _ = try await new.setState(.connected, for: selector)
    #expect(world.snapshot().count == 2)
    #expect(try newStore.loadRecords().isEmpty)
  }

  @Test func aRealOtherProcessHoldingTheLockCausesBusyAndDeathReleasesIt() async throws {
    let coordinator = try coordinator()
    let child = Process(); let output = Pipe()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    child.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); print('ready',flush=True); time.sleep(30)",
      coordinator.directory.appendingPathComponent("displaydj-connection-v1.lock").path]
    child.standardOutput = output; child.standardError = FileHandle.nullDevice
    try child.run(); output.fileHandleForWriting.closeFile()
    defer { if child.isRunning { child.terminate() }; try? output.fileHandleForReading.close() }
    var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
    #expect(poll(&descriptor, 1, 5000) > 0)
    #expect(try output.fileHandleForReading.read(upToCount: 6) == Data("ready\n".utf8))
    do {
      let _: Bool = try await coordinator.withLock(timeout: .milliseconds(50)) { Issue.record("Must not enter held lock"); return true }
      Issue.record("Expected busy")
    } catch let error as DisplayDJError { #expect(error.code == .busy) }
    child.terminate(); child.waitUntilExit()
    #expect(try await coordinator.withLock { true })
  }

  @Test func oldRecordFormatLoadsAndNewOperationOwnershipSurvivesReload() throws {
    let coordinator = try coordinator()
    let url = coordinator.directory.appendingPathComponent("records.json")
    try Data("[{\"runtimeID\":2,\"stableID\":\"uuid:legacy\",\"name\":\"Desk\",\"disconnectedAt\":0}]".utf8).write(to: url)
    let store = FileDisplayConnectionRecordStore(fileURL: url)
    #expect(try store.loadRecords().first?.operationID == nil)
    let record = DisplayConnectionRecord(runtimeID: 2, stableID: "uuid:legacy", name: "Desk",
      operationID: UUID(), ownerID: UUID())
    try store.saveRecords([record]); #expect(try store.loadRecords() == [record])
  }
}
