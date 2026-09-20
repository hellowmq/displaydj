import SwiftUI

/// How tall the card list is allowed to be, given how tall its content actually is.
///
/// A popover takes its size from its content's *ideal* height, and a `ScrollView` has no ideal
/// height — it accepts whatever height it is handed and scrolls the rest. That is what made the
/// first open look broken: the popover is shown before any display is known, so it was measured
/// against the empty state, and the cards that arrived a moment later were silently clipped
/// inside the scroll view instead of making the window taller. The second card's slider was
/// simply below the fold, with nothing on screen saying so.
///
/// Measuring the content and pinning the viewport to that measurement gives the popover a height
/// to follow again, for every later growth as well: a monitor plugged in while the popover is
/// open, a failure banner, the alias fields that appear in reorder mode.
///
/// The cap is the other half. Without it a six-monitor desk would ask for a popover taller than
/// the screen, which is the reason the scroll view is here in the first place.
enum DisplayCardsViewport {
  /// Tallest the list may grow before it starts scrolling.
  static let maximumHeight: CGFloat = 400

  /// Height used for the single layout pass before the content has reported its own.
  ///
  /// Cannot be zero: a zero-height viewport is a viewport whose content is never laid out, and
  /// content that is never laid out never reports a height — the measurement would never start.
  /// One card's worth is the smallest guess that is always useful, and it is derived from the
  /// slider's own row height so it cannot drift far from what a card really costs.
  static var unmeasuredHeight: CGFloat { BrightnessSliderMetrics.hitHeight + 32 }

  /// The viewport height for content of the given height.
  ///
  /// Non-positive and non-finite inputs mean "not measured yet", not "no cards": an unmeasured
  /// geometry reader reports zero, and treating that as a real answer is how the list would
  /// collapse to nothing and stay there.
  static func height(contentHeight: CGFloat) -> CGFloat {
    guard contentHeight.isFinite, contentHeight > 0 else { return unmeasuredHeight }
    return min(contentHeight, maximumHeight)
  }
}

extension View {
  /// Publishes this view's laid-out height into `height`.
  ///
  /// Lives next to the rule that consumes it. Applied to the card stack *inside* the scroll
  /// view on purpose: a scroll view proposes no height to its content, so the stack lays out at
  /// its own full height there even while the viewport around it is still too short to show it.
  /// That is precisely the number the popover has to be told about, and precisely the number the
  /// viewport itself does not have.
  func measuringHeight(into height: Binding<CGFloat>) -> some View {
    background(
      GeometryReader { proxy in
        Color.clear
          .onAppear { height.wrappedValue = proxy.size.height }
          .onChange(of: proxy.size.height) { newHeight in
            height.wrappedValue = newHeight
          }
      }
    )
  }
}
