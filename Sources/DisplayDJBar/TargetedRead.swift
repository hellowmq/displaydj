/// Whether a read aimed at one named display may go ahead.
///
/// A targeted read and the polling pass are not asking the same question, and they were
/// sharing one answer. The pass asks *"should I keep walking the display list?"*, and it
/// abandons the whole walk the moment the user starts writing anything, because the walk holds
/// the shared DDC lane for as long as it lasts — one read per attached monitor, hundreds of
/// milliseconds each. A targeted read asks something far narrower: *"may I read this one
/// monitor, right now?"*
///
/// Answering the narrow question with the broad flag is the defect this type exists to undo.
/// `hasPending` is true whenever *any* card has a queued value, and a drag queues one on every
/// frame of the gesture — so for as long as the user steered one display, every read aimed at
/// every *other* display was refused. Selecting a second card left it showing a placeholder,
/// and the retry button on a card whose read had failed did nothing whatsoever.
///
/// Every other consumer of "is this reading still wanted?" is already per display:
/// `ReadPass.step` takes `hasPendingIntent` for the display it is about to read,
/// `applyReadValue` refuses to overwrite a newer intent for that same display, and the failure
/// path discards a stale reading only for the display that failed. This entry point was the
/// one place that asked globally, which is why a neighbour's activity could speak for it.
///
/// Split out as a plain value for the same reason `ReadPass`, `ReadTrigger` and `SliderStep`
/// were: the decision can then be asserted without a running status item.
enum TargetedRead: Equatable {
  /// Read it.
  case proceed
  /// A write is on the wire. It owns the shared DDC lane whichever display it is aimed at,
  /// so this read waits — the one condition that legitimately answers for every display.
  case laneBusy
  /// The user has a newer value queued for *this* display, so anything the hardware reports
  /// is already out of date. Resolves itself as soon as the write lands.
  case steering
  /// This display has no stable identity and cannot be addressed at all.
  case unaddressable

  /// Resolves a targeted read request.
  ///
  /// `targetHasPendingIntent` is deliberately about the target and nothing else. Passing a
  /// global "somebody has queued something" flag here is precisely how a neighbour's drag came
  /// to silence an unrelated monitor.
  static func decision(
    stableID: String,
    writeInFlight: Bool,
    targetHasPendingIntent: Bool
  ) -> TargetedRead {
    // Checked first because it is the only permanent condition. The other two clear
    // themselves within a moment, and reporting a display that can never be addressed as
    // merely "busy" would hide it behind a state the caller expects to pass.
    guard !stableID.isEmpty else { return .unaddressable }
    // Global on purpose. A write in flight is not a statement about any particular monitor;
    // it is a statement about the wire both of them share.
    if writeInFlight { return .laneBusy }
    if targetHasPendingIntent { return .steering }
    return .proceed
  }
}
