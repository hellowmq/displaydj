import AppKit

/// DisplayDJ's smallest brand mark: an open rounded channel and one fader cap.
///
/// The app icon may use the brand palette, but macOS menu-bar artwork must adapt to the
/// system appearance. Drawing this small reduction as a template keeps it legible in both
/// appearances. It is drawn independently at 18 pt instead of shrinking the app artwork.
enum DisplayDJStatusIcon {
  static func make(accessibilityDescription: String) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
      let gate = NSBezierPath()
      gate.move(to: NSPoint(x: 14, y: 12.5))
      gate.line(to: NSPoint(x: 14, y: 13))
      gate.curve(to: NSPoint(x: 11.5, y: 15.5), controlPoint1: NSPoint(x: 14, y: 14.4), controlPoint2: NSPoint(x: 12.9, y: 15.5))
      gate.line(to: NSPoint(x: 7, y: 15.5))
      gate.curve(to: NSPoint(x: 3.5, y: 12), controlPoint1: NSPoint(x: 5.1, y: 15.5), controlPoint2: NSPoint(x: 3.5, y: 13.9))
      gate.line(to: NSPoint(x: 3.5, y: 6))
      gate.curve(to: NSPoint(x: 7, y: 2.5), controlPoint1: NSPoint(x: 3.5, y: 4.1), controlPoint2: NSPoint(x: 5.1, y: 2.5))
      gate.line(to: NSPoint(x: 11.5, y: 2.5))
      gate.curve(to: NSPoint(x: 14, y: 5), controlPoint1: NSPoint(x: 12.9, y: 2.5), controlPoint2: NSPoint(x: 14, y: 3.6))
      gate.line(to: NSPoint(x: 14, y: 5.5))
      gate.lineCapStyle = .round
      gate.lineJoinStyle = .round
      gate.lineWidth = 2
      gate.stroke()

      let fader = NSBezierPath()
      fader.move(to: NSPoint(x: 8, y: 9))
      fader.line(to: NSPoint(x: 14, y: 9))
      fader.lineCapStyle = .round
      fader.lineWidth = 2
      fader.stroke()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = accessibilityDescription
    return image
  }
}
