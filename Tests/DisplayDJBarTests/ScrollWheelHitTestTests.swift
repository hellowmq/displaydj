import CoreGraphics
import Foundation
import Testing

@testable import DisplayDJBar

@Suite("Scroll wheel hit testing")
struct ScrollWheelHitTestTests {

  private let frame = CGRect(x: 100, y: 200, width: 40, height: 22)

  @Test("A wheel over the item is ours")
  func pointInside() {
    #expect(ScrollWheelHitTest.contains(CGPoint(x: 120, y: 210), in: frame))
  }

  /// The defect this guards: a global monitor sees every wheel on the system. Were the
  /// geometry to go wrong in the permissive direction, scrolling a document would change
  /// the brightness of a display the user was not looking at.
  @Test("A wheel anywhere else on the menu bar is not")
  func pointOutside() {
    #expect(!ScrollWheelHitTest.contains(CGPoint(x: 40, y: 210), in: frame))
    #expect(!ScrollWheelHitTest.contains(CGPoint(x: 120, y: 260), in: frame))
  }

  @Test("The edge is given a couple of points of slack")
  func edgeHasSlack() {
    #expect(ScrollWheelHitTest.contains(CGPoint(x: 99, y: 210), in: frame))
  }

  /// The item has no frame until it has been laid out. A hit test against one must not
  /// answer yes, or every wheel on the system would be captured during launch.
  @Test("A frame that does not exist yet captures nothing")
  func missingFrameCapturesNothing() {
    #expect(!ScrollWheelHitTest.contains(CGPoint(x: 120, y: 210), in: .zero))
    #expect(!ScrollWheelHitTest.contains(CGPoint(x: 120, y: 210), in: .null))
  }
}
