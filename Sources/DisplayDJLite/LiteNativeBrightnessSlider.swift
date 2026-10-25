import AppKit
import SwiftUI

/// AppKit input and accessibility, with Full's 13/22/44pt fader.
struct LiteBrightnessSlider: NSViewRepresentable {
  @Binding var value: Double
  @Binding var dragging: Bool
  let enabled: Bool
  let hasReading: Bool
  let name: String
  let submit: (Int) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> LiteNativeBrightnessSlider {
    let view = LiteNativeBrightnessSlider(frame: .zero)
    view.cell = LiteBrightnessSliderCell()
    view.minValue = 0; view.maxValue = 100
    view.isContinuous = true
    view.target = context.coordinator
    view.action = #selector(Coordinator.changed(_:))
    view.onTracking = { [weak coordinator = context.coordinator, weak view] active in
      if active { coordinator?.lastSubmitted = nil }
      if coordinator?.updatingView == true {
        Task { @MainActor [weak coordinator, weak view] in
          guard view?.trackingBrightness == active else { return }
          coordinator?.parent.dragging = active
        }
      } else { coordinator?.parent.dragging = active }
    }
    view.onDiscreteStep = { [weak coordinator = context.coordinator] in coordinator?.lastSubmitted = nil }
    return view
  }

  func updateNSView(_ view: LiteNativeBrightnessSlider, context: Context) {
    context.coordinator.updatingView = true
    defer { context.coordinator.updatingView = false }
    context.coordinator.parent = self
    view.hasReading = hasReading
    view.isEnabled = enabled && hasReading
    if !view.trackingBrightness { view.doubleValue = value }
    view.setAccessibilityLabel("\(name) 亮度")
    view.setAccessibilityHelp(enabled ? "按左右方向键以 5% 为步进调节" : "亮度未确认或操作进行中")
    view.needsDisplay = true
  }

  static func dismantleNSView(_ view: LiteNativeBrightnessSlider, coordinator: Coordinator) {
    coordinator.updatingView = true
    defer { coordinator.updatingView = false }
    view.cancelTracking()
    view.onTracking = nil
    view.onDiscreteStep = nil
    view.target = nil
  }

  @MainActor final class Coordinator: NSObject {
    var parent: LiteBrightnessSlider
    var lastSubmitted: Int?
    var updatingView = false
    init(_ parent: LiteBrightnessSlider) { self.parent = parent }
    @objc func changed(_ slider: NSSlider) {
      let value = min(100, max(0, Int(slider.doubleValue.rounded())))
      slider.doubleValue = Double(value)
      parent.value = Double(value)
      guard lastSubmitted != value else { return }
      lastSubmitted = value
      parent.submit(value)
    }
  }
}

final class LiteNativeBrightnessSlider: NSSlider {
  var hasReading = false { didSet { if !hasReading { cancelTracking() } } }
  override var isEnabled: Bool { didSet { if !isEnabled { cancelTracking() } } }
  private(set) var trackingBrightness = false
  var onTracking: ((Bool) -> Void)?
  var onDiscreteStep: (() -> Void)?
  private var trackingOffset: CGFloat = 0
  override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 44) }
  override var acceptsFirstResponder: Bool { isEnabled }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled, hasReading else { return }
    cancelTracking()
    window?.makeFirstResponder(self)
    let point = convert(event.locationInWindow, from: nil)
    let knob = (cell as? NSSliderCell)?.knobRect(flipped: isFlipped) ?? .zero
    trackingOffset = knob.contains(point) ? point.x - knob.midX : 0
    trackingBrightness = true
    onTracking?(true)
    track(event)
  }

  override func mouseDragged(with event: NSEvent) { track(event) }
  override func mouseUp(with event: NSEvent) {
    guard trackingBrightness else { return }
    track(event)
    cancelTracking()
  }

  /// End only the input gesture. Already submitted hardware transactions keep
  /// their own verification/rollback semantics; cancellation never writes an undo.
  func cancelTracking() {
    guard trackingBrightness else { return }
    trackingBrightness = false
    trackingOffset = 0
    onTracking?(false)
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    cancelTracking()
    let center = NotificationCenter.default
    center.removeObserver(self)
    if let newWindow {
      for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                   NSWindow.didMiniaturizeNotification] {
        center.addObserver(self, selector: #selector(interrupted), name: name, object: newWindow)
      }
      for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification] {
        center.addObserver(self, selector: #selector(interrupted), name: name, object: NSApp)
      }
    }
    super.viewWillMove(toWindow: newWindow)
  }

  @objc private func interrupted(_ notification: Notification) { cancelTracking(); needsDisplay = true }
  override func viewDidHide() { cancelTracking(); super.viewDidHide() }
  deinit { NotificationCenter.default.removeObserver(self) }

  private func track(_ event: NSEvent) {
    guard trackingBrightness, isEnabled, hasReading, bounds.width > 22 else { return }
    let x = convert(event.locationInWindow, from: nil).x - trackingOffset
    doubleValue = min(100, max(0, Double((x - 11) / (bounds.width - 22)) * 100)).rounded()
    sendAction(action, to: target)
    needsDisplay = true
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 123, 125: step(-5)
    case 124, 126: step(5)
    case 53 where trackingBrightness: cancelTracking()
    case 48: moveFocus(backward: event.modifierFlags.contains(.shift))
    default: super.keyDown(with: event)
    }
  }
  override func accessibilityValue() -> Any? { hasReading ? doubleValue : nil }
  override func accessibilityValueDescription() -> String? { hasReading ? "\(Int(doubleValue.rounded()))%" : "未知" }
  override func accessibilityPerformIncrement() -> Bool { step(5) }
  override func accessibilityPerformDecrement() -> Bool { step(-5) }

  private func moveFocus(backward: Bool) {
    guard let window, let root = window.contentView else { return }
    // NSHostingView does not always link representables into AppKit's key loop.
    // Prefer its native loop; otherwise keep both screen faders keyboard reachable.
    let linked = backward ? previousValidKeyView : nextValidKeyView
    if let linked, linked !== self { window.makeFirstResponder(linked); return }
    func collect(_ view: NSView) -> [LiteNativeBrightnessSlider] {
      if let slider = view as? LiteNativeBrightnessSlider { return slider.isEnabled ? [slider] : [] }
      return view.subviews.flatMap(collect)
    }
    let sliders = collect(root).sorted {
      let left = $0.convert($0.bounds, to: root).midY
      let right = $1.convert($1.bounds, to: root).midY
      return root.isFlipped ? left < right : left > right
    }
    guard sliders.count > 1, let index = sliders.firstIndex(where: { $0 === self }) else {
      window.makeFirstResponder(nil); return
    }
    let next = (index + (backward ? -1 : 1) + sliders.count) % sliders.count
    window.makeFirstResponder(sliders[next])
  }

  @discardableResult private func step(_ delta: Int) -> Bool {
    guard isEnabled, hasReading else { return false }
    cancelTracking()
    let next = min(100, max(0, Int(doubleValue.rounded()) + delta))
    doubleValue = Double(next)
    onDiscreteStep?()
    sendAction(action, to: target)
    return true
  }

  override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { cancelTracking() }
    needsDisplay = true
    return resigned
  }
}

private final class LiteBrightnessSliderCell: NSSliderCell {
  private var slider: LiteNativeBrightnessSlider? { controlView as? LiteNativeBrightnessSlider }
  private var accent: NSColor {
    slider?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(red: 85/255, green: 217/255, blue: 1, alpha: 1)
      : NSColor(red: 0, green: 0.38, blue: 0.52, alpha: 1)
  }
  override func drawBar(inside rect: NSRect, flipped: Bool) {
    guard let slider else { return }
    let bounds = slider.bounds
    let track = NSRect(x: 11, y: bounds.midY - 6.5, width: max(0, bounds.width - 22), height: 13)
    NSColor.labelColor.withAlphaComponent(0.12).setFill()
    NSBezierPath(roundedRect: track, xRadius: 6.5, yRadius: 6.5).fill()
    if slider.hasReading {
      var fill = track; fill.size.width *= CGFloat(slider.doubleValue / 100)
      accent.withAlphaComponent(slider.isEnabled ? 1 : 0.45).setFill()
      NSBezierPath(roundedRect: fill, xRadius: 6.5, yRadius: 6.5).fill()
    }
    if slider.window?.firstResponder === slider, slider.window?.isKeyWindow == true {
      accent.setStroke()
      let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 5), xRadius: 8, yRadius: 8)
      ring.lineWidth = 2; ring.stroke()
    }
  }
  override func knobRect(flipped: Bool) -> NSRect {
    guard let slider else { return super.knobRect(flipped: flipped) }
    let x = CGFloat(slider.doubleValue / 100) * max(0, slider.bounds.width - 22)
    return NSRect(x: x, y: slider.bounds.midY - 11, width: 22, height: 22)
  }
  override func drawKnob(_ rect: NSRect) {
    guard let slider, slider.hasReading else { return }
    NSColor.white.withAlphaComponent(slider.isEnabled ? 1 : 0.45).setFill()
    NSBezierPath(ovalIn: rect).fill()
    NSColor.black.withAlphaComponent(0.12).setStroke()
    NSBezierPath(ovalIn: rect).stroke()
  }
}
