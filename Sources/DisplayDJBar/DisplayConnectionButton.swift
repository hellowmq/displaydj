import DisplayDJCore
import SwiftUI

/// Stops output to one display, from that display's own card.
///
/// On the card rather than in a menu at the bottom because the card is where the
/// user is already looking at this particular monitor: a separate list would ask
/// them to match a name here with a row there, and the whole point of one card
/// per display is that the control and the thing it controls are in one place.
///
/// The button is disabled — not hidden — when the change cannot be made, so the
/// reason is available as a tooltip and to VoiceOver instead of being silently
/// unavailable.
///
/// Its target is 28×28 even though the glyph is 10pt. It used to be a bare `Image` in a 14pt
/// frame — a 196pt² hit area, a quarter of the macOS minimum — which was survivable only
/// because it sat in a row of thirteen controls; R2 left it as one of the two things a card can
/// do, so it has to be the size of one. The glyph is unchanged, so the picture is the same and
/// only the reachable area grew.
struct DisplayConnectionButton: View {
  let display: DisplayDescriptor
  @ObservedObject var controller: DisplayBarController

  /// The smallest square macOS expects a control's target to cover.
  private static let targetSide: CGFloat = 28

  private var availability: DisplayConnectionAvailability {
    controller.connectionAvailability(for: display)
  }

  private var guidance: String {
    availability.guidance ?? "停止向这台显示器输出信号"
  }

  var body: some View {
    Button {
      Task { await controller.disconnect(display) }
    } label: {
      Image(systemName: "power")
        .font(.system(size: 10, weight: .medium))
        .frame(width: Self.targetSide, height: Self.targetSide)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundColor(.secondary)
    .disabled(!availability.canDisconnect || controller.showsActivitySpinner)
    .help(guidance)
    .accessibilityLabel("断开 \(display.name)")
    .accessibilityHint(guidance)
  }
}
