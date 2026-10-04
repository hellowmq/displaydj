import AppKit
import SwiftUI

struct BrightnessHUDContent: Equatable {
  enum State: Equatable {
    case reading
    case changing(Int)
    case confirmed(Int)
    case failed(String)
  }
  let runtimeID: UInt32
  let name: String
  let state: State

  var value: Int? {
    switch state {
    case .changing(let value), .confirmed(let value): value
    default: nil
    }
  }

  var caption: String {
    switch state {
    case .reading: "正在读取硬件亮度…"
    case .changing, .confirmed: "硬件亮度"
    case .failed(let message): message
    }
  }

  /// Reading is an internal stage of each repeated adjustment, not a reason to clear
  /// a visible value. Only retain content from this screen's currently visible HUD.
  func presentation(after previous: BrightnessHUDContent?) -> BrightnessHUDContent {
    guard state == .reading, let previous,
          previous.runtimeID == runtimeID, previous.value != nil else { return self }
    return .init(runtimeID: runtimeID, name: name, state: previous.state)
  }

  var isFailure: Bool {
    if case .failed = state { return true }
    return false
  }
}

struct BrightnessHUDView: View {
  let content: BrightnessHUDContent

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Image(systemName: content.isFailure ? "exclamationmark.triangle" : "sun.max.fill")
          .font(.system(size: 24))
          .foregroundStyle(content.isFailure ? Color.orange : DisplayDJBrandColor.spectralCyan)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(content.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
          Text(content.caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        }
        Spacer(minLength: 0)
        if let value = content.value {
          Text("\(value)%").font(.system(size: 22, weight: .semibold, design: .rounded))
            .monospacedDigit()
        }
      }
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(.primary.opacity(0.12))
          if let value = content.value {
            Capsule().fill(DisplayDJBrandColor.spectralCyan)
              .frame(width: geometry.size.width * CGFloat(min(100, max(0, value))) / 100)
          }
        }
      }.frame(height: 5).accessibilityHidden(true)
    }
    .padding(20)
    .frame(width: 300, height: 120)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.1)))
    .accessibilityElement(children: .combine)
  }
}

private final class BrightnessHUDPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// One short-lived, click-through panel per affected screen; no activation or private OSD API.
@MainActor
final class BrightnessHUDController {
  private var panels: [UInt32: NSPanel] = [:]
  private var visibleContent: [UInt32: BrightnessHUDContent] = [:]
  private var dismissals: [UInt32: Task<Void, Never>] = [:]

  func show(_ content: BrightnessHUDContent) {
    guard let screen = NSScreen.screens.first(where: {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == content.runtimeID
    }) else { dismiss(content.runtimeID); return }
    let panel: NSPanel
    if let existing = panels[content.runtimeID] { panel = existing }
    else {
      panel = BrightnessHUDPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
      panel.isReleasedWhenClosed = false
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = true
      panel.level = .statusBar
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
      panel.ignoresMouseEvents = true
      panel.hidesOnDeactivate = false
      panels[content.runtimeID] = panel
    }
    let presented = content.presentation(after: visibleContent[content.runtimeID])
    visibleContent[content.runtimeID] = presented
    if let hostingView = panel.contentView as? NSHostingView<BrightnessHUDView> {
      hostingView.rootView = BrightnessHUDView(content: presented)
    } else {
      panel.contentView = NSHostingView(rootView: BrightnessHUDView(content: presented))
    }
    let frame = screen.visibleFrame
    panel.setFrame(NSRect(x: frame.midX - 150, y: frame.minY + min(80, frame.height * 0.12),
                          width: 300, height: 120), display: true)
    panel.orderFrontRegardless()
    dismissals[content.runtimeID]?.cancel()
    let seconds: Double
    switch content.state {
    case .reading, .changing: seconds = 10
    case .confirmed: seconds = 1.8
    case .failed: seconds = 3.5
    }
    dismissals[content.runtimeID] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      self?.dismiss(content.runtimeID)
    }
  }

  func hideAll() {
    for id in Array(panels.keys) { dismiss(id) }
  }

  func hide(for runtimeID: UInt32) { dismiss(runtimeID) }

  private func dismiss(_ id: UInt32) {
    visibleContent.removeValue(forKey: id)
    dismissals.removeValue(forKey: id)?.cancel()
    panels.removeValue(forKey: id)?.close()
  }
}
