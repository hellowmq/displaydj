import Foundation

/// Names the display the menu bar wheel — and the hotkeys, once enabled — will act on.
///
/// Selection used to have no observable consequence at all: it moved a four-point dot and
/// slightly darkened one card, while the hotkeys it existed for are off by default. The
/// wheel changed that, and in doing so made the target worth naming. Without a name the
/// user scrolls, watches one of two identical panels change, and infers which one was
/// addressed — which is to say they learn the model by experiment, one surprise at a time.
enum ScrollTargetBadge {
  /// Withheld on a single display: there is no other candidate, so the label would only
  /// add words where none are needed.
  static func shows(displayCount: Int) -> Bool {
    displayCount > 1
  }

  /// What the badge says. It names the hotkeys only when they are actually live, so the
  /// label never claims an effect the current settings do not have.
  static func title(hotkeysEnabled: Bool) -> String {
    hotkeysEnabled ? "滚轮 · 快捷键目标" : "滚轮目标"
  }

  static let accessibilityLabel = "滚轮调节目标显示器"
}
