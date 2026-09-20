import Foundation

/// The result of releasing a disable because a display was physically disturbed.
///
/// `wasVerified` is reported rather than assumed, so a release that could not be
/// confirmed is never presented as one that took effect.
public struct DisplayConnectionAutoReleaseOutcome: Sendable, Equatable {
  public enum Action: String, Sendable, Equatable {
    /// A display this tool had disabled was unplugged, so its record is gone.
    case clearedOnUnplug
    /// A display came back inactive, so output to it was turned back on.
    case restoredOnReconnect
  }

  public let runtimeID: UInt32
  public let action: Action
  public let displayName: String?
  public let wasVerified: Bool

  public init(
    runtimeID: UInt32,
    action: Action,
    displayName: String?,
    wasVerified: Bool
  ) {
    self.runtimeID = runtimeID
    self.action = action
    self.displayName = displayName
    self.wasVerified = wasVerified
  }
}

/// Releases a disable when the physical connection behind it changes.
///
/// A disable is invisible: the display is simply absent from the layout, and
/// nothing on screen says why. Left alone across a replug, that absence becomes
/// a black screen the user has no way to attribute — the cable is in, the
/// monitor has power, and the tool that stopped the signal is the one part
/// nobody thinks to suspect. Every rule here trades a sticky disable for a
/// display that comes back on, because the second failure is self-explanatory
/// and the first is not.
public struct DisplayConnectionAutoRelease: Sendable {
  private let transaction: any DisplayConfigurationTransactionApplying
  private let store: any DisplayConnectionRecordStoring
  private let runtimeStatus: any DisplayRuntimeStatusQuerying
  private let ledger: DisplayConnectionIntentLedger

  public init(
    transaction: any DisplayConfigurationTransactionApplying,
    store: any DisplayConnectionRecordStoring,
    runtimeStatus: any DisplayRuntimeStatusQuerying = CoreGraphicsDisplayRuntimeStatus(),
    ledger: DisplayConnectionIntentLedger = .shared
  ) {
    self.transaction = transaction
    self.store = store
    self.runtimeStatus = runtimeStatus
    self.ledger = ledger
  }

  /// The production watcher, using the private entry point.
  ///
  /// - Throws: When the entry point is missing. An unavailable symbol is a hard
  ///   failure: silently not watching would leave every disable unguarded while
  ///   looking exactly like one that is being watched.
  public static func live(
    store: any DisplayConnectionRecordStoring = FileDisplayConnectionRecordStore(),
    runtimeStatus: any DisplayRuntimeStatusQuerying = CoreGraphicsDisplayRuntimeStatus(),
    ledger: DisplayConnectionIntentLedger = .shared
  ) throws -> DisplayConnectionAutoRelease {
    DisplayConnectionAutoRelease(
      transaction: try CGSConnectionTransaction(
        resolver: ProcessDisplayConnectionSymbolResolver()
      ),
      store: store,
      runtimeStatus: runtimeStatus,
      ledger: ledger
    )
  }

  /// Reacts to one topology change.
  ///
  /// - Returns: `nil` when the change needs nothing from this tool, which is the
  ///   common case: most displays are plugged and unplugged while enabled.
  public func handle(
    _ change: DisplayTopologyChange
  ) throws -> DisplayConnectionAutoReleaseOutcome? {
    guard !ledger.isSuppressed(runtimeID: change.runtimeID) else { return nil }

    switch change.kind {
    case .removed:
      return try clearOnUnplug(change.runtimeID)
    case .added:
      return try restoreOnReconnect(change.runtimeID)
    }
  }

  // MARK: - Unplug

  /// Forgets a disabled display that has just been unplugged.
  ///
  /// Two reasons, both about a record outliving what it describes. The disable
  /// itself is moot once the cable is out, so keeping the record only preserves
  /// the ability to reconnect a display that is not there. Worse, runtime IDs
  /// are reassigned: a record left behind can later point at whichever display
  /// inherits that number, so a reconnect aimed at one monitor would drive
  /// another.
  private func clearOnUnplug(
    _ runtimeID: UInt32
  ) throws -> DisplayConnectionAutoReleaseOutcome? {
    var records = try store.loadRecords()

    guard let index = records.firstIndex(where: { $0.runtimeID == runtimeID }) else {
      return nil
    }

    let record = records.remove(at: index)
    try store.saveRecords(records)

    return DisplayConnectionAutoReleaseOutcome(
      runtimeID: runtimeID,
      action: .clearedOnUnplug,
      displayName: record.name,
      wasVerified: !runtimeStatus.isActive(runtimeID: runtimeID)
    )
  }

  // MARK: - Reconnect

  /// Turns output back on for a display that has just come back inactive.
  ///
  /// macOS can restore a display it had been told to stop driving while keeping
  /// it inactive, which is the one state that defeats the unplug rule above:
  /// the record is already gone, so nothing else will recognise the monitor.
  /// Restoring on arrival is what makes a replug mean "on" regardless of what
  /// the system remembered.
  private func restoreOnReconnect(
    _ runtimeID: UInt32
  ) throws -> DisplayConnectionAutoReleaseOutcome? {
    guard !runtimeStatus.isMirrored(runtimeID: runtimeID) else { return nil }
    guard !runtimeStatus.isActive(runtimeID: runtimeID) else { return nil }

    let records = try store.loadRecords()
    try transaction.setEnabled(true, forRuntimeID: runtimeID)

    let remaining = records.filter { $0.runtimeID != runtimeID }
    if remaining.count != records.count {
      try store.saveRecords(remaining)
    }

    return DisplayConnectionAutoReleaseOutcome(
      runtimeID: runtimeID,
      action: .restoredOnReconnect,
      displayName: records.first(where: { $0.runtimeID == runtimeID })?.name,
      wasVerified: runtimeStatus.isActive(runtimeID: runtimeID)
    )
  }
}
