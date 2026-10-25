import DisplayDJCore
import Foundation
import AppKit
import Darwin

// MARK: - Display connection
//
// Its own file because the controller is already at the length limit, and because
// connecting a display is one more thing this app can do rather than one more
// block inside brightness handling.

extension DisplayBarController {
  /// Whether this system exposes the entry point that disconnecting needs.
  ///
  /// Probed rather than assumed: the symbol is private and may be absent or
  /// renamed, and a control that fails identically on every tap is worse than
  /// one that says up front that it cannot work here.
  func probeConnectionSupport() -> Bool {
    ProcessDisplayConnectionSymbolResolver()
      .resolve(.configureDisplayEnabled) != nil
  }

  /// Rebuilds the list of displays this tool disconnected.
  func refreshDisconnectedDisplays() {
    do {
      let saved = try connectionStore.loadRecords()
      let records = saved.map { record -> DisplayConnectionRecord in
        guard record.requiresRediscovery != true,
              !connectionTopology.contains(where: { $0.stableID == record.stableID && record.stableID != nil }) else { return record }
        var boot = timeval(); var size = MemoryLayout<timeval>.size
        let knowsBoot = sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0
        let reused = connectionTopology.contains { $0.runtimeID == record.runtimeID }
        guard reused || (knowsBoot && record.disconnectedAt < Date(timeIntervalSince1970: Double(boot.tv_sec))) else { return record }
        return .init(runtimeID: record.runtimeID, stableID: record.stableID, name: record.name,
          disconnectedAt: record.disconnectedAt, requiresRediscovery: true)
      }
      if records != saved { try connectionStore.saveRecords(records) }
      disconnectedDisplays = records.sorted { $0.disconnectedAt < $1.disconnectedAt }
      connectionRecordError = nil
    } catch {
      connectionRecordError = "恢复记录无法读取或保存，已暂停连接操作。原记录仍保留，请刷新重试。"
    }
  }

  /// Whether the given display can be disconnected from here.
  func connectionAvailability(
    for display: DisplayDescriptor
  ) -> DisplayConnectionAvailability {
    if display.stableID == nil || display.isVirtual != false { return .unidentified }
    if connectionRecordError != nil { return .unidentified }
    return DisplayConnectionAvailabilityResolver.resolve(
      isSupported: connectionSupported,
      onlineCount: onlineDisplayCount,
      isMirrored: display.isMirrored,
      isBuiltIn: display.isBuiltIn
    )
  }

  /// Stops output to a display that is currently online.
  func disconnect(_ display: DisplayDescriptor) async {
    guard connectionRecordError == nil,
          connectionAvailability(for: display).canDisconnect,
          !isLoading, !isRestoringConnections else { return }
    let fresh = try? await displayDiscovery.discoverDisplays()
    guard let fresh, fresh.filter({ $0.selectionKey == display.selectionKey }).count == 1,
          let target = fresh.first(where: { $0.selectionKey == display.selectionKey }),
          target.runtimeID == display.runtimeID, !target.isBuiltIn, !target.isMirrored else {
      connectionNotice = .init(id: display.selectionKey, summary: "目标屏幕已变化，未执行断开",
        suggestion: "请刷新后重新选择目标。")
      return
    }
    await applyConnection(
      .disconnected,
      selector: Self.selector(for: display),
      displayName: display.name,
      targetKey: display.selectionKey
    )
  }

  /// Restores output to a display this tool disconnected.
  ///
  /// Resolve through the saved stable identity, recheck the current topology,
  /// and let the core verify that same identity after restoration. Never accept
  /// an unrelated display merely because it inherited the old runtime ID.
  func reconnect(_ record: DisplayConnectionRecord) async {
    guard recoveryGuidance(for: record) == nil, let stableID = record.stableID else { return }
    let fresh = try? await displayDiscovery.discoverDisplays()
    guard let fresh else {
      connectionNotice = .init(id: DisplayConnectionList.key(for: record), summary: "无法核验当前目标",
        suggestion: "未执行重连，恢复记录已保留。请刷新重试。")
      return
    }
    if !fresh.contains(where: { $0.stableID == stableID }),
       let reused = fresh.first(where: { $0.runtimeID == record.runtimeID }), reused.stableID != stableID {
      refreshDisconnectedDisplays()
      connectionNotice = .init(id: DisplayConnectionList.key(for: record), summary: "目标身份已变化",
        suggestion: "已停止重连，恢复记录仍保留。请接好原屏幕后刷新。")
      return
    }
    await applyConnection(
      .connected,
      selector: .stableID(stableID),
      displayName: record.name,
      targetKey: DisplayConnectionList.key(for: record)
    )
  }

  func recoveryGuidance(for record: DisplayConnectionRecord) -> String? {
    if let error = connectionRecordError { return error }
    guard let id = record.stableID, id.hasPrefix("uuid:"), UUID(uuidString: String(id.dropFirst(5))) != nil else {
      return "恢复身份无法确认，请重新接好原屏幕后刷新。"
    }
    if disconnectedDisplays.filter({ $0.stableID == id }).count != 1 { return "恢复身份重复，已停止操作。" }
    if connectionTopology.contains(where: { $0.stableID == id }) { return nil }
    if record.requiresRediscovery == true { return "未接入 · 历史记录保留；接好原屏幕后刷新。" }
    return nil
  }

  func requestDisconnect(_ display: DisplayDescriptor) {
    guard !isLoading, !isRestoringConnections, !isConfirmingDisconnect else { return }
    isConfirmingDisconnect = true
    popover?.performClose(nil)
    let alert = NSAlert()
    alert.messageText = "断开「\(alias(for: display))」？"
    alert.informativeText = "这台屏幕会从 Mac 桌面布局中移除，窗口移到其他在线屏幕。之后可在 DisplayDJ 中重新连接。"
    alert.addButton(withTitle: "取消").keyEquivalent = "\r"
    alert.addButton(withTitle: "断开这台显示器").keyEquivalent = ""
    let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let cancelled = MainActor.assumeIsolated {
        guard event.window === alert.window, [UInt16(53), 36, 76].contains(event.keyCode) else { return false }
        NSApp.stopModal(withCode: .alertFirstButtonReturn)
        return true
      }
      return cancelled ? nil : event
    }
    NSApp.activate(ignoringOtherApps: true)
    let approved = alert.runModal() == .alertSecondButtonReturn
    if let monitor { NSEvent.removeMonitor(monitor) }
    isConfirmingDisconnect = false
    guard approved else { showConnectionResult(); return }
    Task { await disconnect(display); showConnectionResult() }
  }

  func showConnectionResult() {
    if let window = panelWindow, window.isVisible {
      window.makeKeyAndOrderFront(nil)
      return
    }
    guard let button = statusItem?.button, let popover, !popover.isShown else { return }
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
  }

  func restoreConnectionsForQuit() async -> Bool {
    guard !isLoading, !isRestoringConnections else { return false }
    isRestoringConnections = true
    defer { isRestoringConnections = false }
    do { connectionTopology = try await displayDiscovery.discoverDisplays() }
    catch { return false }
    refreshDisconnectedDisplays()
    guard connectionRecordError == nil else { return false }
    let targets = disconnectedDisplays.filter { record in
      record.requiresRediscovery != true || connectionTopology.contains { $0.stableID == record.stableID }
    }
    for record in targets {
      guard recoveryGuidance(for: record) == nil else { quitRecoveryFailed = true; return false }
      await reconnect(record)
      guard connectionNotice == nil else { quitRecoveryFailed = true; return false }
    }
    refreshDisconnectedDisplays()
    let remaining = disconnectedDisplays.filter { record in
      record.requiresRediscovery != true || connectionTopology.contains { $0.stableID == record.stableID }
    }
    let success = connectionRecordError == nil && remaining.isEmpty
    quitRecoveryFailed = !success
    return success
  }

  // MARK: - Internals

  private static func selector(for display: DisplayDescriptor) -> DisplaySelector {
    if let stableID = display.stableID, !stableID.isEmpty {
      return .stableID(stableID)
    }
    return .runtimeID(display.runtimeID)
  }

  /// The single path every connection change takes.
  ///
  /// The rescan afterwards is part of the act rather than a follow-up the caller
  /// could forget: a disconnect moves windows and can change the remaining
  /// displays' resolution, so the popover's own picture of the topology is stale
  /// the moment the call succeeds — and a stale list is what makes a reconnect
  /// button disappear exactly when the user needs it.
  private func applyConnection(
    _ state: DisplayConnectionState,
    selector: DisplaySelector,
    displayName: String,
    targetKey: String
  ) async {
    guard !isChangingConnection else { return }
    isChangingConnection = true
    connectionTargetKey = targetKey
    connectionNotice = nil
    defer { isChangingConnection = false; connectionTargetKey = nil }

    do {
      let controller = try connectionControllerFactory()
      let result = try await controller.setState(state, for: selector)
      guard result.wasVerified, result.observedState == state else {
        throw DisplayDJError(code: .verificationFailed, message: "连接结果未确认")
      }
      connectionNotice = nil
    } catch {
      connectionNotice = DisplayConnectionNoticePresenter.notice(
        for: error,
        intent: state,
        displayName: displayName,
        targetKey: targetKey
      )
    }

    await scanAndRefresh()
  }
}
