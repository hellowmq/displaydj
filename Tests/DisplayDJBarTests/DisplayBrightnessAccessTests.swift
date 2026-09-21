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
