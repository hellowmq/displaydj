import DisplayDJCore
import Testing
import VibeDisplayCore

@testable import DisplayDJBar

private let internalID = "uuid:11111111-2222-3333-4444-555555555555"
private let externalID = "uuid:11111111-2222-3333-4444-666666666666"

private func panel(_ builtin: Bool, runtimeID: UInt32? = nil, mirrored: Bool = false,
                   virtual: Bool = false) -> DisplayDescriptor {
  DisplayDescriptor(runtimeID: runtimeID ?? (builtin ? 71 : 72),
    stableID: builtin ? internalID : externalID,
    name: builtin ? "Built-in Retina" : "DELL", isBuiltIn: builtin,
    isVirtual: virtual, isMirrored: mirrored)
}

private struct BrightnessDiscovery: DisplayDiscovering {
  let displays: [DisplayDescriptor]
  func discoverDisplays() async throws -> [DisplayDescriptor] { displays }
}

private actor ChangingBrightnessDiscovery: DisplayDiscovering {
  private var displays: [DisplayDescriptor] = []
  private var scans = 0

  func discoverDisplays() async throws -> [DisplayDescriptor] {
    scans += 1
    return displays
  }

  func update(_ displays: [DisplayDescriptor]) { self.displays = displays }
  func scanCount() -> Int { scans }
}

private actor OutOfOrderBrightnessDiscovery: DisplayDiscovering {
  private var calls = 0
  private var firstStarted: CheckedContinuation<Void, Never>?
  private var firstResult: CheckedContinuation<[DisplayDescriptor], Never>?

  func discoverDisplays() async throws -> [DisplayDescriptor] {
    calls += 1
    guard calls == 1 else { return [panel(true)] }
    firstStarted?.resume()
    firstStarted = nil
    return await withCheckedContinuation { firstResult = $0 }
  }

  func waitForFirstScan() async {
    guard calls == 0 else { return }
    await withCheckedContinuation { firstStarted = $0 }
  }

  func finishFirstScan() {
    firstResult?.resume(returning: [])
    firstResult = nil
  }
}

private final class NativeBackendStub: BrightnessBackend {
  let transport = BrightnessTransport.displayServices
  var available = true
  var value: Double? = 0.43
  var acceptsWrite = true
  var appliesWrite = true
  var reads: [UInt32] = []
  var writes: [(UInt32, Double)] = []
  func supports(_ display: DisplayInfo) -> Bool { available && display.isBuiltin }
  func read(_ display: DisplayInfo) -> Double? {
    reads.append(display.id)
    return value
  }
  func write(_ display: DisplayInfo, value: Double) -> Bool {
    writes.append((display.id, value))
    if acceptsWrite && appliesWrite { self.value = value }
    return acceptsWrite
  }
}

@Suite("Menu bar native and external brightness routing")
@MainActor
struct DisplayBrightnessAccessTests {
  @Test func delayedTopologyRefreshFindsDisplayMissingAtFirstScan() async throws {
    let discovery = ChangingBrightnessDiscovery()
    let controller = DisplayBarController()
    controller.displayDiscovery = discovery

    await controller.scanAndRefresh()
    #expect(controller.displays.isEmpty)
    await discovery.update([panel(true)])
    controller.scheduleTopologyRescan()
    controller.scheduleTopologyRescan()
    try await Task.sleep(for: .milliseconds(700))

    #expect(controller.displays.count == 1)
    #expect(await discovery.scanCount() == 2)
  }

  @Test func staleEmptyScanCannotReplaceNewerDisplayList() async {
    let discovery = OutOfOrderBrightnessDiscovery()
    let controller = DisplayBarController()
    controller.displayDiscovery = discovery

    let first = Task { await controller.scanAndRefresh() }
    await discovery.waitForFirstScan()
    await controller.scanAndRefresh()
    await discovery.finishFirstScan()
    await first.value

    #expect(controller.displays.compactMap(\.stableID) == [internalID])
  }

  private func access(_ backend: NativeBackendStub,
                      displays: [DisplayDescriptor] = [panel(true), panel(false)]) -> DisplayBrightnessAccess {
    DisplayBrightnessAccess(discovery: BrightnessDiscovery(displays: displays),
      nativeBackend: backend,
      readDDC: { _ in Issue.record("Unexpected DDC read"); return 0 },
      writeDDC: { _, _ in Issue.record("Unexpected DDC write"); return 0 })
  }

  @Test func builtInUsesNativeAndFreshRuntimeID() async throws {
    let backend = NativeBackendStub()
    let router = access(backend, displays: [panel(true, runtimeID: 99)])
    #expect(try await router.read(stableID: internalID) == 43)
    #expect(try await router.write(percent: 67, stableID: internalID) == 67)
    #expect(backend.reads == [99, 99])
    #expect(backend.writes.count == 1)
    #expect(backend.writes.first?.0 == 99)
    #expect(backend.writes.first?.1 == 0.67)
  }

  @Test func externalUsesExistingDDCAndKeepsTarget() async throws {
    let backend = NativeBackendStub()
    var router = access(backend)
    var readTarget: String?
    var writeTarget: String?
    router.readDDC = { readTarget = $0; return 38 }
    router.writeDDC = { percent, id in
      writeTarget = id
      #expect(percent == 62)
      return 61.6
    }
    #expect(try await router.read(stableID: externalID) == 38)
    #expect(try await router.write(percent: 62, stableID: externalID) == 62)
    #expect(readTarget == externalID)
    #expect(writeTarget == externalID)
    #expect(backend.reads.isEmpty && backend.writes.isEmpty)
  }

  @Test func unavailableNativeDoesNotFallBackToDDCOrSoftwareDimming() async {
    let backend = NativeBackendStub()
    backend.available = false
    let router = access(backend)
    await #expect(throws: NativeBrightnessError.self) { try await router.read(stableID: internalID) }
    await #expect(throws: NativeBrightnessError.self) { try await router.write(percent: 60, stableID: internalID) }
    #expect(backend.writes.isEmpty)
  }

  @Test func failedNativeReadAndUnconfirmedWriteAreReported() async {
    let backend = NativeBackendStub()
    backend.value = nil
    let router = access(backend)
    await #expect(throws: NativeBrightnessError.self) { try await router.read(stableID: internalID) }
    backend.value = 0.43
    backend.appliesWrite = false
    await #expect(throws: NativeBrightnessError.self) { try await router.write(percent: 60, stableID: internalID) }
    backend.acceptsWrite = false
    await #expect(throws: NativeBrightnessError.self) { try await router.write(percent: 60, stableID: internalID) }
  }

  @Test func invalidTargetsAndMissingDisplaysNeverWrite() async {
    let backend = NativeBackendStub()
    let router = access(backend, displays: [])
    await #expect(throws: DisplayDJError.self) { try await router.write(percent: 101, stableID: internalID) }
    await #expect(throws: DisplayDJError.self) { try await router.write(percent: 50, stableID: internalID) }
    #expect(backend.writes.isEmpty)
  }

  @Test func nativeFailureRecoveryNamesItsOwnCard() {
    for error in [NativeBrightnessError.unavailable, .readFailed, .writeRejected, .unverified] {
      let failure = BrightnessFailurePresenter.failure(for: error,
        operation: .write(value: 60, displayStableID: internalID))
      #expect(failure.recovery == .retryWrite(value: 60, displayStableID: internalID))
      #expect(!failure.suggestion.contains("DDC"))
      #expect(!failure.suggestion.contains("线缆"))
      #expect(!failure.suggestion.contains("已经恢复"))
    }
  }

  @Test func controllerShowsAndAdjustsBothPanelsIndependently() async throws {
    let backend = NativeBackendStub()
    let controller = DisplayBarController()
    controller.displayDiscovery = BrightnessDiscovery(displays: [panel(true), panel(false)])
    var router = access(backend)
    router.readDDC = { _ in 35 }
    router.writeDDC = { percent, id in
      #expect(id == externalID)
      return percent
    }
    controller.brightnessAccess = router
    await controller.scanAndRefresh()
    #expect(Set(controller.displays.compactMap(\.stableID)) == [internalID, externalID])
    await controller.refreshDisplay(stableID: internalID, trigger: .userRequest)
    await controller.refreshDisplay(stableID: externalID, trigger: .userRequest)
    #expect(controller.brightnessByID[internalID] == 43)
    #expect(controller.brightnessByID[externalID] == 35)
    await controller.setBrightness(65, for: internalID)
    #expect(controller.brightnessByID[internalID] == 65)
    #expect(controller.brightnessByID[externalID] == 35)
    await controller.setBrightness(55, for: externalID)
    #expect(controller.brightnessByID[internalID] == 65)
    #expect(controller.brightnessByID[externalID] == 55)
    #expect(backend.writes.count == 1)
    #expect(controller.intendedByID.isEmpty)
  }

  @Test func optedInSyncMovesTwoConfirmedDisplaysByTheSameDelta() async {
    let backend = NativeBackendStub()
    let controller = DisplayBarController()
    controller.preferencesStore = InMemoryDisplayPreferencesStore()
    controller.displayDiscovery = BrightnessDiscovery(displays: [panel(true), panel(false)])
    var externalValue = 35.0
    var externalWrites: [Double] = []
    var router = access(backend)
    router.readDDC = { _ in externalValue }
    router.writeDDC = { percent, id in
      #expect(id == externalID)
      externalWrites.append(percent)
      externalValue = percent
      return percent
    }
    controller.brightnessAccess = router
    await controller.scanAndRefresh()

    await controller.setBrightnessSyncEnabled(true)
    #expect(controller.isBrightnessSyncEnabled)
    await controller.setBrightness(48, for: internalID)
    #expect(controller.brightnessByID[internalID] == 48)
    #expect(controller.brightnessByID[externalID] == 40)
    #expect(externalWrites == [40])
    #expect(backend.writes.last?.1 == 0.48)
  }

  @Test func missingFollowerReadingTurnsSyncOffBeforeTheSourceWrite() async {
    let backend = NativeBackendStub()
    let controller = DisplayBarController()
    controller.preferencesStore = InMemoryDisplayPreferencesStore()
    controller.displayDiscovery = BrightnessDiscovery(displays: [panel(true), panel(false)])
    var externalWrites: [Double] = []
    var router = access(backend)
    router.readDDC = { _ in 35 }
    router.writeDDC = { percent, _ in externalWrites.append(percent); return percent }
    controller.brightnessAccess = router
    await controller.scanAndRefresh()
    await controller.setBrightnessSyncEnabled(true)
    controller.setBrightnessForDisplay(nil, id: externalID)

    await controller.setBrightness(48, for: internalID)

    #expect(controller.isBrightnessSyncEnabled == false)
    #expect(controller.brightnessByID[internalID] == 48)
    #expect(externalWrites.isEmpty)
    #expect(controller.failures.topology?.summary == "无法同步调节显示器")
  }

  @Test func unreadableExternalCannotEnableHardwareSync() async {
    let backend = NativeBackendStub()
    let controller = DisplayBarController()
    controller.preferencesStore = InMemoryDisplayPreferencesStore()
    controller.displayDiscovery = BrightnessDiscovery(displays: [panel(true), panel(false)])
    var router = access(backend)
    router.readDDC = { _ in
      throw DisplayDJError(code: .transportFailure, message: "Get VCP failed")
    }
    controller.brightnessAccess = router
    await controller.scanAndRefresh()

    await controller.setBrightnessSyncEnabled(true)

    #expect(controller.isBrightnessSyncEnabled == false)
    #expect(controller.failures.topology?.summary == "无法同步调节显示器")
    #expect(backend.writes.isEmpty)
  }

  @Test func invalidExternalReadingCannotEnableHardwareSync() async {
    let backend = NativeBackendStub()
    let controller = DisplayBarController()
    controller.preferencesStore = InMemoryDisplayPreferencesStore()
    controller.displayDiscovery = BrightnessDiscovery(displays: [panel(true), panel(false)])
    var router = access(backend)
    router.readDDC = { _ in 101 }
    controller.brightnessAccess = router
    await controller.scanAndRefresh()

    await controller.setBrightnessSyncEnabled(true)

    #expect(controller.isBrightnessSyncEnabled == false)
    #expect(controller.failures.topology?.summary == "无法同步调节显示器")
    #expect(backend.writes.isEmpty)
  }

  @Test func transientReadFailureStaysNeutralUntilNextRead() async {
    let backend = NativeBackendStub()
    backend.value = nil
    let controller = DisplayBarController()
    controller.displayDiscovery = BrightnessDiscovery(displays: [panel(true)])
    controller.brightnessAccess = access(backend, displays: [panel(true)])
    await controller.scanAndRefresh()

    await controller.refreshDisplay(stableID: internalID, trigger: .userRequest)
    #expect(controller.displayedBrightness(for: internalID) == nil)
    #expect(controller.failure(for: internalID) == nil)
    #expect(controller.readFailureCounts[internalID] == 1)
    #expect(!controller.canAdjustRelatively(internalID))

    backend.value = 0.43
    await controller.refreshDisplay(stableID: internalID, trigger: .userRequest)
    #expect(controller.displayedBrightness(for: internalID) == 43)
    #expect(controller.failure(for: internalID) == nil)
    #expect(controller.readFailureCounts[internalID] == nil)

    controller.invalidateBrightnessAfterWake()
    #expect(controller.displayedBrightness(for: internalID) == nil)
    #expect(!controller.canAdjustRelatively(internalID))
    #expect(backend.writes.isEmpty)
  }

  @Test func repeatedReadFailureShowsRecovery() async {
    let backend = NativeBackendStub()
    backend.value = nil
    let controller = DisplayBarController()
    controller.displayDiscovery = BrightnessDiscovery(displays: [panel(true)])
    controller.brightnessAccess = access(backend, displays: [panel(true)])
    await controller.scanAndRefresh()

    await controller.refreshDisplay(stableID: internalID, trigger: .userRequest)
    #expect(controller.failure(for: internalID) == nil)
    await controller.refreshDisplay(stableID: internalID, trigger: .userRequest)
    #expect(controller.failure(for: internalID)?.recovery == .retryRead(displayStableID: internalID))
  }

  @Test func visiblePanelsIncludeBuiltInButExcludeMirrorsAndVirtualDisplays() {
    #expect(DisplayBrightnessAccess.visibleDisplays([
      panel(true), panel(false), panel(true, mirrored: true), panel(false, virtual: true)
    ]) == [panel(true), panel(false)])
  }

  @Test func addingBuiltInBrightnessDoesNotEnableDisconnectingIt() {
    let availability = DisplayConnectionAvailabilityResolver.resolve(
      isSupported: true, onlineCount: 2, isMirrored: false, isBuiltIn: true)
    #expect(availability == .builtInDisplay)
    #expect(!availability.canDisconnect)
  }
}
