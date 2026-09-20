/// Whether a hardware read is in flight, and *which* read owns that state.
///
/// A read is superseded by cancelling it and starting another, but cancellation in Swift is
/// cooperative: the cancelled task keeps running until its next suspension point resumes and
/// unwinds, so its cleanup executes *after* its replacement has already started. With a bare
/// boolean the departing read cleared a flag that no longer described it, leaving the app
/// claiming to be idle while a read was still on the hardware lane. The polling timer's
/// mutual-exclusion guard then waved a fresh pass through onto that same lane, which is the
/// read/write contention the polling rules exist to prevent, and the progress spinner vanished
/// mid-read while the refresh and retry buttons re-enabled themselves.
///
/// Handing out a token and accepting cleanup only from its current holder turns "am I still the
/// one reading?" into a question the type answers, rather than an assumption every call site
/// makes on its own. Split out as plain values so it can be tested without a running status item.
struct ReadActivity: Equatable {
  /// The last token handed out. Monotonic so a token is never reused, and a stale holder can
  /// therefore never be mistaken for the current one.
  private var lastToken: UInt64 = 0
  /// The token of the read currently in flight, or `nil` when the lane is idle.
  private var owner: UInt64?

  /// Whether any read is currently in flight.
  var isReading: Bool {
    owner != nil
  }

  /// Marks a read as started and returns the token identifying it.
  ///
  /// Taking over from an already-running read is deliberately allowed: the caller has just
  /// cancelled its predecessor, and the new read is the one that now describes the lane.
  mutating func begin() -> UInt64 {
    lastToken &+= 1
    owner = lastToken
    return lastToken
  }

  /// Marks a read as finished, but only when it is still the current one.
  ///
  /// A superseded read calling this is a no-op by design. Letting it through would announce an
  /// idle lane while its replacement is still reading, which is exactly the false "not busy"
  /// window that let polling and a user-initiated read overlap.
  mutating func end(_ token: UInt64) {
    guard owner == token else { return }
    owner = nil
  }
}
