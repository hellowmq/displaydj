import Foundation
import Testing

@testable import DisplayDJBar

@Suite("Slider drag settling")
struct SliderDragTests {

  // MARK: - Handing rendering back to the value binding

  /// The defect this guards: `onEnded` committed the released value to the hardware but left
  /// the `value` binding holding the number the drag started from. Because every rendered
  /// property switches from `dragValue` back to `value` the instant `isDragging` clears, the
  /// fill and the thumb jumped back to the start of the gesture while the readout and the
  /// display showed where the user actually let go.
  @Test("Settling reports the binding value, not only the committed number")
  func settlePublishesBindingValue() {
    let settled = SliderDrag.settle(dragValue: 73)
    #expect(settled.committed == 73)
    #expect(settled.value == 73)
  }

  /// The keyboard path already assigned both variables, so the two paths must agree; the
  /// settled value is what lets the drag path make the same assignment.
  @Test("The settled value and the committed value never disagree")
  func settledValueMatchesCommitted() {
    for raw in [0.0, 0.4, 12.5, 49.6, 50.0, 87.2, 99.5, 100.0] {
      let settled = SliderDrag.settle(dragValue: raw)
      #expect(settled.value == Double(settled.committed))
    }
  }

  @Test("A fractional drag position settles to a whole percentage")
  func settleRounds() {
    #expect(SliderDrag.settle(dragValue: 49.6).committed == 50)
    #expect(SliderDrag.settle(dragValue: 49.4).committed == 49)
  }

  /// A gesture can be dragged past either end of the track, and the value that reaches the
  /// hardware has to stay inside the representable range.
  @Test("Positions beyond the track settle inside the range")
  func settleClamps() {
    #expect(SliderDrag.settle(dragValue: -20).committed == 0)
    #expect(SliderDrag.settle(dragValue: 140).committed == 100)
    #expect(SliderDrag.settle(dragValue: -20).value == 0)
    #expect(SliderDrag.settle(dragValue: 140).value == 100)
  }

  // MARK: - Keeping the binding current during a drag

  /// The defect this guards: the slider published each movement to the hardware but wrote
  /// only its own private `dragValue`, leaving the bound value at the number the drag started
  /// from. The owning card renders its header from that binding and cannot see `dragValue`,
  /// and its own re-sync is suppressed while a drag is in progress — so the header stayed
  /// frozen at the starting number for the whole gesture while the track followed the pointer.
  @Test("Tracking a movement reports the binding value, not only the published number")
  func trackPublishesBindingValue() {
    let tracked = SliderDrag.track(atX: 124, width: 248)
    #expect(tracked.published == 50)
    #expect(tracked.value == 50)
  }

  /// Whatever the card shows mid-drag has to be the same number the hardware is being sent,
  /// otherwise the header and the display disagree for the length of the gesture.
  @Test("The tracked value and the published value never disagree")
  func trackedValueMatchesPublished() {
    for locationX in stride(from: CGFloat(-20), through: 300, by: 17) {
      let tracked = SliderDrag.track(atX: locationX, width: 248)
      #expect(tracked.value == Double(tracked.published))
    }
  }

  /// Releasing the finger must not nudge the number the user was already watching, so the
  /// last tracked position and the settled result share their rounding.
  @Test("Releasing at the last tracked position changes nothing")
  func trackAgreesWithSettle() {
    for locationX in stride(from: CGFloat(0), through: 248, by: 11) {
      let tracked = SliderDrag.track(atX: locationX, width: 248)
      let settled = SliderDrag.settle(dragValue: tracked.value)
      #expect(settled.committed == tracked.published)
      #expect(settled.value == tracked.value)
    }
  }

  @Test("Tracking uses the measured width and clamps to the range")
  func trackFollowsMeasuredWidthAndClamps() {
    #expect(SliderDrag.track(atX: 120, width: 240).published == 50)
    #expect(SliderDrag.track(atX: 120, width: 248).published == 48)
    #expect(SliderDrag.track(atX: -30, width: 248).published == 0)
    #expect(SliderDrag.track(atX: 400, width: 248).published == 100)
    #expect(SliderDrag.track(atX: 50, width: 0).published == 0)
  }

  // MARK: - Position to value

  /// The endpoints are the whole point of measuring the real width: with a hard-coded width
  /// the right-hand end was unreachable and the track carried a systematic offset.
  @Test("The track endpoints map exactly to the range endpoints")
  func endpointsAreExact() {
    #expect(SliderDrag.value(atX: 0, width: 248) == 0)
    #expect(SliderDrag.value(atX: 248, width: 248) == 100)
  }

  @Test("The midpoint of the real width is the midpoint of the range")
  func midpointIsExact() {
    #expect(SliderDrag.value(atX: 124, width: 248) == 50)
  }

  /// The rendered width is what must drive the conversion. Measuring 248 while converting
  /// against 240 put every value on the track off by theratio between them.
  @Test("Conversion follows the measured width rather than a fixed one")
  func followsMeasuredWidth() {
    #expect(SliderDrag.value(atX: 120, width: 240) == 50)
    #expect(SliderDrag.value(atX: 120, width: 248) == 48)
  }

  @Test("Positions outside the track are clamped to the range")
  func clampsOutOfBounds() {
    #expect(SliderDrag.value(atX: -30, width: 248) == 0)
    #expect(SliderDrag.value(atX: 400, width: 248) == 100)
  }

  /// A zero width happens on the first layout pass, before the track has been measured.
  @Test("An unmeasured track yields the lower bound instead of dividing by zero")
  func zeroWidthIsSafe() {
    #expect(SliderDrag.value(atX: 50, width: 0) == 0)
  }
}
