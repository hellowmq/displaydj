/// Why a reading is being taken, and therefore whether a closed popover should stop it.
///
/// `popoverIsVisible` was answering two different questions at once. "Should the routine
/// refresh keep running?" — no, nobody is looking at the cards, and unattended DDC traffic is
/// exactly what the polling rules exist to stop. But also "is anyone asking for a reading at
/// all?" — and that one it gets wrong, because the brightness hotkeys are deliberately usable
/// while the popover is closed. A keypress is somebody asking.
///
/// Split out as a plain value for the same reason `ReadPass` and `RefreshScope` were: the
/// decision can then be asserted without a running `NSStatusItem`, which no test can create.
enum ReadTrigger: Equatable {
  /// Filling in what the popover is showing: the cards' readings and their `±` buttons.
  ///
  /// The cards are the only consumer, so with the popover closed the result has nowhere to
  /// go and the read must not happen.
  case popoverContent

  /// Something the user just did, whose result is consumed outside the popover.
  ///
  /// The hotkeys are the case this exists for. They apply a *relative* step, so they need a
  /// starting point, and the reading also feeds the menu bar number — neither of which is a
  /// card. Refusing the read because the popover happens to be closed made the shortcut the
  /// user explicitly opted into do nothing at all.
  case userRequest

  /// Whether a read for this reason may proceed with the popover in the given state.
  ///
  /// Only the trigger decides. A user request is never refused: it is one-shot, it happened
  /// because of a deliberate action, and there is no timer behind it that could turn it into
  /// the background polling this gate was put here to prevent.
  func allowsRead(popoverIsVisible: Bool) -> Bool {
    switch self {
    case .popoverContent:
      return popoverIsVisible
    case .userRequest:
      return true
    }
  }
}
