import Combine
import DisplayDJCore
import Foundation
import Testing
@testable import DisplayDJBar

private actor WriteGate {
  var started = false
  var entered: CheckedContinuation<Void, Never>?
  var suspended: CheckedContinuation<Void, Never>?
  func pause() async {
    started = true; entered?.resume(); entered = nil
    await withCheckedContinuation { suspended = $0 }
  }
  func wait() async { if !started { await withCheckedContinuation { entered = $0 } } }
  func resume() { suspended?.resume(); suspended = nil }
}
private struct RejectedConnection: DisplayConfigurationTransactionApplying {
  func setEnabled(_ enabled: Bool, forRuntimeID id: UInt32) throws {
    throw DisplayDJError(code: .verificationFailed, message: "fake rejected change")
  }
}
private struct UnreadableRecords: DisplayConnectionRecordStoring {
  func loadRecords() throws -> [DisplayConnectionRecord] { throw CocoaError(.fileReadCorruptFile) }
  func saveRecords(_ records: [DisplayConnectionRecord]) throws { Issue.record("Must not overwrite unreadable records") }
}

@Suite("Full interaction state, selection and recovery")
@MainActor
struct FullInteractionTests {
  private func prepared() async -> (DisplayBarController, FullInteractionPreview) {
    let controller = DisplayBarController()
    let world = FullInteractionPreview(count: 2)
    world.configure(controller)
    controller.connectionSupported = true
    await controller.scanAndRefresh()
    return (controller, world)
  }

  @Test func keyboardSummarySeparatesWheelSelectionAndPointerPolicy() async {
    let (controller, _) = await prepared()
    #expect(controller.keyboardSummary == nil)
    controller.hotkeysEnabled = true
    controller.hasAccessibilityPermission = false
    #expect(controller.keyboardSummary == "键盘控制待授权")
    controller.hasAccessibilityPermission = true
    #expect(controller.keyboardSummary == "键盘监听未建立")
    controller.hotkeysEnabled = false
    controller.mediaKeysEnabled = true
    controller.mediaKeysStatus = .active
    controller.hotkeyTarget = .mouse
    #expect(controller.keyboardSummary == "按键目标：鼠标所在屏幕")
    #expect(ScrollTargetBadge.title == "菜单栏滚轮目标")
  }

  @Test func keyboardReorderingKeepsIdentitySelectionAndPersistsOrder() async throws {
    let (controller, _) = await prepared()
    let selected = controller.selectedDisplayKey
    let first = controller.displays[0]
    controller.moveDisplay(first, offset: 1)
    #expect(controller.displays.last?.selectionKey == first.selectionKey)
    #expect(controller.selectedDisplayKey == selected)
    #expect(try controller.preferencesStore.loadPreferences().manualOrder == controller.displays.compactMap(\.stableID))
    controller.moveDisplay(first, offset: 1)
    #expect(controller.displays.last?.selectionKey == first.selectionKey)
  }

  @Test(arguments: [false, true], [60, 80])
  func supersededWriteCannotShowConfirmedOrFailureForLatestIntent(oldFails: Bool, latestValue: Int) async throws {
    let (controller, _) = await prepared()
    let id = try #require(controller.displays.first { !$0.isBuiltIn }?.stableID)
    let gate = WriteGate()
    var calls = 0
    controller.brightnessAccess.writeDDC = { value, _ in
      calls += 1
      if calls == 1 {
        await gate.pause()
        if oldFails { throw DisplayDJError(code: .transportFailure, message: "old request failed") }
      }
      return value
    }
    var states: [BrightnessOperationFeedback] = []
    let subscription = controller.$brightnessFeedback.sink { map in if let state = map[id] { states.append(state) } }
    let first = Task { await controller.setBrightness(60, for: id) }
    await gate.wait()
    #expect(controller.isWriting)
    #expect(!controller.isRefreshingFromToolbar)
    let latest = Task { await controller.setBrightness(latestValue, for: id) }
    for _ in 0..<1000 {
      if controller.intents.hasPending { break }
      await Task.yield()
    }
    #expect(controller.intents.hasPending)
    #expect(controller.intendedByID[id] == latestValue)
    #expect(controller.brightnessFeedback[id] == .confirming)
    await gate.resume(); await first.value; await latest.value
    #expect(controller.brightnessByID[id] == latestValue)
    #expect(controller.brightnessFeedback[id] == .confirmed)
    #expect(states.filter { $0 == .confirmed }.count == 1)
    #expect(!states.contains(.failed))
    #expect(controller.failure(for: id) == nil)
    subscription.cancel()
  }

  @Test func partialSyncFailureKeepsEachResultAndDoesNotClaimWholeGroupSuccess() async throws {
    let (controller, _) = await prepared()
    let ids = controller.displays.compactMap(\.stableID)
    for id in ids { controller.setBrightnessForDisplay(40, id: id) }
    controller.preferences.syncBrightness = true
    controller.brightnessAccess.writeDDC = { _, _ in throw DisplayDJError(code: .transportFailure, message: "fake follower failure") }
    let source = try #require(controller.displays.first { $0.isBuiltIn }?.stableID)
    await controller.setBrightness(60, for: source)
    #expect(controller.brightnessSyncResults[source] == true)
    #expect(controller.brightnessSyncResults.values.contains(false))
    #expect(controller.brightnessFeedback[source] == .confirmed)
    #expect(controller.brightnessSyncResults.count == 2)
  }

  @Test func quitRestoresCurrentRecordAndPreservesReusedHistoricalIdentity() async throws {
    let (controller, _) = await prepared()
    let target = try #require(controller.displays.first { !$0.isBuiltIn })
    let old = DisplayConnectionRecord(runtimeID: target.runtimeID,
      stableID: "uuid:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", name: "Old", requiresRediscovery: true)
    try controller.connectionStore.saveRecords([old])
    await controller.disconnect(target)
    #expect(try controller.connectionStore.loadRecords().count == 2)
    #expect(!controller.displays.contains { $0.stableID == target.stableID })
    #expect(await controller.restoreConnectionsForQuit())
    #expect(controller.displays.contains { $0.stableID == target.stableID })
    #expect(try controller.connectionStore.loadRecords() == [old])
  }

  @Test func failedQuitRecoveryRetainsRecordAndDoesNotApproveExit() async throws {
    let (controller, world) = await prepared()
    let target = try #require(controller.displays.first { !$0.isBuiltIn })
    await controller.disconnect(target)
    controller.connectionControllerFactory = {
      DisplayConnectionController(discovery: world, transaction: RejectedConnection(), store: controller.connectionStore,
        ledger: DisplayConnectionIntentLedger(store: InMemoryDisplayConnectionIntentStore()), verificationAttempts: 1, verificationDelay: .zero)
    }
    #expect(!(await controller.restoreConnectionsForQuit()))
    #expect(controller.quitRecoveryFailed)
    #expect(controller.connectionNotice?.id == target.stableID)
    #expect(try controller.connectionStore.loadRecords().count == 1)
    #expect(!controller.isRestoringConnections)
  }

  @Test func unreadableRecoveryRecordsAreVisibleAndPreventExit() async {
    let (controller, _) = await prepared()
    controller.connectionStore = UnreadableRecords()
    controller.refreshDisconnectedDisplays()
    #expect(controller.connectionRecordError != nil)
    #expect(!(await controller.restoreConnectionsForQuit()))
  }

  @Test func allPanelContentFitsScreenBudgetIncludingRecoveryAndErrors() {
    #expect(DisplayCardsViewport.height(contentHeight: 900, availableHeight: 500, chromeHeight: 280) == 220)
    #expect(DisplayCardsViewport.height(contentHeight: 900, availableHeight: 1000, chromeHeight: 280) == 400)
  }
}
