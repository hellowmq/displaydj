import Combine
import DisplayDJCore
import Foundation
import Testing
@testable import DisplayDJLite
import VibeDisplayCore

private let internalKey = "uuid:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
private let externalKey = "uuid:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
private let internalPanel = DisplayDescriptor(runtimeID: 41, stableID: internalKey, name: "Internal",
  isBuiltIn: true, isVirtual: false, isMirrored: false)
private let externalPanel = DisplayDescriptor(runtimeID: 42, stableID: externalKey, name: "External",
  isBuiltIn: false, isVirtual: false, isMirrored: false)

private actor BrightnessFixture: LiteBrightnessAccess {
  var levels = [internalKey: 45, externalKey: 62]
  var writes: [(String, Int)] = []
  var blockFirst = false
  var failFirst = false
  var readFails = false
  private var reads: [String] = []
  private var pauseRead = false
  private var readStarted = false
  private var readEntry: CheckedContinuation<Void, Never>?
  private var readGate: CheckedContinuation<Void, Never>?
  private var started = false
  private var entry: CheckedContinuation<Void, Never>?
  private var gate: CheckedContinuation<Void, Never>?
  func configure(block: Bool = false, fail: Bool = false, readFails: Bool = false) {
    blockFirst = block; failFirst = fail; self.readFails = readFails
  }
  func read(stableID: String) async throws -> Int {
    reads.append(stableID)
    if pauseRead {
      pauseRead = false; readStarted = true; readEntry?.resume(); readEntry = nil
      await withCheckedContinuation { readGate = $0 }
    }
    if readFails { throw LiteRefusal("Fake unsupported brightness") }
    return levels[stableID] ?? 50
  }
  func write(percent: Int, stableID: String) async throws -> Int {
    writes.append((stableID, percent))
    let first = writes.count == 1
    if first && blockFirst {
      started = true; entry?.resume(); entry = nil
      await withCheckedContinuation { gate = $0 }
    }
    if first && failFirst { throw LiteRefusal("Fake unconfirmed write") }
    levels[stableID] = percent
    return percent
  }
  func wait() async { if !started { await withCheckedContinuation { entry = $0 } } }
  func release() { gate?.resume(); gate = nil }
  func calls() -> [(String, Int)] { writes }
  func readCalls() -> [String] { reads }
  func pauseNextRead() { pauseRead = true; readStarted = false }
  func waitForRead() async { if !readStarted { await withCheckedContinuation { readEntry = $0 } } }
  func releaseRead() { readGate?.resume(); readGate = nil }
}

private struct FixedBrightnessDiscovery: DisplayDiscovering {
  let displays: [DisplayDescriptor]
  func discoverDisplays() async throws -> [DisplayDescriptor] { displays }
}

private actor ConnectionFixture: LiteConnectionAccess {
  nonisolated let unavailableReason: String? = nil
  var changes = 0
  private var snapshots = 0
  private var pauseSnapshot = false
  private var entered = false
  private var entry: CheckedContinuation<Void, Never>?
  private var gate: CheckedContinuation<Void, Never>?
  func pauseNextSnapshot() { pauseSnapshot = true }
  func snapshot() async throws -> LiteSnapshot {
    snapshots += 1
    if pauseSnapshot {
      pauseSnapshot = false; entered = true; entry?.resume(); entry = nil
      await withCheckedContinuation { gate = $0 }
    }
    return .init(displays: [internalPanel, externalPanel], records: [])
  }
  func waitForSnapshot() async { if !entered { await withCheckedContinuation { entry = $0 } } }
  func releaseSnapshot() { gate?.resume(); gate = nil }
  func change(_ state: DisplayConnectionState, stableID: String) async throws -> DisplayConnectionOutcome {
    changes += 1
    throw LiteRefusal("Connection must be blocked during a brightness write")
  }
  func changeCount() -> Int { changes }
  func snapshotCount() -> Int { snapshots }
}

private final class NativeFixture: BrightnessBackend {
  let transport = BrightnessTransport.displayServices
  var available = true
  var level = 0.45
  var writes: [(UInt32, Double)] = []
  func supports(_ display: DisplayInfo) -> Bool { available && display.isBuiltin }
  func read(_ display: DisplayInfo) -> Double? { available ? level : nil }
  func write(_ display: DisplayInfo, value: Double) -> Bool {
    writes.append((display.id, value)); level = value; return true
  }
}

@Suite("Lite hardware brightness and interaction")
@MainActor
struct LiteBrightnessTests {
  @Test func wakeInvalidatesOldValueAndDiscardsReadAlreadyInFlight() async {
    let (model, access) = await prepared()
    await access.pauseNextRead()
    let read = Task { await model.reread(externalKey) }
    await access.waitForRead()
    model.invalidate(clearReadings: true)
    #expect(model.value(for: externalKey) == nil && !model.canAdjust(externalKey))
    await access.releaseRead(); await read.value
    #expect(model.value(for: externalKey) == nil)
    await model.refresh(displays: [internalPanel, externalPanel])
    #expect(model.value(for: externalKey) == 62 && model.canAdjust(externalKey))
    #expect(await access.calls().isEmpty)
  }

  @Test func topologyInvalidationDuringAWriteDoesNotReuseItsResult() async {
    let (model, access) = await prepared()
    await access.configure(block: true)
    let write = Task { await model.set(70, for: externalKey) }
    await access.wait()
    model.invalidate(clearReadings: true)
    await model.refresh(displays: [internalPanel, externalPanel])
    #expect(model.value(for: externalKey) == nil)
    await access.release(); await write.value
    // The result came from a new read after the write completed, not the old
    // operation's confirmation; no stale success announcement is retained.
    #expect(model.value(for: externalKey) == 70 && model.feedback[externalKey] == nil)
    #expect(await access.calls().count == 1)
    #expect(!model.isWorking)
  }

  @Test func topologyEventDuringSnapshotRequiresAnotherFreshSnapshot() async {
    let connection = ConnectionFixture(); let access = BrightnessFixture()
    let model = LiteModel(access: connection, brightnessAccess: access)
    await connection.pauseNextSnapshot()
    let refresh = Task { await model.refresh() }
    await connection.waitForSnapshot()
    model.invalidateForTopologyChange()
    #expect(!model.canChangeConnection)
    await connection.releaseSnapshot(); await refresh.value
    #expect(await connection.snapshotCount() == 2)
    #expect(model.canChangeConnection && model.brightness?.value(for: internalKey) == 45)
    #expect(await access.calls().isEmpty)
  }

  private func prepared() async -> (LiteBrightnessModel, BrightnessFixture) {
    let access = BrightnessFixture()
    let model = LiteBrightnessModel(access: access)
    await model.refresh(displays: [internalPanel, externalPanel])
    return (model, access)
  }

  /// Wait until this request has actually reached its first suspension point.
  private func enqueue(_ value: Int, id: String, model: LiteBrightnessModel) async -> Task<Void, Never> {
    var entered = false
    let request = Task { @MainActor in entered = true; await model.set(value, for: id) }
    while !entered { await Task.yield() }
    return request
  }

  @Test func readsBothKindsWithoutWritingAndUnknownNeverBecomesABaseline() async {
    let (model, access) = await prepared()
    #expect(model.value(for: internalKey) == 45)
    #expect(model.value(for: externalKey) == 62)
    #expect(await access.calls().isEmpty)
    await access.configure(readFails: true)
    await model.refresh(displays: [internalPanel, externalPanel])
    #expect(model.value(for: externalKey) == nil)
    #expect(!model.canAdjust(externalKey))
    await model.set(70, for: externalKey)
    #expect(await access.calls().isEmpty)
  }

  @Test(arguments: [false, true], [60, 80])
  func latestRequestOwnsFeedbackEvenWhenItRepeatsAnActiveValue(oldFails: Bool, latestValue: Int) async {
    let (model, access) = await prepared()
    await access.configure(block: true, fail: oldFails)
    var states: [LiteBrightnessFeedback] = []
    let subscription = model.$feedback.sink { if let state = $0[externalKey] { states.append(state) } }
    let first = Task { await model.set(60, for: externalKey) }
    await access.wait()
    let latest = await enqueue(latestValue, id: externalKey, model: model)
    #expect(model.value(for: externalKey) == latestValue)
    #expect(model.feedback[externalKey] == .confirming)
    await access.release(); await first.value; await latest.value
    #expect(model.confirmed[externalKey] == latestValue)
    #expect(states.filter { $0 == .confirmed }.count == 1)
    #expect(!states.contains { if case .failed = $0 { return true }; return false })
    #expect(await access.calls().map(\.1) == [60, latestValue])
    subscription.cancel()
  }

  @Test func coalescingIsPerScreenAndDoesNotDiscardTheOtherScreen() async {
    let (model, access) = await prepared()
    await access.configure(block: true)
    let first = Task { await model.set(60, for: externalKey) }
    await access.wait()
    let internalRequest = await enqueue(70, id: internalKey, model: model)
    let intermediate = await enqueue(80, id: externalKey, model: model)
    let latest = await enqueue(90, id: externalKey, model: model)
    await access.release()
    await first.value; await internalRequest.value; await intermediate.value; await latest.value
    #expect(await access.calls().map(\.1) == [60, 70, 90])
    #expect(model.value(for: internalKey) == 70)
    #expect(model.value(for: externalKey) == 90)
  }

  @Test func unplugAndReplugCannotAdoptAnOldResultOrQueuedRequest() async {
    let (model, access) = await prepared()
    await access.configure(block: true)
    let first = Task { await model.set(60, for: externalKey) }
    await access.wait()
    let latest = await enqueue(80, id: externalKey, model: model)
    await model.refresh(displays: [internalPanel])
    await model.refresh(displays: [internalPanel, externalPanel])
    await access.release(); await first.value; await latest.value
    #expect(await access.calls().map(\.1) == [60])
    #expect(model.value(for: externalKey) == nil)
    await model.refresh(displays: [internalPanel, externalPanel])
    #expect(model.value(for: externalKey) == 60)
  }

  @Test func failureRetainsLastConfirmedValueAndRefreshCanRecover() async {
    let (model, access) = await prepared()
    await access.configure(fail: true)
    await model.set(80, for: externalKey)
    #expect(model.value(for: externalKey) == 62)
    #expect(model.feedback[externalKey] == .failed("Fake unconfirmed write"))
    await access.configure()
    await model.set(80, for: externalKey)
    #expect(model.value(for: externalKey) == 80)
    #expect(model.feedback[externalKey] == .confirmed)
  }

  @Test func unsupportedAndAmbiguousTargetsAndInvalidValuesNeverWrite() async {
    let (model, access) = await prepared()
    await model.set(-1, for: internalKey); await model.set(101, for: externalKey)
    #expect(await access.calls().isEmpty)
    await model.refresh(displays: [externalPanel, externalPanel])
    await model.set(50, for: externalKey)
    #expect(await access.calls().isEmpty)
    let mirror = DisplayDescriptor(runtimeID: 42, stableID: externalKey, name: "Mirror",
      isBuiltIn: false, isVirtual: false, isMirrored: true)
    await model.refresh(displays: [mirror]); await model.set(50, for: externalKey)
    #expect(await access.calls().isEmpty)
  }

  @Test func writingKeepsRefreshQuietAndPreventsConnectionAndQuit() async {
    let connection = ConnectionFixture()
    let access = BrightnessFixture()
    let model = LiteModel(access: connection, brightnessAccess: access)
    await model.refresh()
    #expect(model.builtInDisplays.count == 1)
    await access.configure(block: true)
    let write = Task { await model.setBrightness(70, for: externalKey) }
    await access.wait()
    #expect(model.isBusy && !model.canQuit)
    #expect(!model.isRefreshingFromToolbar)
    await model.perform(model.rows[0])
    #expect(!(await model.restoreForQuit()))
    #expect(await connection.changeCount() == 0)
    await access.release(); await write.value
    #expect(model.canQuit)
  }

  @Test func onlyManualRefreshShowsItsBusyIndicatorAndItCannotBeStartedTwice() async {
    let connection = ConnectionFixture()
    let model = LiteModel(access: connection, brightnessAccess: BrightnessFixture())
    await connection.pauseNextSnapshot()
    let refresh = Task { await model.refreshFromToolbar() }
    await connection.waitForSnapshot()
    #expect(model.isRefreshingFromToolbar)
    #expect(!(await model.refreshFromToolbar()))
    #expect(model.isRefreshingFromToolbar)
    await connection.releaseSnapshot()
    #expect(await refresh.value)
    #expect(!model.isRefreshingFromToolbar)
    await model.refresh()
    #expect(!model.isRefreshingFromToolbar)
  }

  @Test func previewBrightnessAndConnectionShareOnlyTheSameMemoryScene() async throws {
    let access = LitePreviewAccess(compact: true)
    let model = LiteModel(access: access, brightnessAccess: access)
    await model.refresh()
    let row = try #require(model.rows.first)
    let id = try #require(row.stableID)
    await model.setBrightness(80, for: id)
    #expect(model.brightness?.value(for: id) == 80)
    #expect(!model.isRefreshingFromToolbar)
    await model.perform(row)
    #expect(model.rows[0].hasRecoveryRecord && !model.rows[0].isOnline)
    #expect(model.brightness?.value(for: id) == nil)
    await model.perform(model.rows[0])
    #expect(model.rows[0].isOnline)
    #expect(model.brightness?.value(for: id) == 80)
    #expect(model.pendingRecoveryCount == 0)
  }

  @Test(arguments: [LitePreviewBrightnessFailure.read, .write])
  func previewFailureCanRecoverWithoutTouchingTheOtherScreen(_ failure: LitePreviewBrightnessFailure) async throws {
    let access = LitePreviewAccess(compact: true, brightnessFailure: failure)
    let model = LiteModel(access: access, brightnessAccess: access)
    await model.refresh()
    let external = try #require(model.rows.first?.stableID)
    let builtin = try #require(model.builtInDisplays.first?.stableID)
    if failure == .write { await model.setBrightness(80, for: external) }
    #expect(model.brightness?.feedback[external] != nil)
    #expect(model.brightness?.value(for: external) == (failure == .read ? nil : 62))
    #expect(model.brightness?.value(for: builtin) == 45)
    await model.rereadBrightness(external)
    #expect(model.brightness?.value(for: external) == 62)
    #expect(model.brightness?.feedback[external] == nil)
    await model.setBrightness(80, for: external)
    #expect(model.brightness?.value(for: external) == 80)
    #expect(model.brightness?.value(for: builtin) == 45)
    #expect(!model.isRefreshingFromToolbar && model.pendingRecoveryCount == 0)
  }

  @Test func losingTopologyKeepsOnlyAnExplicitLastConfirmedValue() async {
    let (model, access) = await prepared()
    model.invalidate()
    #expect(model.value(for: externalKey) == 62)
    #expect(model.feedback[externalKey] == .failed("屏幕状态未确认，请刷新重试。"))
    #expect(!model.canAdjust(externalKey))
    await model.set(80, for: externalKey)
    #expect(await access.calls().isEmpty)
  }

  @Test func rowRetryReadsOnlyItsScreenAndKeepsOtherFailureAndToolbarQuiet() async {
    let connection = ConnectionFixture()
    let access = BrightnessFixture()
    await access.configure(readFails: true)
    let model = LiteModel(access: connection, brightnessAccess: access)
    await model.refresh()
    let otherFailure = model.brightness?.feedback[internalKey]
    let previousReads = await access.readCalls().count
    await access.configure()
    await model.rereadBrightness(externalKey)
    #expect(await access.readCalls().dropFirst(previousReads) == [externalKey])
    #expect(await connection.snapshotCount() == 1)
    #expect(model.brightness?.value(for: externalKey) == 62)
    #expect(model.brightness?.value(for: internalKey) == nil)
    #expect(model.brightness?.feedback[internalKey] == otherFailure)
    #expect(!model.isRefreshingFromToolbar)
    #expect(await access.calls().isEmpty)
  }

  @Test func rowRetryCannotReviveAnInvalidatedTargetOrRunDuringAWrite() async {
    let (model, access) = await prepared()
    await access.pauseNextRead()
    let read = Task { await model.reread(externalKey) }
    await access.waitForRead()
    #expect(model.isReading)
    #expect(model.valueDescription(for: externalKey) == "上次确认亮度")
    model.invalidate()
    await access.releaseRead(); await read.value
    #expect(model.feedback[externalKey] == .failed("屏幕状态未确认，请刷新重试。"))
    #expect(!model.canReread(externalKey) && !model.isReading)
    await model.refresh(displays: [internalPanel, externalPanel])
    await access.configure(block: true)
    let write = Task { await model.set(70, for: externalKey) }
    await access.wait()
    let readCount = await access.readCalls().count
    await model.reread(externalKey)
    #expect(await access.readCalls().count == readCount)
    await access.release(); await write.value
  }

  @Test func accessibleReadoutDistinguishesIntentConfirmationFailureAndUnknown() async {
    let (model, access) = await prepared()
    #expect(model.valueDescription(for: externalKey) == "已确认亮度")
    #expect(model.valueDescription(for: externalKey, dragging: true) == "目标亮度")
    await access.configure(block: true, fail: true)
    let write = Task { await model.set(80, for: externalKey) }
    await access.wait()
    #expect(model.valueDescription(for: externalKey) == "目标亮度")
    #expect(model.value(for: externalKey) == 80 && model.confirmed[externalKey] == 62)
    await access.release(); await write.value
    #expect(model.valueDescription(for: externalKey) == "上次确认亮度")
    await access.configure(readFails: true)
    await model.reread(externalKey)
    #expect(model.valueDescription(for: externalKey) == "亮度未知")
  }

  @Test func liveAdapterRoutesHardwareAndClaimsManualOwnershipWithoutGamma() async throws {
    let native = NativeFixture()
    let access = LiteHardwareBrightnessAccess()
    access.discovery = FixedBrightnessDiscovery(displays: [internalPanel, externalPanel])
    access.nativeBackend = native
    let store = StateStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("lite-brightness-\(UUID())/state.json"))
    access.coordinator = BrightnessCoordinator(store: store)
    var ddcWrites = 0
    access.readDDC = { _ in 62 }
    access.writeDDC = { value, id in #expect(id == externalKey); ddcWrites += 1; return value }
    #expect(try await access.read(stableID: internalKey) == 45)
    #expect(try await access.read(stableID: externalKey) == 62)
    #expect(try await access.write(percent: 55, stableID: internalKey) == 55)
    #expect(native.writes.count == 1 && native.writes[0].0 == 41)
    #expect(store.load().brightnessRevisions?[String(internalKey.dropFirst(5))] != nil)
    #expect(try await access.write(percent: 70, stableID: externalKey) == 70)
    #expect(ddcWrites == 1)
    native.available = false
    do { _ = try await access.write(percent: 30, stableID: internalKey); Issue.record("Native failure silently fell back") }
    catch {}
    #expect(ddcWrites == 1 && native.writes.count == 1)
    access.readDDC = { _ in .nan }
    do { _ = try await access.read(stableID: externalKey); Issue.record("Accepted invalid DDC reading") }
    catch {}
    access.discovery = FixedBrightnessDiscovery(displays: [externalPanel, externalPanel])
    do { _ = try await access.write(percent: 70, stableID: externalKey); Issue.record("Accepted duplicate identity") }
    catch {}
    #expect(ddcWrites == 1)
  }
}
