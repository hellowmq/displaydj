import AppKit
import Testing
@testable import DisplayDJLite

@MainActor
private final class SliderActionSpy: NSObject {
  var values: [Int] = []
  @objc func changed(_ sender: NSSlider) { values.append(Int(sender.doubleValue.rounded())) }
}

@Suite("Lite native slider input")
@MainActor
struct LiteNativeSliderTests {
  private func control() -> (LiteNativeBrightnessSlider, SliderActionSpy) {
    _ = NSApplication.shared
    let slider = LiteNativeBrightnessSlider(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
    slider.minValue = 0; slider.maxValue = 100; slider.doubleValue = 62
    slider.hasReading = true; slider.isEnabled = true
    let spy = SliderActionSpy()
    slider.target = spy; slider.action = #selector(SliderActionSpy.changed(_:))
    return (slider, spy)
  }

  @Test func rightArrowAndAccessibilityBothSendFivePointActions() throws {
    let (slider, spy) = control()
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
      characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
    slider.keyDown(with: event)
    #expect(slider.doubleValue == 67)
    #expect(slider.accessibilityPerformDecrement())
    #expect(slider.doubleValue == 62)
    #expect(spy.values == [67, 62])
  }

  @Test func unknownAndDisabledControlsCannotSubmit() {
    let (slider, spy) = control()
    slider.hasReading = false
    #expect(slider.accessibilityValue() == nil)
    #expect(!slider.accessibilityPerformIncrement())
    slider.hasReading = true; slider.isEnabled = false
    #expect(!slider.accessibilityPerformDecrement())
    #expect(spy.values.isEmpty)
  }

  @Test func steppingAtTheBoundaryStillSubmitsManualIntent() {
    let (slider, spy) = control()
    slider.doubleValue = 100
    #expect(slider.accessibilityPerformIncrement())
    #expect(slider.doubleValue == 100)
    #expect(spy.values == [100])
  }

  @Test func pointerTrackingUpdatesContinuouslyAndEndsOutsideTheTrack() throws {
    let (slider, spy) = control()
    slider.doubleValue = 50
    var tracking: [Bool] = []
    slider.onTracking = { tracking.append($0) }
    func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
      try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 22),
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1))
    }
    slider.mouseDown(with: try event(.leftMouseDown, x: 150))
    #expect(slider.trackingBrightness)
    slider.mouseDragged(with: try event(.leftMouseDragged, x: 245))
    #expect(slider.doubleValue > 80)
    slider.mouseUp(with: try event(.leftMouseUp, x: 500))
    #expect(slider.doubleValue == 100)
    #expect(!slider.trackingBrightness)
    #expect(tracking == [true, false])
    #expect(spy.values.count == 3)
  }

  @Test func tabCanLeaveAnUnlinkedHostedSlider() throws {
    let (first, _) = control()
    let (second, _) = control()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
      styleMask: [], backing: .buffered, defer: false)
    first.frame.origin.y = 90; second.frame.origin.y = 10
    window.contentView?.addSubview(first); window.contentView?.addSubview(second)
    window.makeFirstResponder(first)
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
    first.keyDown(with: event)
    #expect(window.firstResponder === second)
  }

  @Test(arguments: ["escape", "focus", "disabled", "unknown", "hidden", "detached", "window", "app"])
  func interruptedGestureEndsOnceAndOldReleaseCannotSubmitAgain(_ interruption: String) throws {
    let (slider, spy) = control()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
      styleMask: [], backing: .buffered, defer: false)
    window.contentView?.addSubview(slider)
    var tracking: [Bool] = []
    slider.onTracking = { tracking.append($0) }
    func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
      try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 22),
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1))
    }
    slider.mouseDown(with: try event(.leftMouseDown, x: 150))
    slider.mouseDragged(with: try event(.leftMouseDragged, x: 245))
    let submitted = spy.values
    switch interruption {
    case "escape":
      slider.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
    case "focus": _ = slider.resignFirstResponder()
    case "disabled": slider.isEnabled = false
    case "unknown": slider.hasReading = false
    case "hidden": slider.isHidden = true
    case "detached": slider.removeFromSuperview()
    case "window": NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    default: NotificationCenter.default.post(name: NSApplication.didHideNotification, object: NSApp)
    }
    #expect(!slider.trackingBrightness)
    slider.cancelTracking()
    slider.mouseDragged(with: try event(.leftMouseDragged, x: 0))
    slider.mouseUp(with: try event(.leftMouseUp, x: 0))
    #expect(spy.values == submitted)
    #expect(tracking == [true, false])
    slider.isHidden = false; slider.isEnabled = true; slider.hasReading = true
    if slider.superview == nil { window.contentView?.addSubview(slider) }
    slider.mouseDown(with: try event(.leftMouseDown, x: 20))
    slider.mouseUp(with: try event(.leftMouseUp, x: 20))
    #expect(tracking == [true, false, true, false])
    #expect(spy.values.last != submitted.last)
  }
}
