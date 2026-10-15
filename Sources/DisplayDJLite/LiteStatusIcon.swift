import AppKit

enum LiteStatusIcon {
  static func makeImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      NSColor.black.setStroke()
      NSColor.black.setFill()
      let path = NSBezierPath()
      path.move(to: NSPoint(x: 13, y: 13))
      path.curve(to: NSPoint(x: 11, y: 15), controlPoint1: NSPoint(x: 13, y: 15), controlPoint2: NSPoint(x: 12, y: 15))
      path.line(to: NSPoint(x: 7, y: 15))
      path.curve(to: NSPoint(x: 3, y: 11), controlPoint1: NSPoint(x: 4, y: 15), controlPoint2: NSPoint(x: 3, y: 14))
      path.line(to: NSPoint(x: 3, y: 7))
      path.curve(to: NSPoint(x: 7, y: 3), controlPoint1: NSPoint(x: 3, y: 4), controlPoint2: NSPoint(x: 4, y: 3))
      path.line(to: NSPoint(x: 11, y: 3))
      path.curve(to: NSPoint(x: 13, y: 5), controlPoint1: NSPoint(x: 12, y: 3), controlPoint2: NSPoint(x: 13, y: 3))
      path.lineWidth = 1.6
      path.lineCapStyle = .round
      path.stroke()
      NSBezierPath(ovalIn: NSRect(x: 12.15, y: 8.15, width: 1.7, height: 1.7)).fill()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "DisplayDJ Lite"
    return image
  }
}
