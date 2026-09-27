import Foundation

/// Whether a display receives a signal from the window server.
public enum DisplayConnectionState: String, Codable, CaseIterable, Sendable {
  case connected
  case disconnected
}

/// The outcome of one connect or disconnect request.
///
/// `observedState` comes from a fresh discovery pass rather than from the
/// requested value, and `wasVerified` is true only when the two agree.
public struct DisplayConnectionOutcome: Codable, Equatable, Sendable {
  public let display: DisplayDescriptor
  public let requestedState: DisplayConnectionState
  public let observedState: DisplayConnectionState
  public let wasVerified: Bool

  public init(
    display: DisplayDescriptor,
    requestedState: DisplayConnectionState,
    observedState: DisplayConnectionState,
    wasVerified: Bool
  ) {
    self.display = display
    self.requestedState = requestedState
    self.observedState = observedState
    self.wasVerified = wasVerified
  }
}

/// The rules that decide whether a connection change may be applied at all.
///
/// These live apart from the controller because they are the reason a bad
/// request never reaches the window server: the failure mode here is a display
/// that stops showing anything, so a refusal is always cheaper than a mistake.
public struct DisplayConnectionSafety: Sendable {
  public init() {}

  /// Rejects selectors that can match more than one display.
  ///
  /// Disconnecting several displays at once is exactly how a session ends up
  /// with nothing on screen, so multi-display selectors are refused outright.
  func requireSingleTarget(_ selector: DisplaySelector) throws {
    switch selector {
    case .all, .builtIn, .external:
      throw DisplayDJError(
        code: .invalidSelector,
        message: """
          Select one display at a time. Use a stable ID or runtime:<id> from \
          'displaydj list'.
          """,
        operation: .write,
        displayID: SelectorDescription.text(selector),
        details: [
          "phase": "safety-guard",
          "reason": "multi-display-selector",
        ]
      )
    case .runtimeID, .stableID:
      return
    }
  }

  /// Rejects a disconnect that would alter a mirror set or empty the desktop.
  func requireSafeDisconnect(
    of display: DisplayDescriptor,
    selector: DisplaySelector,
    onlineCount: Int
  ) throws {
    guard !display.isMirrored else {
      throw DisplayDJError(
        code: .unsupported,
        message: """
          '\(display.name)' is part of a mirror set. Disconnecting it would \
          change the mirror set rather than stop output to one display.
          """,
        operation: .write,
        displayID: SelectorDescription.text(selector),
        details: [
          "phase": "safety-guard",
          "reason": "mirrored-display",
          "runtimeID": String(display.runtimeID),
        ]
      )
    }

    guard onlineCount > 1 else {
      throw DisplayDJError(
        code: .conflict,
        message: """
          Refusing to disconnect '\(display.name)': it is the only online \
          display, and disconnecting it would leave nothing to see.
          """,
        operation: .write,
        displayID: SelectorDescription.text(selector),
        details: [
          "phase": "safety-guard",
          "reason": "last-online-display",
          "onlineDisplayCount": String(onlineCount),
        ]
      )
    }
  }
}

/// Connects and disconnects individual displays at the window server level.
///
/// Disconnecting removes the display from the macOS layout entirely and stops
/// the window server from rendering to it. That is a different effect from
/// dimming a panel or putting it to sleep over DDC: the desktop space
/// disappears and its windows move to a display that is still online.
public struct DisplayConnectionController: Sendable {
  private let discovery: any DisplayDiscovering
  private let transaction: any DisplayConfigurationTransactionApplying
  private let store: any DisplayConnectionRecordStoring
  private let selectorResolver: DisplaySelectorResolver
  private let safety: DisplayConnectionSafety
  private let ledger: DisplayConnectionIntentLedger
  private let verificationAttempts: Int
  private let verificationDelay: Duration

  public init(
    discovery: any DisplayDiscovering,
    transaction: any DisplayConfigurationTransactionApplying,
    store: any DisplayConnectionRecordStoring = NoOpDisplayConnectionRecordStore(),
    selectorResolver: DisplaySelectorResolver = DisplaySelectorResolver(),
    safety: DisplayConnectionSafety = DisplayConnectionSafety(),
    ledger: DisplayConnectionIntentLedger = .shared,
    verificationAttempts: Int = 25,
    verificationDelay: Duration = .milliseconds(200)
  ) {
    self.discovery = discovery
    self.transaction = transaction
    self.store = store
    self.selectorResolver = selectorResolver
    self.safety = safety
    self.ledger = ledger
    self.verificationAttempts = max(1, verificationAttempts)
    self.verificationDelay = verificationDelay
  }

  /// The production controller, using live discovery and the private entry point.
  public static func live(
    store: any DisplayConnectionRecordStoring = FileDisplayConnectionRecordStore()
  ) throws -> DisplayConnectionController {
    DisplayConnectionController(
      discovery: CoreGraphicsDisplayDiscovery(),
      transaction: try CGSConnectionTransaction(
        resolver: ProcessDisplayConnectionSymbolResolver()
      ),
      store: store
    )
  }

  public func setState(
    _ state: DisplayConnectionState,
    for selector: DisplaySelector
  ) async throws -> DisplayConnectionOutcome {
    switch state {
    case .disconnected:
      return try await disconnect(selector)
    case .connected:
      return try await connect(selector)
    }
  }

  // MARK: - Disconnect

  private func disconnect(
    _ selector: DisplaySelector
  ) async throws -> DisplayConnectionOutcome {
    try safety.requireSingleTarget(selector)
    let displays = try await discovery.discoverDisplays()

    guard let online = try onlineMatch(for: selector, among: displays) else {
      throw Self.notFound(selector)
    }

    try safety.requireSafeDisconnect(
      of: online,
      selector: selector,
      onlineCount: displays.count
    )

    // Save recovery identity before touching the desktop. A transaction can
    // mutate the display and still fail or publish topology late; the record
    // must survive that ambiguous result so a later connect can find it.
    try remember(online)
    // Announced before the call: the reconfiguration it emits lands on another
    // thread, and may arrive while this call is still running.
    ledger.noteIntent(runtimeID: online.runtimeID)
    try transaction.setEnabled(false, forRuntimeID: online.runtimeID)
    try await requireAbsent(online.runtimeID, selector: selector)

    return DisplayConnectionOutcome(
      display: online,
      requestedState: .disconnected,
      observedState: .disconnected,
      wasVerified: true
    )
  }

  // MARK: - Connect

  private func connect(
    _ selector: DisplaySelector
  ) async throws -> DisplayConnectionOutcome {
    try safety.requireSingleTarget(selector)
    let displays = try await discovery.discoverDisplays()

    if let online = try onlineMatch(for: selector, among: displays) {
      // A previous connect can complete after its caller timed out. A retry
      // must clear the saved disconnect intent, not leave a stale record.
      try forget(runtimeID: online.runtimeID, stableID: online.stableID)
      return DisplayConnectionOutcome(
        display: online,
        requestedState: .connected,
        observedState: .connected,
        wasVerified: true
      )
    }

    let runtimeID = try offlineRuntimeID(for: selector)
    ledger.noteIntent(runtimeID: runtimeID)
    try transaction.setEnabled(true, forRuntimeID: runtimeID)
    let restored = try await requirePresent(runtimeID, selector: selector)

    try forget(runtimeID: runtimeID, stableID: restored.stableID)

    return DisplayConnectionOutcome(
      display: restored,
      requestedState: .connected,
      observedState: .connected,
      wasVerified: true
    )
  }

  // MARK: - Verification

  private func requireAbsent(
    _ runtimeID: UInt32,
    selector: DisplaySelector
  ) async throws {
    for attempt in 0..<verificationAttempts {
      let after = try await discovery.discoverDisplays()
      if !after.contains(where: { $0.runtimeID == runtimeID }) { return }
      if attempt + 1 < verificationAttempts { try await Task.sleep(for: verificationDelay) }
    }
    throw DisplayDJError(
      code: .verificationFailed,
      message: "The display remained online within the verification window; reconnect record retained.",
      operation: .write,
      displayID: SelectorDescription.text(selector),
      details: [
        "phase": "verification",
        "runtimeID": String(runtimeID),
        "attempts": String(verificationAttempts),
      ]
    )
  }

  private func requirePresent(
    _ runtimeID: UInt32,
    selector: DisplaySelector
  ) async throws -> DisplayDescriptor {
    let expectedStableID: String?
    if case .stableID(let value) = selector {
      expectedStableID = try DisplayStableSelector.normalizeInput(value).lowercased()
    } else {
      expectedStableID = nil
    }
    // CGSCompleteDisplayConfiguration can return before CoreGraphics has
    // published the new online topology. Bound the wait and re-enumerate;
    // accepting the same runtime ID alone could select a different display.
    for attempt in 0..<verificationAttempts {
      let after = try await discovery.discoverDisplays()
      if let restored = after.first(where: { display in
        if let expectedStableID {
          return display.stableID.flatMap(DisplayStableSelector.normalizeDescriptorID) == expectedStableID
        }
        return display.runtimeID == runtimeID
      }) {
        return restored
      }
      if attempt + 1 < verificationAttempts { try await Task.sleep(for: verificationDelay) }
    }
    throw DisplayDJError(
      code: .verificationFailed,
      message: "The display did not come back online within the verification window.",
      operation: .write,
      displayID: SelectorDescription.text(selector),
      details: [
        "phase": "verification",
        "runtimeID": String(runtimeID),
        "attempts": String(verificationAttempts),
      ]
    )
  }

  // MARK: - Lookup

  private func onlineMatch(
    for selector: DisplaySelector,
    among displays: [DisplayDescriptor]
  ) throws -> DisplayDescriptor? {
    let matches = try? selectorResolver.resolve(selector, among: displays)
    return matches?.first
  }

  /// Recovers the runtime ID of a display that is no longer online.
  private func offlineRuntimeID(for selector: DisplaySelector) throws -> UInt32 {
    switch selector {
    case .runtimeID(let runtimeID):
      return runtimeID

    case .stableID(let stableID):
      let normalized =
        try DisplayStableSelector.normalizeInput(stableID).lowercased()
      let records = try store.loadRecords()

      guard
        let record = records.first(where: {
          $0.stableID.flatMap(DisplayStableSelector.normalizeDescriptorID) == normalized
        })
      else {
        throw DisplayDJError(
          code: .displayNotFound,
          message: """
            No online display matched '\(stableID)' and no saved disconnect \
            record points back to it. Reconnect with runtime:<id>.
            """,
          operation: .write,
          displayID: stableID,
          details: [
            "phase": "offline-resolution",
            "reason": "no-saved-record",
          ]
        )
      }

      return record.runtimeID

    case .all, .builtIn, .external:
      throw DisplayDJError(
        code: .invalidSelector,
        message: "Select one display at a time.",
        operation: .write,
        displayID: SelectorDescription.text(selector)
      )
    }
  }

  // MARK: - Records

  private func remember(_ display: DisplayDescriptor) throws {
    var records = try store.loadRecords()
    records.removeAll { $0.runtimeID == display.runtimeID }
    records.append(
      DisplayConnectionRecord(
        runtimeID: display.runtimeID,
        stableID: display.stableID,
        name: display.name
      )
    )

    do {
      try store.saveRecords(records)
    } catch {
      throw DisplayDJError(
        code: .internalFailure,
        message: """
          The reconnect record for '\(display.name)' could not be saved, so \
          the display was not disconnected.
          """,
        operation: .write,
        displayID: display.stableID ?? "runtime:\(display.runtimeID)",
        details: [
          "phase": "record-save",
          "runtimeID": String(display.runtimeID),
        ]
      )
    }
  }

  private func forget(runtimeID: UInt32, stableID: String?) throws {
    var records = try store.loadRecords()
    let normalized = stableID.flatMap(DisplayStableSelector.normalizeDescriptorID)
    records.removeAll {
      $0.runtimeID == runtimeID ||
        (normalized != nil && $0.stableID.flatMap(DisplayStableSelector.normalizeDescriptorID) == normalized)
    }
    try store.saveRecords(records)
  }

  private static func notFound(_ selector: DisplaySelector) -> DisplayDJError {
    DisplayDJError(
      code: .displayNotFound,
      message: "No online display matched '\(SelectorDescription.text(selector))'.",
      operation: .write,
      displayID: SelectorDescription.text(selector)
    )
  }
}

private enum SelectorDescription {
  static func text(_ selector: DisplaySelector) -> String {
    switch selector {
    case .all:
      return "all"
    case .builtIn:
      return "built-in"
    case .external:
      return "external"
    case .runtimeID(let id):
      return "runtime:\(id)"
    case .stableID(let id):
      return id
    }
  }
}
