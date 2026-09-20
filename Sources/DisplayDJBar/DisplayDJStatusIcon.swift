import AppKit

/// A compact, template-rendered version of the DisplayDJ display-and-fader mark.
///
/// The app icon may use the brand palette, but macOS menu-bar artwork must adapt to the
/// system appearance. Drawing this small reduction as a template keeps it legible in both
/// appearances while retaining the display frame, fader and cue concepts.
enum DisplayDJStatusIcon {
  static func make(accessibilityDescription: String) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
      let frame = NSRect(x: 2, y: 3.5, width: 14, height: 11)
      NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3).stroke()

      let track = NSBezierPath()
      track.move(to: NSPoint(x: 9, y: 5.5))
      track.line(to: NSPoint(x: 9, y: 12.5))
      track.lineCapStyle = .round
      track.lineWidth = 2
      track.stroke()

      NSBezierPath(ovalIn: NSRect(x: 6.75, y: 7.75, width: 4.5, height: 4.5)).fill()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = accessibilityDescription
    return image
  }
}
