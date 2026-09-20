import DisplayDJCore
import Foundation

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
    let records = (try? connectionStore.loadRecords()) ?? []
    let online = Set(displays.map(\.runtimeID))
    disconnectedDisplays = DisplayConnectionList.resolve(
      records: records,
      onlineRuntimeIDs: online
    )
  }

  /// Whether the given display can be disconnected from here.
  func connectionAvailability(
    for display: DisplayDescriptor
  ) -> DisplayConnectionAvailability {
    DisplayConnectionAvailabilityResolver.resolve(
      isSupported: connectionSupported,
      onlineCount: onlineDisplayCount,
      isMirrored: display.isMirrored,
      isBuiltIn: display.isBuiltIn
    )
  }

  /// Stops output to a display that is currently online.
  func disconnect(_ display: DisplayDescriptor) async {
    await applyConnection(
      .disconnected,
      selector: Self.selector(for: display),
      displayName: display.name,
      targetKey: display.selectionKey
    )
  }

  /// Restores output to a display this tool disconnected.
  ///
  /// Addressed by runtime ID rather than by stable ID: a disconnected display is
  /// absent from the topology, so its stable ID no longer resolves to anything
  /// and the saved record's runtime ID is the only address that reaches it.
  func reconnect(_ record: DisplayConnectionRecord) async {
    await applyConnection(
      .connected,
      selector: .runtimeID(record.runtimeID),
      displayName: record.name,
      targetKey: DisplayConnectionList.key(for: record.runtimeID)
    )
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
    defer { isChangingConnection = false }

    do {
      let controller = try connectionControllerFactory()
      _ = try await controller.setState(state, for: selector)
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
