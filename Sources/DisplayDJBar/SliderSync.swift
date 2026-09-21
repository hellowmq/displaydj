/// When the card's slider adopts the display's reading — including the very first time.
///
/// The card renders its slider from a `@State Double` initialised from the controller's
/// reading when available. `.onChange(of: displayedBrightness)` keeps it current afterward.
/// `onChange` is a *difference* channel: it fires when the value changes while the view is
/// alive, and it does not fire for the value that was already there when the view appeared.
/// So the slider had a rule for staying in step and no rule for starting in step.
///
/// That gap is not hypothetical, because the reading routinely predates the card:
///
/// * The popover is `.transient`. Closing it tears the SwiftUI content down, and reopening
///   builds fresh `DisplayCard`s while `brightnessByID` survives untouched. The card now
///   initialises its state from that reading; this appearance rule still covers a reading
///   that changes between construction and appearance.
/// * A hotkey pressed before the popover was ever opened runs `refreshSelectedDisplayOnDemand`,
///   which enumerates and reads. By the time the user opens the popover, the reading is already
///   in hand and the card is created after it.
///
/// Before the initialisation fix, the readout could show the real value while the track drew
/// 50 for its first frame. The appearance rule remains useful as a safety net; the initial
/// state now prevents the visual mismatch before that callback runs.
///
/// It cannot heal on its own while the popover is shut, and once open it heals only if the
/// hardware happens to report a *different* number — a display sitting at a stable brightness
/// never does.
///
/// The decision is expressed as a value, and both occasions resolve through it, for the same
/// reason `SliderTrack` merged drawing with stepping: "the reading arrived" and "the reading was
/// already here" are one question — *should the slider adopt this number?* — and answering it in
/// two places is how one of them came to be missing entirely.
enum SliderSync: Equatable {
  /// Take this value, and whether the change should be animated.
  case adopt(value: Double, animated: Bool)

  /// Leave the slider where it is.
  ///
  /// Deliberately not named `none`: as `SliderSync?` it would collide with `Optional.none` and
  /// silently swallow a branch, the same trap `SliderTrack.unknown`, `RefreshScope.nothing` and
  /// `SliderStep.unavailable` are already named around.
  case keep

  /// Why the card is asking.
  ///
  /// Carried rather than inferred, because the two occasions differ in exactly one respect and
  /// it is not one the reading can reveal: appearing at a value is not a change the user can
  /// perceive as motion, so animating it slides the thumb in from a position the display never
  /// held. A reading that arrives while the card is on screen *is* motion and should read as it.
  enum Occasion: Equatable {
    /// The card was just built and holds nothing but its `@State` default.
    case cardAppeared
    /// The displayed brightness changed while the card was on screen.
    case readingChanged
  }

  /// Resolves whether the slider should take the reading.
  ///
  /// A drag outranks everything: the finger is the authority on where the control sits, and
  /// letting a poll land underneath it would drag the thumb out from under the user. That is the
  /// same exclusion the original `onChange` guard made, kept here so both callers inherit it
  /// rather than each remembering it.
  static func resolve(reading: Int?, isDragging: Bool, occasion: Occasion) -> SliderSync {
    guard !isDragging else { return .keep }
    // No reading means there is nothing to adopt. The slider does not fall back to a default
    // here: `SliderTrack` already refuses to draw a position without a reading, so whatever the
    // `@State` happens to hold is never rendered in that state.
    guard let reading else { return .keep }
    return .adopt(
      value: Double(BrightnessAccessibility.clamp(reading)),
      animated: occasion == .readingChanged
    )
  }
}
