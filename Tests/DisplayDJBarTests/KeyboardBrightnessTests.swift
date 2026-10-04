import Foundation
import DisplayDJCore
import Testing
@testable import VibeDisplayCore
@testable import DisplayDJBar

private let screenA = "uuid:11111111-2222-3333-4444-555555555555"
private let screenB = "uuid:11111111-2222-3333-4444-666666666666"

private actor KeyboardDiscovery: DisplayDiscovering {
  var displays = [DisplayDescriptor(runtimeID: 71, stableID: screenA, name: "A", isBuiltIn: false,
                                    isVirtual: false, isMirrored: false),
                  DisplayDescriptor(runtimeID: 72, stableID: screenB, name: "B", isBuiltIn: false,
                                    isVirtual: false, isMirrored: false)]
  func discoverDisplays() async throws -> [DisplayDescriptor] { displays }
  func removeA() { displays.removeFirst() }
}

@MainActor
private final class KeyboardGate {
  private var entered = false
  private var entryWaiter: CheckedContinuation<Void, Never>?
  private var releaseWaiter: CheckedContinuation<Void, Never>?
  func wait() async {
    entered = true
    entryWaiter?.resume()
    entryWaiter = nil
    await withCheckedContinuation { releaseWaiter = $0 }
  }
  func waitForEntry() async {
    if !entered { await withCheckedContinuation { entryWaiter = $0 } }
  }
  func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

@MainActor
private final class KeyboardHardware {
  var values: [String: Double] = [screenA: 50, screenB: 70]
  var writes: [BrightnessIntent] = []
  var readGate: KeyboardGate?
  var writeGate: KeyboardGate?
  var readFails = false
  var failedReadID: String?
  var failedWriteID: String?
  var observedOffset: Double = 0
  var feedback: [BrightnessHUDContent] = []

  func read(_ id: String) async throws -> Double {
    if let gate = readGate { readGate = nil; await gate.wait() }
    if readFails || failedReadID == id { throw NativeBrightnessError.readFailed }
    return values[id]!
  }
  func write(_ value: Double, _ id: String) async throws -> Double {
    writes.append(.init(value: Int(value), displayStableID: id))
    if let gate = writeGate { writeGate = nil; await gate.wait() }
    if failedWriteID == id { throw NativeBrightnessError.unverified }
    values[id] = value + observedOffset
    return values[id]!
  }
}

@Suite("Keyboard brightness queue and verified feedback")
@MainActor
struct KeyboardBrightnessTests {
  private func fixture() async -> (DisplayBarController, KeyboardHardware, StateStore, KeyboardDiscovery) {
    let discovery = KeyboardDiscovery()
    let hardware = KeyboardHardware()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("displaydj-keyboard-\(UUID().uuidString)")
    let store = StateStore(url: directory.appendingPathComponent("state.json"))
    let controller = DisplayBarController()
    controller.displayDiscovery = discovery
    controller.preferencesStore = FileDisplayPreferencesStore(fileURL: directory.appendingPathComponent("preferences.json"))
    controller.brightnessAccess = DisplayBrightnessAccess(coordinator: BrightnessCoordinator(store: store),
      discovery: discovery,
      readDDC: { try await hardware.read($0) }, writeDDC: { try await hardware.write($0, $1) })
    controller.keyboardFeedbackPresenter = { hardware.feedback.append($0) }
    await controller.scanAndRefresh()
    return (controller, hardware, store, discovery)
  }

  @Test func coldReadCoalescesAndClampsEveryStep() async {
    let (controller, hardware, _, _) = await fixture()
    hardware.values[screenA] = 98
    let gate = KeyboardGate()
    hardware.readGate = gate
    controller.enqueueKeyboardBrightness(by: 5, for: screenA)
    await gate.waitForEntry()
    controller.enqueueKeyboardBrightness(by: 5, for: screenA)
    controller.enqueueKeyboardBrightness(by: -5, for: screenA)
    gate.release()
    await controller.keyboardTask?.value
    #expect(hardware.writes == [.init(value: 95, displayStableID: screenA)])
    #expect(hardware.feedback.first?.state == .reading)
    #expect(hardware.feedback.last?.state == .confirmed(95))
  }

  @Test func slowWritePreservesLaterStepsInOneFollowUpWrite() async {
    let (controller, hardware, _, _) = await fixture()
    let gate = KeyboardGate()
    hardware.writeGate = gate
    controller.enqueueKeyboardBrightness(by: 5, for: screenA)
    await gate.waitForEntry()
    for delta in [5, 5, -5] { controller.enqueueKeyboardBrightness(by: delta, for: screenA) }
    gate.release()
    await controller.keyboardTask?.value
    #expect(hardware.writes.map(\.value) == [55, 60])
    #expect(hardware.feedback.last?.state == .confirmed(60))
  }

  @Test func targetIsCapturedAndDifferentScreensKeepTheirSteps() async {
    let (controller, hardware, _, _) = await fixture()
    controller.enqueueKeyboardBrightness(by: 5, for: screenA)
    controller.enqueueKeyboardBrightness(by: -5, for: screenB)
    controller.enqueueKeyboardBrightness(by: 5, for: screenA)
    controller.hotkeyTarget = .mouse
    await controller.keyboardTask?.value
    #expect(hardware.writes == [.init(value: 55, displayStableID: screenA),
                               .init(value: 65, displayStableID: screenB),
                               .init(value: 60, displayStableID: screenA)])
  }

  @Test func freshHardwareValueReplacesStaleMenuReading() async {
    let (controller, hardware, _, _) = await fixture()
    controller.setBrightnessForDisplay(10, id: screenA)
    hardware.values[screenA] = 63
    controller.enqueueKeyboardBrightness(by: 5, for: screenA)
    await controller.keyboardTask?.value
    #expect(hardware.writes.first?.value == 68)
  }

  @Test func readFailureNeverWritesOrPresentsSuccess() async {
    let (controller, hardware, _, _) = await fixture()
    hardware.readFails = true
    controller.enqueueKeyboardBrightness(by: 5, for: screenA)
    await controller.keyboardTask?.value
    #expect(hardware.writes.isEmpty)
    #expect(hardware.feedback.last?.isFailure == true)
    #expect(controller.brightnessByID[screenA] == nil)
    #expect(controller.failure(for: screenA) != nil)
  }

  @Test func writeFailureDoesNotConfirmRequestedValue() async {
    let (controller, hardware, _, _) = await fixture()
    hardware.failedWriteID = screenA
    controller.enqueueKeyboardBrightness(by: 5, for: screenA)
    await controller.keyboardTask?.value
    #expect(hardware.feedback.last?.isFailure == true)
    #expect(!hardware.feedback.contains { if case .confirmed = $0.state { true } else { false } })
  }

  @Test func feedbackUsesObservedValueAndReportsFollowerFailure() async {
    let (controller, hardware, _, _) = await fixture()
    controller.preferences.syncBrightness = true
    controller.setBrightnessForDisplay(70, id: screenB)
    hardware.failedWriteID = screenB
    hardware.observedOffset = -1
    controller.enqueueKeyboardBrightness(by: 5, for: screenA)
    await controller.keyboardTask?.value
    #expect(hardware.feedback.contains { $0.runtimeID == 71 && $0.state == .confirmed(54) })
    #expect(hardware.feedback.last(where: { $0.runtimeID == 72 })?.isFailure == true)
    #expect(hardware.writes.map(\.value) == [55, 75])
  }

  @Test func synchronizationAlsoReadsFreshFollowerBaseline() async {
    let (controller, hardware, _, _) = await fixture()
    controller.preferences.syncBrightness = true
    controller.setBrightnessForDisplay(20, id: screenB)
    hardware.values[screenB] = 83
    controller.enqueueKeyboardBrightness(by: 5, for: screenA)
    await controller.keyboardTask?.value
    #expect(hardware.writes.map(\.value) == [55, 88])
    #expect(hardware.feedback.last(where: { $0.runtimeID == 72 })?.state == .confirmed(88))
  }

  @Test func synchronizedBurstPreservesFollowerClampingBeforeReversal() async {
    let (controller, hardware, _, _) = await fixture()
    controller.preferences.syncBrightness = true
    hardware.values[screenB] = 98
    let gate = KeyboardGate()
    hardware.readGate = gate
    controller.enqueueKeyboardBrightness(by: 5, for: screenA)
    await gate.waitForEntry()
    controller.enqueueKeyboardBrightness(by: -5, for: screenA)
    gate.release()
    await controller.keyboardTask?.value
    #expect(hardware.writes == [.init(value: 50, displayStableID: screenA),
                               .init(value: 95, displayStableID: screenB)])
  }

  @Test func failedFollowerReadDisablesSyncAndExplainsItOnThatScreen() async {
    let (controller, hardware, _, _) = await fixture()
    controller.preferences.syncBrightness = true
    controller.setBrightnessForDisplay(70, id: screenB)
    hardware.failedReadID = screenB
    controller.enqueueKeyboardBrightness(by: 5, for: screenA)
    await controller.keyboardTask?.value
    #expect(!controller.isBrightnessSyncEnabled)
    #expect(hardware.writes == [.init(value: 55, displayStableID: screenA)])
    #expect(hardware.feedback.last(where: { $0.runtimeID == 72 })?.isFailure == true)
    #expect(hardware.feedback.last(where: { $0.runtimeID == 71 })?.state == .confirmed(55))
  }

  @Test func laterSliderIntentSupersedesColdKeyboardRead() async {
    let (controller, hardware, _, _) = await fixture()
    let gate = KeyboardGate()
    hardware.readGate = gate
    controller.enqueueKeyboardBrightness(by: 5, for: screenA)
    await gate.waitForEntry()
    await controller.setBrightness(35, for: screenA)
    gate.release()
    await controller.keyboardTask?.value
    #expect(hardware.writes == [.init(value: 35, displayStableID: screenA)])
    #expect(controller.brightnessByID[screenA] == 35)
  }

  @Test func unplugDuringReadDiscardsCapturedRequest() async {
    let (controller, hardware, _, discovery) = await fixture()
    let gate = KeyboardGate()
    hardware.readGate = gate
    controller.enqueueKeyboardBrightness(by: 5, for: screenA)
    await gate.waitForEntry()
    await discovery.removeA()
    await controller.scanAndRefresh()
    gate.release()
    await controller.keyboardTask?.value
    #expect(hardware.writes.isEmpty)
    #expect(controller.brightnessByID[screenA] == nil)
  }

  @Test func disablingWhileReadingDiscardsUnsubmittedWrites() async {
    let (controller, hardware, _, _) = await fixture()
    let gate = KeyboardGate()
    hardware.readGate = gate
    controller.enqueueKeyboardBrightness(by: 5, for: screenA)
    await gate.waitForEntry()
    controller.discardKeyboardSteps()
    gate.release()
    await controller.keyboardTask?.value
    #expect(hardware.writes.isEmpty)
  }

  @Test func disablingMediaKeysPreservesPendingShortcutSteps() async {
    let (controller, hardware, _, _) = await fixture()
    let gate = KeyboardGate()
    hardware.readGate = gate
    controller.enqueueKeyboardBrightness(by: 5, for: screenA, source: .mediaKey)
    await gate.waitForEntry()
    controller.enqueueKeyboardBrightness(by: -5, for: screenA, source: .shortcut)
    controller.discardKeyboardSteps(from: .mediaKey)
    gate.release()
    await controller.keyboardTask?.value
    #expect(hardware.writes == [.init(value: 45, displayStableID: screenA)])
  }

  @Test func disablingOnlySourceDuringReadDoesNotWriteAnUnchangedBaseline() async {
    let (controller, hardware, _, _) = await fixture()
    let gate = KeyboardGate()
    hardware.readGate = gate
    controller.enqueueKeyboardBrightness(by: 5, for: screenA, source: .mediaKey)
    await gate.waitForEntry()
    controller.discardKeyboardSteps(from: .mediaKey)
    gate.release()
    await controller.keyboardTask?.value
    #expect(hardware.writes.isEmpty)
  }

  @Test func keyAtUpperLimitStillRetiresAgentOwnership() async {
    let (controller, hardware, store, _) = await fixture()
    hardware.values[screenA] = 100
    let uuid = String(screenA.dropFirst(5)).uppercased()
    let key = uuid.lowercased()
    store.mutate {
      $0.brightnessSnapshots[uuid] = 0.6
      $0.brightnessSnapshotTransports = [uuid: .ddc]
      $0.brightnessRevisions = [key: "agent-revision"]
      $0.brightnessSnapshotOwnership = [uuid: .init(revision: "agent-revision", sessionID: "agent")]
    }
    controller.enqueueKeyboardBrightness(by: 5, for: screenA)
    await controller.keyboardTask?.value
    #expect(hardware.writes.first?.value == 100)
    #expect(store.load().brightnessSnapshots[uuid] == nil)
    #expect(store.load().brightnessRevisions?[key] != "agent-revision")
  }
}
