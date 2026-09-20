import AppKit
import Combine

/// The menu bar item: what it shows, and what keeps it current.
///
/// Kept in its own file for the same reason as the polling, write and prune units. This one
/// has an extra claim on being read as a whole: the status item is the only brightness on
/// screen that SwiftUI does *not* redraw for us. Every card re-renders from `@Published`
/// state, whereas this number is written imperatively by one sink — so the list of inputs
/// that sink subscribes to has to be checkable against the list the number is computed from,
/// and that comparison is only possible if both sit together.
extension DisplayBarController {

  /// Keeps the menu bar label in step with the only input it depends on.
  ///
  /// The menu bar now shows the sun icon only and announces the display count; both are a
  /// function of `displays` alone. The brightness maps and the selection no longer affect the
  /// item, so the sink watches only the display list. It is still written imperatively here
  /// rather than by SwiftUI, and the item is still the only brightness visible while the
  /// popover is closed — but with no number to show, neither staleness nor cross-display
  /// ambiguity can occur, which is exactly why the number was dropped.
  func observeStatusItemInputs() {
    $displays
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.updateStatusItemTitle()
      }
      .store(in: &cancellables)
  }

  /// Shows the sun icon in the menu bar with no brightness number beside it.
  ///
  /// What to draw *and* what to announce are both decided by `StatusItemTitle` so the rule can
  /// be tested without a status item; this method only applies the result.
  ///
  /// The menu bar deliberately carries no number: a single brightness figure is stale the
  /// moment the popover closes (polling stops then) and meaningless with more than one display
  /// attached, because it cannot name its display. The label is still re-applied on every
  /// update rather than set once at setup, because `NSButton` derives its accessibility label
  /// from a non-empty title — here the title is always empty, so the spoken label would be
  /// displaced if it were not set explicitly each time.
  func updateStatusItemTitle() {
    guard let button = statusItem?.button else { return }
    let presentation = StatusItemTitle.presentation(displaysCount: controller.displays.count)
    button.title = presentation.title
    button.imagePosition = presentation.showsNumber ? .imageLeading : .imageOnly
    button.setAccessibilityLabel(presentation.accessibilityLabel)
    // Reserve a fixed menu-bar slot instead of `variableLength`. The item now holds only the
    // sun glyph, but pinning the length keeps the slot — and every other menu-bar item — from
    // shifting if the icon ever swaps (the failure glyph in `ScrollWheel`) or AppKit relayouts.
    statusItem?.length = Self.reservedStatusItemLength(for: button)
  }

  /// Width the status item is pinned to: the sun glyph plus a small margin.
  ///
  /// The menu bar no longer carries a brightness number, so the slot only has to fit the icon.
  /// Computed from the live button rather than a constant so it tracks whatever icon size
  /// AppKit actually renders, including the failure glyph swap in `ScrollWheel`.
  private static func reservedStatusItemLength(for button: NSButton) -> CGFloat {
    let iconWidth = button.image?.size.width ?? 18
    return iconWidth + 10
  }
}
