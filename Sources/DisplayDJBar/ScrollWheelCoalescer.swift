import Foundation

/// Accumulates scroll steps so one gesture becomes one write.
///
/// The wheel emits events far faster than DDC can be driven — a single flick is dozens of
/// them — and each event used to start its own write, so the hardware was asked for every
/// intermediate value the pointer had already swept past. A step is only ever a number to
/// add, so they sum without loss: the value finally sent is identical, and it is sent once.
///
/// Deliberately not a scheduler. When to stop waiting belongs to whoever can see the clock;
/// this holds the arithmetic so that decision stays testable.
struct ScrollWheelCoalescer {
  private(set) var pending = 0

  mutating func add(_ step: Int) {
    pending += step
  }

  /// The accumulated step, or `nil` when nothing is owed — including when the steps have
  /// cancelled each other out, which is a scroll down and back up rather than a no-op.
  mutating func take() -> Int? {
    guard pending != 0 else { return nil }
    defer { pending = 0 }
    return pending
  }
}
