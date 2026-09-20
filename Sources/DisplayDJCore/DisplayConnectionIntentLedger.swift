import Foundation

/// Remembers which displays this tool is changing on purpose.
///
/// Disabling a display emits the same reconfiguration event as pulling its
/// cable: the window server cannot tell the two apart. Without this ledger, the
/// event produced by a disconnect would be read as a physical unplug and would
/// immediately release the disable that had just been applied — and discard the
/// record needed to undo it.
///
/// The shared ledger is backed by a file rather than by memory alone. The menu
/// bar app and a one-shot CLI invocation are separate processes, so an intent
/// held in one is invisible to the other: the app's watcher would see the
/// removal the CLI caused, find no intent of its own, and delete the record the
/// CLI had just written. Sharing the ledger is what makes "the app is running"
/// and "the CLI disconnected a display" composable instead of destructive.
public final class DisplayConnectionIntentLedger: @unchecked Sendable {
  /// Shared because the controller that applies a change and the watcher that
  /// reacts to topology events are built separately and must agree on it —
  /// including across processes, which is why it is file-backed.
  public static let shared = DisplayConnectionIntentLedger(
    store: FileDisplayConnectionIntentStore()
  )

  private let lock = NSLock()
  private let store: (any DisplayConnectionIntentStoring)?
  private let graceInterval: TimeInterval
  private let now: @Sendable () -> Date
  private var lastIntentAt: [UInt32: Date] = [:]

  /// - Parameter store: Where the intent is shared with other processes. `nil`
  ///   keeps it in this process only, which is what tests and one-shot callers
  ///   that never run a watcher want.
  public init(
    store: (any DisplayConnectionIntentStoring)? = nil,
    graceInterval: TimeInterval = 3,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.store = store
    self.graceInterval = graceInterval
    self.now = now
  }

  /// Records that this tool is about to change `runtimeID`.
  public func noteIntent(runtimeID: UInt32) {
    let moment = now()

    lock.lock()
    lastIntentAt[runtimeID] = moment
    lock.unlock()

    guard let store else { return }

    // Read-modify-write rather than a blind overwrite: another process may have
    // announced an intent for a different display moments ago, and clobbering
    // the file would silently withdraw it.
    var shared = (try? store.loadIntents()) ?? [:]
    shared[runtimeID] = moment
    let stillLive = shared.filter { moment.timeIntervalSince($0.value) < graceInterval }
    _ = try? store.saveIntents(stillLive)
  }

  /// Whether a change to `runtimeID` should be read as this tool's own doing.
  ///
  /// The window is bounded rather than open-ended: an intent that is never
  /// followed by an event — a rejected transaction, say — must not suppress
  /// genuine physical changes for the rest of the session.
  public func isSuppressed(runtimeID: UInt32) -> Bool {
    let moment = now()

    lock.lock()
    let own = lastIntentAt[runtimeID]
    lock.unlock()

    if let own, moment.timeIntervalSince(own) < graceInterval {
      return true
    }

    guard let store else { return false }
    guard let shared = try? store.loadIntents(), let theirs = shared[runtimeID] else {
      return false
    }
    guard moment.timeIntervalSince(theirs) < graceInterval else { return false }

    // Adopted so a later check in this process does not have to touch the disk
    // again, and so a purge of the file cannot retract an intent already seen.
    lock.lock()
    lastIntentAt[runtimeID] = theirs
    lock.unlock()

    return true
  }
}
