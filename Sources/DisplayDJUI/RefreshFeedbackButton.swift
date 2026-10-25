import SwiftUI

/// The system symbol owns its rotation axis and start/stop timing.
public struct RefreshFeedbackButton: View {
  let isRefreshing: Bool
  let isDisabled: Bool
  let refresh: @MainActor () async -> Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var feedback = RefreshFeedbackState()

  public init(isRefreshing: Bool, isDisabled: Bool, refresh: @escaping @MainActor () async -> Bool) {
    self.isRefreshing = isRefreshing
    self.isDisabled = isDisabled
    self.refresh = refresh
  }

  private var running: Bool { feedback.isRequestInFlight || isRefreshing }

  public var body: some View {
    Button {
      guard let id = feedback.begin(isDisabled: isDisabled, isRefreshing: isRefreshing) else { return }
      // Hiding the panel ends visual feedback, not the model's read.
      Task { @MainActor in
        await Task.yield()
        let accepted = await refresh()
        feedback.finish(id, accepted: accepted)
      }
    } label: {
      glyph.frame(width: 28, height: 28).contentShape(Rectangle())
    }
    .buttonStyle(RefreshPressStyle())
    .disabled(isDisabled || running)
    .overlay(alignment: .leading) {
      if feedback.pendingLabelID != nil {
        Text("刷新中").font(.system(size: 11)).foregroundStyle(.secondary)
          .fixedSize().offset(x: -40)
          .allowsHitTesting(false).accessibilityHidden(true)
      }
    }
    .padding(.leading, 40)
    .accessibilityLabel("刷新显示器")
    .accessibilityValue(running ? "正在刷新" : feedback.completionID != nil ? "刷新已结束" : "就绪")
    .help(running ? "正在刷新显示器" : "刷新显示器（⌘R）")
    .keyboardShortcut("r", modifiers: .command)
    .onAppear { feedback.setVisible(true) }
    .onDisappear { feedback.setVisible(false) }
    .task(id: feedback.requestID) {
      let id = feedback.requestID
      guard feedback.isRequestInFlight else { return }
      do { try await Task.sleep(for: RefreshFeedbackState.pendingLabelDelay) }
      catch { return }
      feedback.revealPendingLabel(id)
    }
    .task(id: feedback.completionID) {
      guard let id = feedback.completionID else { return }
      try? await Task.sleep(for: RefreshFeedbackState.completionDuration)
      guard !Task.isCancelled else { return }
      feedback.expire(id)
    }
  }

  @ViewBuilder private var glyph: some View {
    let symbol = Image(systemName: "arrow.clockwise")
      .font(.system(size: 12, weight: .medium))
    if #available(macOS 15, *), !reduceMotion, feedback.isVisible {
      symbol
        .symbolEffect(.rotate.clockwise, options: .nonRepeating.speed(3), value: feedback.requestID)
        .frame(width: 16, height: 16)
    } else {
      symbol.frame(width: 16, height: 16)
    }
  }
}

/// Keep the original monochrome symbol visible while busy; pressing gives
/// immediate local feedback without waiting for a read or a symbol animation.
private struct RefreshPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.foregroundStyle(Color.primary)
      .opacity(configuration.isPressed ? 0.55 : 1)
  }
}
