import Foundation

/// Selection names the menu-bar wheel only. Keyboard target policy is shown
/// separately, even when keyboard control happens to use the selected display.
enum ScrollTargetBadge {
  static func shows(displayCount: Int) -> Bool { displayCount > 1 }
  static let title = "菜单栏滚轮目标"
  static let accessibilityLabel = "滚轮调节目标显示器"
}
