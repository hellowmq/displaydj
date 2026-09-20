import Foundation
import Testing

@testable import DisplayDJBar

@Suite("Scroll wheel stepping")
struct ScrollWheelStepTests {

  // MARK: - Direction

  /// The defect this guards: brightness is not scrollable content, so the direction cannot
  /// be borrowed from the system's "natural scrolling" preference. Taking it from there
  /// would invert the control for half the users, and the wheel is the one entrance with no
  /// thumb to look at for confirmation.
  @Test("Up brightens, down dims")
  func directionIsFixed() {
    #expect(ScrollWheelStep.step(deltaY: 1, optionHeld: false) == ScrollWheelStep.fineDelta)
    #expect(ScrollWheelStep.step(deltaY: -1, optionHeld: false) == -ScrollWheelStep.fineDelta)
  }

  @Test("Option crosses the range in coarse steps")
  func optionCoarsens() {
    #expect(ScrollWheelStep.step(deltaY: 1, optionHeld: true) == ScrollWheelStep.coarseDelta)
    #expect(ScrollWheelStep.step(deltaY: -1, optionHeld: true) == -ScrollWheelStep.coarseDelta)
  }

  // MARK: - What is not a request

  /// A trackpad keeps emitting sub-pixel deltas after the fingers have lifted. Acting on
  /// them would drive the display with changes the user stopped asking for, and would keep
  /// the write queue busy with values that were swept past rather than chosen.
  @Test("The inertial tail is not a request")
  func subThresholdIgnored() {
    #expect(ScrollWheelStep.step(deltaY: 0.1, optionHeld: false) == 0)
    #expect(ScrollWheelStep.step(deltaY: -0.4, optionHeld: false) == 0)
  }

  @Test("A non-finite delta is not a request either")
  func nonFiniteIgnored() {
    #expect(ScrollWheelStep.step(deltaY: .nan, optionHeld: false) == 0)
  }

  // MARK: - Magnitude

  /// One notch of a mouse wheel and one flick of a trackpad report wildly different numbers.
  /// Both mean "one step", so the size of the reported delta must not size the change.
  @Test("A larger delta still means one step")
  func magnitudeDoesNotSizeTheChange() {
    #expect(ScrollWheelStep.step(deltaY: 12.5, optionHeld: false) == ScrollWheelStep.fineDelta)
    #expect(ScrollWheelStep.step(deltaY: -12.5, optionHeld: false) == -ScrollWheelStep.fineDelta)
  }
}
