/// When a multi-display read pass may take its next reading.
///
/// A pass walks every attached display in turn and each DDC read costs hundreds of
/// milliseconds, so the conditions that authorised the pass at its start routinely stop
/// holding partway through: the user closes the popover, or touches a card and supersedes it.
/// Checking only at the entrance let a dismissed popover keep reading hardware to the end of
/// the display list — precisely the polling the lifecycle rules forbid.
///
/// Split out as plain values so the decision can be tested without a running status item.
enum ReadPass {

  /// What the pass does with one display.
  ///
  /// The two non-reading outcomes are kept apart on purpose. Collapsing them into a single
  /// "skip" made the pass treat *"the user is steering this card, leave it alone"* and
  /// *"this monitor cannot be addressed at all"* as the same thing — but the first is a
  /// deliberate courtesy that needs no explanation, while the second is a permanent condition
  /// the user has to be told about, because that card's controls are disabled and nothing
  /// else on screen says why.
  enum Step: Equatable {
    /// Read this display.
    case read(stableID: String)
    /// Leave this display alone; the user is currently steering it.
    case steering
    /// This display has no stable identity, so it cannot be addressed safely.
    ///
    /// Deliberately not folded into `steering`: it is the one skip that owes the user a
    /// sentence.
    case unaddressable
  }

  /// Whether the pass as a whole should keep going before starting the next display.
  ///
  /// Every condition abandons the *remaining* displays rather than skipping one, because each
  /// means the pass as a whole has stopped being wanted: nobody is waiting for the answer, or
  /// the user has taken the wheel.
  ///
  /// `userIsWriting` is here rather than only on the way in because a write is a user
  /// operation and polling must stay mutually exclusive with those for as long as they last.
  /// The entrance already refused to start a pass while one was in flight, but the user
  /// typically starts steering *after* a pass has begun — that is the whole point of a
  /// two-second timer — so an entry-only test authorised a pass and then let it read the rest
  /// of the display list alongside the write it was supposed to be excluded from.
  static func shouldContinue(
    popoverIsVisible: Bool,
    isCancelled: Bool,
    userIsWriting: Bool
  ) -> Bool {
    popoverIsVisible && !isCancelled && !userIsWriting
  }

  /// What to do with one display in this step.
  ///
  /// Neither non-reading outcome abandons the displays after it: an unaddressable or actively
  /// steered monitor says nothing about its neighbours, which still need their readings.
  static func step(stableID: String?, hasPendingIntent: Bool) -> Step {
    guard let stableID, !stableID.isEmpty else { return .unaddressable }
    // Order matters: a display with no stable identity is unaddressable whatever the user is
    // doing, and reporting it as merely "being steered" would hide it behind a transient
    // state that clears itself.
    guard !hasPendingIntent else { return .steering }
    return .read(stableID: stableID)
  }
}
