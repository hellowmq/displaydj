import CoreGraphics

/// Whether the pointer is over the menu bar item.
///
/// A global monitor sees every wheel event on the system, so "is this one ours" is decided
/// by geometry and nothing else. Kept out of the monitor so the rule is testable without
/// installing one, which is also the only way to test it at all: whether an event arrives
/// is the part that has to be confirmed on real hardware.
enum ScrollWheelHitTest {
  /// A couple of points of slack. The frame is the button's, and a wheel aimed at its very
  /// edge still belongs to it — the alternative is a dead margin the user cannot see.
  static let padding: CGFloat = 2

  static func contains(_ point: CGPoint, in frame: CGRect) -> Bool {
    // A null or empty frame means the item has not been laid out, and a hit test against
    // one must not answer yes: that is the state in which every wheel on the system would
    // be captured.
    guard !frame.isNull, !frame.isEmpty else { return false }
    return frame.insetBy(dx: -padding, dy: -padding).contains(point)
  }
}
