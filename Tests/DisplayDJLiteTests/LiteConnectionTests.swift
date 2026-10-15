import DisplayDJCore
import Foundation
import Testing
@testable import DisplayDJLite

private let a = "uuid:22222222-2222-2222-2222-222222222222"
private let b = "uuid:33333333-3333-3333-3333-333333333333"
private let builtIn = DisplayDescriptor(runtimeID: 1,
  stableID: "uuid:11111111-1111-1111-1111-111111111111", name: "Built-in",
  isBuiltIn: true, isVirtual: false, isMirrored: false)

private func external(_ id: UInt32 = 2, stableID: String? = a,
                      mirrored: Bool = false, virtual: Bool? = false) -> DisplayDescriptor {
  .init(runtimeID: id, stableID: stableID, name: "Same name", isBuiltIn: false,
        isVirtual: virtual, isMirrored: mirrored)
}

/// No production transaction is constructed: all topology mutations remain in memory.
private final class LiteWorld: DisplayDiscovering, DisplayConfigurationTransactionApplying, @unchecked Sendable {
  private let lock = NSLock()
  private var descriptors: [DisplayDescriptor]
  private var active: Set<UInt32>
  private var calls: [(UInt32, Bool)] = []
  private var fail = false
  private var mutate = true
  private var failRead = false
  private var failIDs: Set<UInt32> = []

  init(_ descriptors: [DisplayDescriptor], active: Set<UInt32>? = nil) {
    self.descriptors = descriptors
    self.active = active ?? Set(descriptors.map(\.runtimeID))
  }

  func discoverDisplays() async throws -> [DisplayDescriptor] { try snapshot() }
  private func snapshot() throws -> [DisplayDescriptor] {
    lock.lock(); defer { lock.unlock() }
    if failRead { throw LiteRefusal("test read error") }
    return descriptors.filter { active.contains($0.runtimeID) }
  }
  func setEnabled(_ enabled: Bool, forRuntimeID id: UInt32) throws {
    lock.lock(); defer { lock.unlock() }
    calls.append((id, enabled))
    if mutate {
      if enabled { active.insert(id) } else { active.remove(id) }
    }
    if fail || failIDs.contains(id) { throw LiteRefusal("test transaction error") }
  }
  func configure(fail: Bool = false, mutate: Bool = true, failRead: Bool = false,
                 failIDs: Set<UInt32> = []) {
    lock.lock(); defer { lock.unlock() }
    self.fail = fail; self.mutate = mutate; self.failRead = failRead
    self.failIDs = failIDs
  }
  func replace(_ descriptors: [DisplayDescriptor], active: Set<UInt32>) {
    lock.lock(); defer { lock.unlock() }
    self.descriptors = descriptors; self.active = active
  }
  func identity(_ id: UInt32) -> LiteRuntimeIdentity? {
    lock.lock(); defer { lock.unlock() }
    guard let display = descriptors.first(where: { $0.runtimeID == id }), let stableID = display.stableID else { return nil }
    return .init(stableID: stableID, isBuiltIn: display.isBuiltIn, isMirrored: display.isMirrored)
  }
  var applied: [(UInt32, Bool)] {
    lock.lock(); defer { lock.unlock() }
    return calls
  }
}

private func service(_ world: LiteWorld, store: any DisplayConnectionRecordStoring = InMemoryDisplayConnectionRecordStore(),
                     ledger: DisplayConnectionIntentLedger = DisplayConnectionIntentLedger()) -> LiteConnectionService {
  .init(discovery: world, store: store,
        controller: DisplayConnectionController(discovery: world, transaction: world, store: store,
          ledger: ledger, verificationAttempts: 1, verificationDelay: .zero),
        unavailableReason: nil, runtimeIdentity: { world.identity($0) })
}

private struct UnwritableStore: DisplayConnectionRecordStoring {
  func loadRecords() throws -> [DisplayConnectionRecord] { [] }
  func saveRecords(_ records: [DisplayConnectionRecord]) throws { throw LiteRefusal("read-only store") }
}

private actor GatedAccess: LiteConnectionAccess {
  nonisolated let unavailableReason: String? = nil
  let base: LiteConnectionService
  private var entry: CheckedContinuation<Void, Never>?
  private var release: CheckedContinuation<Void, Never>?
  private var entered = false
  init(_ base: LiteConnectionService) { self.base = base }
  func snapshot() async throws -> LiteSnapshot { try await base.snapshot() }
  func change(_ state: DisplayConnectionState, stableID: String) async throws -> DisplayConnectionOutcome {
    entered = true
    entry?.resume(); entry = nil
    await withCheckedContinuation { release = $0 }
    return try await base.change(state, stableID: stableID)
  }
  func waitForEntry() async {
    if !entered { await withCheckedContinuation { entry = $0 } }
  }
  func finish() { release?.resume(); release = nil }
}

@Suite("Lite connection safety, verified state and coexistence")
@MainActor
struct LiteConnectionTests {
  @Test func anotherDisableIsBlockedUntilSavedRecoveryIsComplete() async throws {
    let world = LiteWorld([builtIn, external(), external(3, stableID: b)])
    let store = InMemoryDisplayConnectionRecordStore()
    let access = service(world, store: store)
    _ = try await access.change(.disconnected, stableID: a)
    let model = LiteModel(access: access)
    await model.refresh()
    #expect(model.rows.first { $0.stableID == b }?.refusal != nil)
    do {
      _ = try await access.change(.disconnected, stableID: b)
      Issue.record("Disabled another target with recovery pending")
    } catch {}
    #expect(world.applied.count == 1)
    _ = try await access.change(.connected, stableID: a)
    _ = try await access.change(.disconnected, stableID: b)
    #expect(world.applied.map { $0.1 } == [false, true, false])
  }

  @Test func reusedRecordIsPreservedAndCannotBlockOrControlReplacementScreen() async throws {
    let old = DisplayConnectionRecord(runtimeID: 2, stableID: a, name: "Old")
    let store = InMemoryDisplayConnectionRecordStore(records: [old])
    let world = LiteWorld([builtIn, external(stableID: b)])
    let access = service(world, store: store)
    let model = LiteModel(access: access)
    await model.refresh()
    #expect(model.pendingRecoveryCount == 0)
    #expect(model.rows.first { $0.stableID == a }?.requiresRediscovery == true)
    #expect(model.rows.first { $0.stableID == b }?.refusal == nil)
    await model.perform(model.rows.first { $0.stableID == b }!)
    #expect(model.pendingRecoveryCount == 1)
    #expect(try store.loadRecords().count == 2)
    // A restart while the replacement screen is disabled must not reuse its
    // now-unqueryable runtime ID for the old display.
    let restarted = LiteModel(access: service(world, store: store))
    await restarted.refresh()
    await restarted.perform(restarted.rows.first { $0.stableID == a }!)
    #expect(world.applied.count == 1)
    #expect(await restarted.restoreForQuit())
    #expect(world.applied.map { $0.1 } == [false, true])
    #expect(try store.loadRecords().map(\.stableID) == [a])
    #expect(try store.loadRecords().first?.requiresRediscovery == true)
    #expect(restarted.rows.first { $0.stableID == b }?.isOnline == true)
    // When the real old screen returns, its stable identity can retire its
    // record without making a transaction against the replacement display.
    world.replace([builtIn, external(3, stableID: a), external(stableID: b)], active: [1, 2, 3])
    await restarted.refresh()
    #expect(restarted.pendingRecoveryCount == 1)
    #expect(await restarted.restoreForQuit())
    #expect(try store.loadRecords().isEmpty)
    #expect(world.applied.count == 2)
  }

  @Test func recoveryRecordSchemaReadsLegacyAndPersistsRediscoveryRequirement() throws {
    let legacy = Data("[{\"runtimeID\":2,\"stableID\":\"\(a)\",\"name\":\"Old\",\"disconnectedAt\":0}]".utf8)
    let records = try JSONDecoder().decode([DisplayConnectionRecord].self, from: legacy)
    #expect(records.first?.requiresRediscovery == nil)
    let marked = DisplayConnectionRecord(runtimeID: 2, stableID: a, name: "Old", requiresRediscovery: true)
    #expect(try JSONDecoder().decode(DisplayConnectionRecord.self, from: JSONEncoder().encode(marked)) == marked)
  }

  @Test func missingGuardianReadinessPreventsRecordAndTransaction() async throws {
    let world = LiteWorld([builtIn, external()])
    let store = InMemoryDisplayConnectionRecordStore()
    var access = service(world, store: store)
    access.ensureRecoveryProtection = { throw LiteRefusal("guardian unavailable") }
    do {
      _ = try await access.change(.disconnected, stableID: a)
      Issue.record("Disconnected without recovery protection")
    } catch {}
    #expect(world.applied.isEmpty)
    #expect(try store.loadRecords().isEmpty)
  }

  @Test func guardianRestoresOnlyApplicableExactRecordsAndThenFinishes() async throws {
    let world = LiteWorld([builtIn, external(stableID: b)], active: [1])
    let store = InMemoryDisplayConnectionRecordStore(records: [
      .init(runtimeID: 2, stableID: a, name: "Old", requiresRediscovery: true),
      .init(runtimeID: 2, stableID: b, name: "Current")])
    #expect(await LiteRecoveryGuardian.restoreAfterParentExit(access: service(world, store: store)))
    #expect(world.applied.count == 1 && world.applied[0].0 == 2 && world.applied[0].1)
    #expect(try store.loadRecords().map(\.stableID) == [a])
  }

  @Test func guardianFailureKeepsUnverifiedRecord() async throws {
    let world = LiteWorld([builtIn, external()], active: [1])
    world.configure(mutate: false)
    let store = InMemoryDisplayConnectionRecordStore(records: [.init(runtimeID: 2, stableID: a, name: "Current")])
    #expect(!(await LiteRecoveryGuardian.restoreAfterParentExit(access: service(world, store: store))))
    #expect(try store.loadRecords().count == 1)
    #expect(world.applied.count == 3)
  }

  @Test func exactTargetAndRecoverySurviveModelRestart() async throws {
    let world = LiteWorld([builtIn, external(), external(3, stableID: b)])
    let store = InMemoryDisplayConnectionRecordStore()
    let access = service(world, store: store)
    let model = LiteModel(access: access)
    await model.refresh()
    #expect(model.rows.count == 2)
    #expect(Set(model.rows.map(\.id)).count == 2)
    await model.perform(model.rows.first { $0.stableID == a }!)
    #expect(world.applied.count == 1)
    #expect(world.applied.first?.0 == 2)
    #expect(world.applied.first?.1 == false)
    #expect(try store.loadRecords().count == 1)
    #expect(model.notices[a] == "已确认退出桌面")
    let relaunched = LiteModel(access: access)
    await relaunched.refresh()
    let recovery = relaunched.rows.first { $0.stableID == a }!
    #expect(!recovery.isOnline && recovery.hasRecoveryRecord)
    await relaunched.perform(recovery)
    #expect(try store.loadRecords().isEmpty)
    #expect(relaunched.rows.first { $0.stableID == a }?.isOnline == true)
    #expect(relaunched.notices[a] == "已确认重新连接")
  }

  @Test func uncertainDisconnectRetainsRecoveryAndRetryRestores() async throws {
    let world = LiteWorld([builtIn, external()])
    let store = InMemoryDisplayConnectionRecordStore()
    let model = LiteModel(access: service(world, store: store))
    await model.refresh()
    world.configure(fail: true)
    await model.perform(model.rows[0])
    #expect(try store.loadRecords().count == 1)
    #expect(model.rows[0].hasRecoveryRecord)
    #expect(model.notices[a]?.contains("error") == true)
    world.configure()
    await model.perform(model.rows[0])
    #expect(model.rows[0].isOnline)
    #expect(try store.loadRecords().isEmpty)
  }

  @Test func unverifiedDisconnectOffersRecoveryEvenWhileStillOnline() async throws {
    let world = LiteWorld([builtIn, external()])
    let store = InMemoryDisplayConnectionRecordStore()
    let model = LiteModel(access: service(world, store: store))
    await model.refresh(); world.configure(mutate: false)
    await model.perform(model.rows[0])
    #expect(model.rows[0].isOnline && model.rows[0].hasRecoveryRecord)
    #expect(model.rows[0].action == .connected)
    #expect(model.notices[a]?.contains("未确认") == true)
    await model.perform(model.rows[0])
    #expect(try store.loadRecords().isEmpty)
    #expect(world.applied.count == 1) // Already-online retry only retires our record.
  }

  @Test func dangerousTargetsNeverReachTransaction() async {
    let cases = [builtIn, external(mirrored: true), external(virtual: true),
                 external(virtual: nil), external(stableID: nil)]
    for display in cases {
      let world = LiteWorld([builtIn, display])
      let access = service(world)
      do { _ = try await access.change(.disconnected, stableID: display.stableID ?? a); Issue.record("Accepted unsafe target") }
      catch {}
      #expect(world.applied.isEmpty)
    }
    let onlyExternal = LiteWorld([external()])
    do { _ = try await service(onlyExternal).change(.disconnected, stableID: a); Issue.record("Disconnected last screen") }
    catch {}
    #expect(onlyExternal.applied.isEmpty)
  }

  @Test func duplicateIdentityAndStaleSelectionAreRejected() async {
    let world = LiteWorld([builtIn, external(), external(3)])
    let model = LiteModel(access: service(world))
    await model.refresh()
    #expect(Set(model.rows.map(\.id)).count == 2)
    #expect(model.rows.allSatisfy { $0.refusal != nil })
    do { _ = try await service(world).change(.disconnected, stableID: a); Issue.record("Accepted duplicate") }
    catch {}
    world.replace([builtIn, external()], active: [1, 2])
    await model.refresh(); let row = model.rows[0]
    world.replace([builtIn], active: [1])
    await model.perform(row)
    #expect(world.applied.isEmpty)
    #expect(model.notices[a] != "已确认退出桌面")
  }

  @Test func recycledRuntimeIdentityCannotRestoreWrongScreen() async {
    let store = InMemoryDisplayConnectionRecordStore(records: [.init(runtimeID: 2, stableID: a, name: "Old")])
    for descriptors in [[builtIn, external(stableID: b)],
                        [builtIn, DisplayDescriptor(runtimeID: 2, stableID: a, name: "Built-in",
                                                    isBuiltIn: true, isVirtual: false, isMirrored: false)]] {
      let world = LiteWorld(descriptors, active: [1])
      do { _ = try await service(world, store: store).change(.connected, stableID: a); Issue.record("Accepted unsafe recovery") }
      catch {}
      #expect(world.applied.isEmpty)
      #expect((try? store.loadRecords().count) == 1)
    }
  }

  @Test func softwareDisabledScreenCanRestoreWhenOfflineUUIDIsUnavailable() async throws {
    let world = LiteWorld([builtIn, external()], active: [1])
    let record = DisplayConnectionRecord(runtimeID: 2, stableID: a, name: "Desk")
    let store = InMemoryDisplayConnectionRecordStore(records: [record])
    let original = service(world, store: store)
    let access = LiteConnectionService(discovery: world, store: store, controller: original.controller,
      unavailableReason: nil, runtimeIdentity: { _ in nil }, recoveryCutoff: record.disconnectedAt.addingTimeInterval(-1))
    let model = LiteModel(access: access)
    await model.refresh(); await model.perform(model.rows[0])
    #expect(model.rows[0].isOnline)
    #expect(model.notices[a] == "已确认重新连接")
    #expect(try store.loadRecords().isEmpty)
    #expect(world.applied.count == 1 && world.applied[0].0 == 2 && world.applied[0].1)
  }

  @Test func absentUUIDWithPreSessionRecordIsRejected() async {
    let world = LiteWorld([builtIn, external()], active: [1])
    let record = DisplayConnectionRecord(runtimeID: 2, stableID: a, name: "Desk")
    let store = InMemoryDisplayConnectionRecordStore(records: [record])
    let original = service(world, store: store)
    let access = LiteConnectionService(discovery: world, store: store, controller: original.controller,
      unavailableReason: nil, runtimeIdentity: { _ in nil }, recoveryCutoff: record.disconnectedAt.addingTimeInterval(1))
    do { _ = try await access.change(.connected, stableID: a); Issue.record("Used stale session record") }
    catch {}
    #expect(world.applied.isEmpty)
    #expect((try? store.loadRecords().count) == 1)
  }

  @Test func refreshFailureRetainsRowsButDisablesActionsUntilRetry() async {
    let world = LiteWorld([builtIn, external()])
    let model = LiteModel(access: service(world))
    await model.refresh(); let row = model.rows[0]
    world.configure(failRead: true); await model.refresh()
    #expect(model.rows.count == 1 && model.error != nil)
    await model.perform(row)
    #expect(world.applied.isEmpty)
    world.configure(); await model.refresh()
    #expect(model.error == nil)
    await model.perform(model.rows[0])
    #expect(world.applied.count == 1)
  }

  @Test func unsupportedBackendStillListsRecovery() async {
    let store = InMemoryDisplayConnectionRecordStore(records: [.init(runtimeID: 2, stableID: a, name: "Desk")])
    let world = LiteWorld([builtIn])
    let access = LiteConnectionService(discovery: world, store: store, controller: nil,
      unavailableReason: "Unsupported", runtimeIdentity: { _ in nil })
    let model = LiteModel(access: access)
    await model.refresh()
    #expect(model.error == "Unsupported")
    #expect(model.rows.count == 1 && model.rows[0].hasRecoveryRecord)
    await model.perform(model.rows[0]); #expect(world.applied.isEmpty)
  }

  @Test func liteRecordsAreIsolatedAndSharedIntentDoesNotEraseFullRecords() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lite-coexist-\(UUID())")
    let liteURL = LiteIdentity.recordURL(environment: ["DISPLAYDJ_HOME": root.appendingPathComponent("CLI").path], supportRoot: root)
    #expect(liteURL.path == root.appendingPathComponent("DisplayDJLite/disconnected-displays.json").path)
    let lite = FileDisplayConnectionRecordStore(fileURL: liteURL)
    let full = FileDisplayConnectionRecordStore(fileURL: root.appendingPathComponent("DisplayDJ/disconnected-displays.json"))
    let fullRecord = DisplayConnectionRecord(runtimeID: 9, stableID: b, name: "Full record")
    try full.saveRecords([fullRecord]); let before = try Data(contentsOf: root.appendingPathComponent("DisplayDJ/disconnected-displays.json"))
    let intentions = FileDisplayConnectionIntentStore(fileURL: root.appendingPathComponent("intents.json"))
    let writer = DisplayConnectionIntentLedger(store: intentions)
    let observer = DisplayConnectionIntentLedger(store: intentions)
    let world = LiteWorld([builtIn, external()])
    let access = service(world, store: lite, ledger: writer)
    _ = try await access.change(.disconnected, stableID: a)
    #expect(observer.isSuppressed(runtimeID: 2))
    #expect(try lite.loadRecords().count == 1)
    _ = try await access.change(.connected, stableID: a)
    #expect(try lite.loadRecords().isEmpty)
    #expect(try full.loadRecords() == [fullRecord])
    #expect(try Data(contentsOf: root.appendingPathComponent("DisplayDJ/disconnected-displays.json")) == before)
    #expect(LiteIdentity.recordURL(environment: ["DISPLAYDJ_LITE_HOME": root.path], supportRoot: root).path == root.appendingPathComponent("disconnected-displays.json").path)
  }

  @Test func previewMutatesOnlyMockState() async throws {
    let access = LitePreviewAccess()
    let model = LiteModel(access: access)
    await model.refresh()
    await model.perform(model.rows.first { $0.hasRecoveryRecord }!)
    let original = try await access.snapshot()
    await model.perform(model.rows.first { $0.stableID == a }!)
    #expect(try await access.snapshot().displays.count == original.displays.count - 1)
    await model.perform(model.rows.first { $0.stableID == a }!)
    #expect(try await access.snapshot().displays.count == original.displays.count)
  }

  @Test func failedRecordSavePreventsMutation() async {
    let world = LiteWorld([builtIn, external()])
    let model = LiteModel(access: service(world, store: UnwritableStore()))
    await model.refresh(); await model.perform(model.rows[0])
    #expect(world.applied.isEmpty)
    #expect(model.notices[a]?.contains("失败") == true)
  }

  @Test func failedReconnectKeepsRecordAndCanRetry() async throws {
    let world = LiteWorld([builtIn, external()], active: [1])
    let store = InMemoryDisplayConnectionRecordStore(records: [.init(runtimeID: 2, stableID: a, name: "Desk")])
    let model = LiteModel(access: service(world, store: store))
    await model.refresh(); world.configure(mutate: false)
    await model.perform(model.rows[0])
    #expect(try store.loadRecords().count == 1)
    #expect(!model.rows[0].isOnline)
    #expect(model.notices[a]?.contains("未确认") == true)
    world.configure(); await model.perform(model.rows[0])
    #expect(try store.loadRecords().isEmpty)
    #expect(model.notices[a] == "已确认重新连接")
  }

  @Test func operationBlocksSecondActionAndQuitThenReconcilesDeferredRefresh() async {
    let world = LiteWorld([builtIn, external()])
    let gated = GatedAccess(service(world))
    let model = LiteModel(access: gated)
    await model.refresh(); let row = model.rows[0]
    let task = Task { await model.perform(row) }
    await gated.waitForEntry()
    #expect(model.busyID == a && !model.canQuit)
    #expect(model.notices[a] == "正在断开…")
    await model.perform(row); await model.refresh()
    #expect(world.applied.isEmpty)
    await gated.finish(); await task.value
    #expect(world.applied.count == 1)
    #expect(model.rows[0].hasRecoveryRecord)
    #expect(model.canQuit)
  }

  @Test func corruptRecoveryFileIsNotOverwrittenAndRefreshCanRecover() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("lite-bad-record-\(UUID()).json")
    let original = Data("{not-json".utf8)
    try original.write(to: file)
    let world = LiteWorld([builtIn, external()])
    let model = LiteModel(access: service(world, store: FileDisplayConnectionRecordStore(fileURL: file)))
    await model.refresh()
    #expect(model.error?.contains("恢复记录无法读取") == true)
    #expect(try Data(contentsOf: file) == original)
    #expect(world.applied.isEmpty)
    try Data("[]".utf8).write(to: file)
    await model.refresh()
    #expect(model.error == nil && model.rows.count == 1)
  }

  @Test func rowPositionSurvivesDisconnectAndReconnect() async {
    let world = LiteWorld([builtIn, external(), external(3, stableID: b)])
    let model = LiteModel(access: service(world))
    #expect(!model.hasLoaded)
    await model.refresh()
    #expect(model.hasLoaded)
    let order = model.rows.map(\.id)
    await model.perform(model.rows[0])
    #expect(model.rows.map(\.id) == order)
    #expect(model.rows[0].hasRecoveryRecord)
    #expect(model.feedback[a] == .confirmed(.disconnected))
    await model.perform(model.rows[0])
    #expect(model.rows.map(\.id) == order)
    #expect(model.feedback[a] == .confirmed(.connected))
  }

  @Test func freshTopologySupersedesOldSuccessFeedback() async {
    let world = LiteWorld([builtIn, external()])
    let model = LiteModel(access: service(world))
    await model.refresh()
    await model.perform(model.rows[0])
    #expect(model.feedback[a] == .confirmed(.disconnected))
    world.replace([builtIn, external()], active: [1, 2])
    await model.refresh()
    #expect(model.rows[0].isOnline)
    #expect(model.feedback[a] == nil)
  }

  @Test func quitRestoresOnlySavedLiteTargetsAndVerifiesAll() async throws {
    let world = LiteWorld([builtIn, external(), external(3, stableID: b)], active: [1])
    let store = InMemoryDisplayConnectionRecordStore(records: [
      .init(runtimeID: 2, stableID: a, name: "A"), .init(runtimeID: 3, stableID: b, name: "B")])
    let model = LiteModel(access: service(world, store: store))
    #expect(await model.restoreForQuit())
    #expect(model.pendingRecoveryCount == 0)
    #expect(try store.loadRecords().isEmpty)
    #expect(world.applied.map { $0.0 } == [2, 3])
    #expect(world.applied.allSatisfy { $0.1 })
    #expect(model.rows.allSatisfy { $0.isOnline })
    #expect(!model.quitRecoveryFailed && model.canQuit)
  }

  @Test func partialQuitRecoveryFailureRetainsRemainingRecordsAndAllowsRetry() async throws {
    let world = LiteWorld([builtIn, external(), external(3, stableID: b)], active: [1])
    let store = InMemoryDisplayConnectionRecordStore(records: [
      .init(runtimeID: 2, stableID: a, name: "A"), .init(runtimeID: 3, stableID: b, name: "B")])
    let model = LiteModel(access: service(world, store: store))
    world.configure(failIDs: [3])
    #expect(!(await model.restoreForQuit()))
    #expect(model.quitRecoveryFailed)
    #expect(try store.loadRecords().map(\.stableID) == [b])
    #expect(model.pendingRecoveryCount == 1 && model.canQuit)
    world.configure()
    #expect(await model.restoreForQuit())
    #expect(try store.loadRecords().isEmpty)
    #expect(!model.quitRecoveryFailed)
  }

  @Test func quitWithNoLiteRecordsDoesNotChangeOnlineScreens() async {
    let world = LiteWorld([builtIn, external()])
    let model = LiteModel(access: service(world))
    #expect(await model.restoreForQuit())
    #expect(world.applied.isEmpty)
  }

  @Test func quitRecoveryIsSerializedAndCannotBeBypassedByRepeatedRequests() async {
    let world = LiteWorld([builtIn, external()], active: [1])
    let store = InMemoryDisplayConnectionRecordStore(records: [.init(runtimeID: 2, stableID: a, name: "A")])
    let access = GatedAccess(service(world, store: store))
    let model = LiteModel(access: access)
    let task = Task { await model.restoreForQuit() }
    await access.waitForEntry()
    #expect(model.isRestoringBeforeQuit && !model.canQuit)
    #expect(!(await model.restoreForQuit()))
    await model.perform(model.rows[0])
    #expect(world.applied.isEmpty)
    await access.finish()
    #expect(await task.value)
    #expect(world.applied.count == 1)
  }

  @Test func unreadableOrUnverifiedRecoveryNeverAuthorizesQuit() async throws {
    let world = LiteWorld([builtIn, external()], active: [1])
    let store = InMemoryDisplayConnectionRecordStore(records: [.init(runtimeID: 2, stableID: a, name: "A")])
    let model = LiteModel(access: service(world, store: store))
    world.configure(mutate: false)
    #expect(!(await model.restoreForQuit()))
    #expect(try store.loadRecords().count == 1)
    world.configure(failRead: true)
    #expect(!(await model.restoreForQuit()))
    #expect(model.quitRecoveryFailed && model.error != nil)
    #expect(try store.loadRecords().count == 1)
  }
}
