import CoreGraphics

/// The geometry of the hand-drawn brightness track, named.
///
/// These numbers used to be literals scattered through `BrightnessSlider`'s body. They are the
/// numbers R2 turns on: the painted bar was 5pt — thin enough to read as a progress indicator
/// while the six `±` buttons beneath it read as *the* control — and the row the pointer actually
/// hits was whatever height was left over after those buttons were placed.
///
/// Named rather than inlined so the criteria can be stated as tests instead of as comments:
/// the bar has to be visibly thicker than what it replaced, the thumb has to fit in the row it
/// is drawn in, and the focus ring has to fit too, or it is clipped at the exact moment the
/// keyboard user needs to see it.
enum BrightnessSliderMetrics {
  /// Visual thickness of the track.
  ///
  /// Chosen to read as a control rather than as a readout: it is more than twice the 5pt it
  /// replaced, and within sight of the thumb's diameter rather than a fifth of it.
  static let trackHeight: CGFloat = 13

  /// Diameter of the white knob.
  static let thumbSize: CGFloat = 22

  /// Height of the row, which is also the pointer's target.
  ///
  /// Only a third of this is painted. The point of the surplus is that a click that lands
  /// anywhere near the bar — including on the padding above and below it, which is where a
  /// pointer aimed at a 13pt bar actually goes — still belongs to the slider.
  static let hitHeight: CGFloat = 44

  /// Room the keyboard focus ring adds around the bar.
  static let focusRingInset: CGFloat = 16

  /// What the focus ring needs, so it can be checked against `hitHeight`.
  static var focusRingHeight: CGFloat { trackHeight + focusRingInset }
}
