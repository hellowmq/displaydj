/// Keeps the user's latest brightness intent while a hardware write is in flight.
///
/// A DDC write takes hundreds of milliseconds. During that window the user can keep
/// dragging the slider, pressing the adjust buttons or picking a preset. Intermediate
/// values may be coalesced, but the *last* intent must never be dropped: it is applied
/// as soon as the in-flight write finishes.
struct BrightnessIntent: Equatable {
  let value: Int
  let displayStableID: String
}

/// A queue of pending intents, one slot **per display**.
///
/// Coalescing is deliberately scoped to a single monitor. Every card in the popover is
/// adjustable without being selected first, so the user can steer display B and then
/// display A within the same write window. A buffer with one shared slot would let A's
/// intent overwrite B's, and B would simply never move — the silent discard this type
/// exists to prevent, reintroduced across displays instead of across time.
///
/// Within one display, only the newest value survives: the intermediate frames of a drag
/// are worth dropping. Across displays, nothing is ever dropped.
struct BrightnessIntentBuffer {
  /// The intent currently being written to hardware.
  private(set) var active: BrightnessIntent?
  /// Newest not-yet-started value for each display, keyed by stable ID.
  private var pendingValues: [String: Int] = [:]
  /// Submission order of the displays in `pendingValues`, oldest first.
  ///
  /// Kept alongside the dictionary so draining is fair and deterministic: without it the
  /// order would follow the dictionary's hashing, and a display could in principle be
  /// starved while its neighbour is written repeatedly.
  private var pendingOrder: [String] = []

  /// Whether the display the in-flight write is aimed at has since been detached.
  ///
  /// A write cannot be recalled once it has been handed to Core, and its restoration
  /// semantics belong to Core alone — so the intent is left to finish. What must not happen
  /// is its *result* being filed: the display has no card left, so a reading or a banner
  /// recorded against it is invisible state that outlives the prune meant to remove it, and
  /// reappears on the card if the display is ever plugged back in.
  private(set) var isActiveOrphaned = false

  var hasPending: Bool {
    !pendingOrder.isEmpty
  }

  var isDraining: Bool {
    active != nil
  }

  // Deliberately absent: a `pending` peek that returned the oldest queued intent without
  // dequeuing it. Its last reader went away when draining moved to `beginNext()`, which
  // promotes and returns in one step precisely so no caller can look at an intent it has not
  // taken ownership of. A peek invites exactly that — read the head, decide something, then
  // drain it separately — with the queue free to change in between. `hasPending` answers the
  // only question the controller actually asks. Do not reintroduce it.

  /// Records the newest intent for its display, replacing that display's not-yet-started
  /// value while leaving every other display's queued intent untouched.
  mutating func submit(_ intent: BrightnessIntent) {
    if pendingValues.updateValue(intent.value, forKey: intent.displayStableID) == nil {
      pendingOrder.append(intent.displayStableID)
    }
  }

  /// Promotes the oldest pending intent to active and returns it, or `nil` when nothing
  /// is queued.
  mutating func beginNext() -> BrightnessIntent? {
    guard let displayStableID = pendingOrder.first,
      let value = pendingValues.removeValue(forKey: displayStableID)
    else { return nil }
    pendingOrder.removeFirst()
    let next = BrightnessIntent(value: value, displayStableID: displayStableID)
    active = next
    return next
  }

  mutating func finishActive() {
    active = nil
    isActiveOrphaned = false
  }

  /// Drops queued intents for displays that are no longer attached.
  ///
  /// A rescan already prunes the readings and the banners, but the intents were left behind —
  /// and an intent is the one piece of per-display state that *reinstates* the others. A
  /// value queued for a monitor that has since been unplugged would still be drained, and
  /// draining it writes a reading and possibly a failure back under a stable ID that has no
  /// card, so the prune undid itself moments after running. Worse, the drain re-enters the
  /// hardware path for a display the topology no longer contains, which is a write nobody
  /// can see the result of.
  ///
  /// The active intent is deliberately *not* cancelled. It has already been handed to Core,
  /// whose single-Set and restore-on-failure semantics own it from that point; interrupting
  /// it here could leave the panel holding a value the user never asked for. It is flagged
  /// instead, so its result can be discarded rather than filed against a departed display.
  mutating func prune(keeping liveIDs: Set<String>) {
    pendingValues = pendingValues.filter { liveIDs.contains($0.key) }
    pendingOrder = pendingOrder.filter { liveIDs.contains($0) }
    if let active {
      isActiveOrphaned = !liveIDs.contains(active.displayStableID)
    }
  }

  /// The most recent intent the user expressed for a display, newest first.
  func latestValue(for displayStableID: String) -> Int? {
    if let value = pendingValues[displayStableID] {
      return value
    }
    if let active, active.displayStableID == displayStableID {
      return active.value
    }
    return nil
  }
}
