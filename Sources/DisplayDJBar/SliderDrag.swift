import Foundation

/// The brightness slider's value arithmetic, kept out of the view so it can be tested.
///
/// The control renders from one of two variables depending on a mode flag: `dragValue` while
/// a drag is in progress, `value` otherwise. Every mode flip therefore hands rendering to a
/// variable that the other mode was not maintaining, so the handover is only safe if the
/// incoming variable is brought up to date in the same step. Expressing the settled state as
/// a value makes that obligation explicit instead of leaving it to be remembered at each
/// call site — it was remembered on the keyboard path and forgotten on the drag path.
///
/// The `value` binding additionally has a second reader: the owning card renders its own
/// header from it and cannot see `dragValue` at all, which is private to the slider. So the
/// binding must stay current *throughout* a drag, not only once it ends. Both `track` and
/// `settle` therefore return the binding value alongside the number to publish, which is why
/// neither of them is a bare `Int`.
enum SliderDrag {

  /// The state the slider settles into when a drag ends.
  ///
  /// `value` is deliberately part of the result rather than left to the caller: releasing the
  /// finger returns rendering authority to the `value` binding, and if that binding still
  /// holds the number the drag started from, the fill and the thumb jump back to the start of
  /// the gesture while the readout and the hardware show where the user actually let go.
  /// Nothing corrects it afterwards, because the card only re-syncs the slider when the
  /// displayed brightness *changes*, and the continuous drag callback has already published
  /// this very value — so the contradiction is permanent, not a transient flicker.
  struct Settled: Equatable {
    /// What both `value` and `dragValue` must hold once the gesture is over.
    let value: Double
    /// What is sent to the hardware.
    let committed: Int
  }

  /// Resolves the end of a drag.
  ///
  /// The committed integer and the settled binding are derived from the same rounding, so the
  /// number on screen, the number spoken by VoiceOver and the number written to the display
  /// cannot disagree by a fraction.
  static func settle(dragValue: Double) -> Settled {
    let committed = BrightnessAccessibility.clamp(Int(dragValue.rounded()))
    return Settled(value: Double(committed), committed: committed)
  }

  /// The state the slider moves through while the finger is still down.
  ///
  /// `value` is part of the result for the same reason it is part of `Settled`: the binding is
  /// not merely the resting place the drag returns to, it is *also* read live by the owning
  /// card, which renders its header from the bound number during a drag. Leaving the binding
  /// untouched until the gesture ends froze that header at the value the drag started from
  /// while the track underneath it followed the finger.
  struct Tracked: Equatable {
    /// What both `value` and `dragValue` must hold while the drag continues.
    let value: Double
    /// What is published to the hardware for this movement.
    let published: Int
  }

  /// Resolves one movement within a drag.
  ///
  /// Shares its rounding with `settle`, so the last tracked position and the committed value
  /// agree and releasing the finger cannot nudge the number the user was watching.
  static func track(atX locationX: CGFloat, width: CGFloat) -> Tracked {
    let raw = value(atX: locationX, width: width)
    let published = BrightnessAccessibility.clamp(Int(raw.rounded()))
    return Tracked(value: Double(published), published: published)
  }

  /// Converts a horizontal touch position into a brightness percentage.
  ///
  /// The width is supplied by the layout rather than assumed, so the pixel the user pressed
  /// and the value that gets committed refer to the same track. A hard-coded width made the
  /// two disagree across the whole range and swallowed a dead zone at the right-hand end.
  static func value(atX locationX: CGFloat, width: CGFloat) -> Double {
    guard width > 0 else { return 0 }
    let ratio = max(0, min(1, locationX / width))
    return (Double(ratio) * 100).rounded()
  }
}
