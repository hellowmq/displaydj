import Foundation
import Testing

@testable import DisplayDJBar

@Suite("Scroll target badge")
struct ScrollTargetBadgeTests {

  /// The defect this guards: selection had no observable consequence — it moved a four-point
  /// dot — while the wheel now reads it. Naming it is what makes the wheel predictable;
  /// without a name the user learns which display is addressed by watching one of two
  /// identical panels change.
  @Test("Two or more displays name the target")
  func multipleDisplaysShowBadge() {
    #expect(ScrollTargetBadge.shows(displayCount: 2))
    #expect(ScrollTargetBadge.shows(displayCount: 3))
  }

  @Test("With one display there is nothing to disambiguate")
  func singleDisplayHidesBadge() {
    #expect(!ScrollTargetBadge.shows(displayCount: 1))
    #expect(!ScrollTargetBadge.shows(displayCount: 0))
  }

  /// The hotkeys are off by default. Naming them while they are inert would credit the badge
  /// with an effect the current settings do not have.
  @Test("The hotkeys are named only while they are live")
  func titleFollowsHotkeys() {
    #expect(ScrollTargetBadge.title(hotkeysEnabled: false) == "滚轮目标")
    #expect(ScrollTargetBadge.title(hotkeysEnabled: true).contains("快捷键"))
  }
}
