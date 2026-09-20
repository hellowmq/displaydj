import AppKit

/// A compact, template-rendered version of the asymmetric DisplayDJ DJ Gate.
///
/// The app icon may use the brand palette, but macOS menu-bar artwork must adapt to the
/// system appearance. Drawing this small reduction as a template keeps it legible in both
/// appearances while retaining the channel, fader and cue concepts.
enum DisplayDJStatusIcon {
  static func make(accessibilityDescription: String) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
      let gate = NSBezierPath()
      gate.move(to: NSPoint(x: 5, y: 15))
      gate.line(to: NSPoint(x: 5, y: 7.25))
      gate.curve(to: NSPoint(x: 9.25, y: 3.5), controlPoint1: NSPoint(x: 5, y: 4.6), controlPoint2: NSPoint(x: 6.7, y: 3.5))
      gate.line(to: NSPoint(x: 11.5, y: 3.5))
      gate.curve(to: NSPoint(x: 14, y: 6), controlPoint1: NSPoint(x: 12.9, y: 3.5), controlPoint2: NSPoint(x: 14, y: 4.6))
      gate.lineCapStyle = .round
      gate.lineJoinStyle = .round
      gate.lineWidth = 2
      gate.stroke()

      let track = NSBezierPath()
      track.move(to: NSPoint(x: 9, y: 6))
      track.line(to: NSPoint(x: 9, y: 13.5))
      track.lineCapStyle = .round
      track.lineWidth = 2
      track.stroke()

      NSBezierPath(ovalIn: NSRect(x: 6.5, y: 8, width: 5, height: 5)).fill()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = accessibilityDescription
    return image
  }
}
