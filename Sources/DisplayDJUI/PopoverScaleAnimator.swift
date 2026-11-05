import AppKit
import QuartzCore

/// Provides smooth, anchor-aware scale animations for menu bar popovers.
/// Simulates macOS window miniaturization/expansion anchored to the status item icon,
/// eliminating the default AppKit popover jitter and bounce.
@MainActor
public enum PopoverScaleAnimator {
  private static let inDuration: CFTimeInterval = 0.18
  private static let outDuration: CFTimeInterval = 0.14
  private static let initialScale: CGFloat = 0.15

  /// Animates the popover expanding outward from the status bar button.
  public static func animateIn(popover: NSPopover, button: NSButton) {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    guard let window = popover.contentViewController?.view.window,
          let frameView = window.contentView?.superview else { return }

    frameView.wantsLayer = true
    guard let layer = frameView.layer else { return }

    applyAnchor(to: frameView, layer: layer, button: button, window: window)

    let scaleAnim = CABasicAnimation(keyPath: "transform")
    scaleAnim.fromValue = CATransform3DMakeScale(initialScale, initialScale, 1.0)
    scaleAnim.toValue = CATransform3DIdentity

    let opacityAnim = CABasicAnimation(keyPath: "opacity")
    opacityAnim.fromValue = 0.0
    opacityAnim.toValue = 1.0

    let group = CAAnimationGroup()
    group.animations = [scaleAnim, opacityAnim]
    group.duration = inDuration
    group.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
    group.fillMode = .both

    layer.add(group, forKey: "popoverScaleAnimation")
  }

  /// Animates the popover collapsing inward towards the status bar button before closing.
  public static func animateOut(popover: NSPopover, button: NSButton, completion: @escaping () -> Void) {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      completion()
      return
    }
    guard let window = popover.contentViewController?.view.window,
          let frameView = window.contentView?.superview,
          let layer = frameView.layer else {
      completion()
      return
    }

    applyAnchor(to: frameView, layer: layer, button: button, window: window)

    let scaleAnim = CABasicAnimation(keyPath: "transform")
    scaleAnim.fromValue = CATransform3DIdentity
    scaleAnim.toValue = CATransform3DMakeScale(initialScale, initialScale, 1.0)

    let opacityAnim = CABasicAnimation(keyPath: "opacity")
    opacityAnim.fromValue = 1.0
    opacityAnim.toValue = 0.0

    let group = CAAnimationGroup()
    group.animations = [scaleAnim, opacityAnim]
    group.duration = outDuration
    group.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.0, 0.7, 0.1)
    group.fillMode = .forwards
    group.isRemovedOnCompletion = false

    CATransaction.begin()
    CATransaction.setCompletionBlock {
      layer.removeAnimation(forKey: "popoverScaleAnimation")
      completion()
    }
    layer.add(group, forKey: "popoverScaleAnimation")
    CATransaction.commit()
  }

  private static func applyAnchor(
    to frameView: NSView,
    layer: CALayer,
    button: NSButton,
    window: NSWindow
  ) {
    let buttonRect = button.convert(button.bounds, to: nil)
    let buttonScreen = button.window?.convertToScreen(buttonRect) ?? .zero
    let windowFrame = window.frame

    let anchorX: CGFloat
    if windowFrame.width > 0 {
      let rel = (buttonScreen.midX - windowFrame.minX) / windowFrame.width
      anchorX = min(max(rel, 0.05), 0.95)
    } else {
      anchorX = 0.5
    }

    // In flipped coordinates (origin at top), the menu bar is at y = 0.
    // In non-flipped AppKit coordinates (origin at bottom), the menu bar is at y = 1.
    let anchorY: CGFloat = frameView.isFlipped ? 0.0 : 1.0
    let targetAnchor = CGPoint(x: anchorX, y: anchorY)

    let currentAnchor = layer.anchorPoint
    guard currentAnchor != targetAnchor else { return }

    let size = layer.bounds.size
    let deltaX = (targetAnchor.x - currentAnchor.x) * size.width
    let deltaY = (targetAnchor.y - currentAnchor.y) * size.height

    layer.anchorPoint = targetAnchor
    layer.position = CGPoint(x: layer.position.x + deltaX, y: layer.position.y + deltaY)
  }
}
