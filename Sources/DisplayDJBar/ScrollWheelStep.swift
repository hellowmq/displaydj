import Foundation

/// How far one scroll event moves the brightness.
///
/// A wheel is not a button: one gesture emits dozens of events, and the magnitude each one
/// reports depends on the device — a mouse wheel reports whole notches, a trackpad reports
/// fractions that decay through the inertial tail. Turning that stream into a step is a
/// decision rather than an arithmetic, so it is made here where it can be tested without an
/// `NSEvent` and without a trackpad.
enum ScrollWheelStep {
  /// What a plain scroll applies. Small enough to feel continuous, large enough that a
  /// nudge is visible on the panel.
  static let fineDelta = 2
  /// What a scroll applies while Option is held, for crossing the range in a few notches.
  static let coarseDelta = 10
  /// Movements below this are noise. A trackpad keeps emitting sub-pixel deltas long after
  /// the fingers have lifted, and acting on those would keep the display busy with changes
  /// the user stopped asking for.
  static let threshold = 0.5

  /// Up brightens, down dims.
  ///
  /// The sign is fixed here rather than taken from the event's own `isDirectionInverted`
  /// preference: that setting describes how content should move under the fingers, and a
  /// brightness bar is not content. Every other menu bar brightness tool scrolls up to
  /// brighten, and the wheel is the one control with no thumb to look at for confirmation.
  static func step(deltaY: Double, optionHeld: Bool) -> Int {
    guard deltaY.isFinite, abs(deltaY) >= threshold else { return 0 }
    let magnitude = optionHeld ? coarseDelta : fineDelta
    return deltaY > 0 ? magnitude : -magnitude
  }
}
