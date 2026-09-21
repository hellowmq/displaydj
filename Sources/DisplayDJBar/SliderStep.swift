/// Whether the slider may apply a discrete step, and what it would step from.
///
/// The pointer and the keyboard are not asking the same thing of this control. A drag names an
/// absolute position on the track, so it needs nothing but a display it is allowed to address.
/// An arrow key or a VoiceOver increment names a *change*, and a change is meaningless without
/// a starting point — which is the one thing missing exactly when a read has failed.
///
/// The controller already keeps those two questions apart: `canControl` asks only whether the
/// display has a stable identity, `canAdjustRelatively` additionally requires a reading, and
/// the card's `±` buttons consult the second. The slider was given only the first, so its
/// keyboard path stepped from whatever number the control happened to be drawn at — a `@State`
/// that starts at 50 and is only ever synced from a reading that exists. With no reading it
/// stepped from a figure nothing had measured, and sent the result to the hardware.
///
/// Split out as a plain value for the same reason `SliderDrag` and `ReadTrigger` were: the
/// decision can then be asserted without instantiating a SwiftUI view.
enum SliderStep: Equatable {
  /// Apply the step, starting from this value.
  case apply(from: Int)
  /// Do not apply it: either the control is unusable, or nothing is known to step from.
  ///
  /// Deliberately not named `none`: as `SliderStep?` it would collide with `Optional.none`
  /// and silently swallow a branch in every `switch`.
  case unavailable

  /// Resolves a discrete step request.
  ///
  /// `currentValue` is optional on purpose, and that is the whole correction. A non-optional
  /// baseline is precisely how the fabricated one got in: every caller had to supply *some*
  /// number, so "no reading" had no representation and the drawn default stood in for it.
  ///
  /// Refusing is not a silent discard. The same absence makes the control announce its value
  /// as unknown, and the card disables the slider until a new reading succeeds.
  static func resolve(isEnabled: Bool, currentValue: Int?) -> SliderStep {
    guard isEnabled, let currentValue else { return .unavailable }
    return .apply(from: currentValue)
  }
}
