import Foundation
import Testing

@testable import DisplayDJBar

@Suite("Scroll wheel coalescing")
struct ScrollWheelCoalescerTests {

  /// The defect this guards: a single flick is dozens of events, and an event-driven write
  /// asked the hardware for every value the pointer swept past. DDC is not fast enough for
  /// that, and the intermediate values are not what the user chose anyway.
  @Test("Twenty events add up to one step")
  func manyEventsOneStep() {
    var coalescer = ScrollWheelCoalescer()
    for _ in 0..<20 { coalescer.add(ScrollWheelStep.fineDelta) }
    #expect(coalescer.pending == 40)
    #expect(coalescer.take() == 40)
  }

  @Test("Taking clears what is owed")
  func takeClears() {
    var coalescer = ScrollWheelCoalescer()
    coalescer.add(-6)
    #expect(coalescer.take() == -6)
    #expect(coalescer.take() == nil)
  }

  @Test("Nothing accumulated means nothing to send")
  func nothingPending() {
    var coalescer = ScrollWheelCoalescer()
    #expect(coalescer.take() == nil)
  }

  /// Not the same as nothing having happened: if the user scrolled down and back up, the
  /// display is already where they left it, and sending a zero would be a write for nothing.
  @Test("A scroll down and back up owes nothing")
  func cancelledOut() {
    var coalescer = ScrollWheelCoalescer()
    coalescer.add(ScrollWheelStep.fineDelta)
    coalescer.add(-ScrollWheelStep.fineDelta)
    #expect(coalescer.take() == nil)
  }
}
