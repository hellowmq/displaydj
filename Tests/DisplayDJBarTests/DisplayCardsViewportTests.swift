import CoreGraphics
import Testing

@testable import DisplayDJBar

/// The rule that keeps the popover's height tied to its cards.
///
/// The defect these tests exist for: the popover appears before any display is known, so it was
/// sized against the empty state, and the cards discovered a moment later were clipped inside a
/// scroll view that had accepted the too-short height without complaint. A `maxHeight` cannot
/// state "be as tall as your content, up to a limit" — only a measured, definite height can, and
/// these are the cases that definite height has to get right.
@Suite("Display cards viewport")
struct DisplayCardsViewportTests {

  @Test("Content shorter than the cap gets exactly the height it asked for")
  func shortContentIsNotPadded() {
    // The popover then ends up exactly as tall as its cards: no clipped slider below the fold,
    // and no band of dead space under the last card either.
    #expect(DisplayCardsViewport.height(contentHeight: 76) == 76)
    #expect(DisplayCardsViewport.height(contentHeight: 158) == 158)
  }

  @Test("Content taller than the cap is capped, which is what the scroll view is for")
  func tallContentIsCapped() {
    // Six monitors would otherwise ask for a popover taller than the screen.
    #expect(DisplayCardsViewport.height(contentHeight: 900) == DisplayCardsViewport.maximumHeight)
    #expect(
      DisplayCardsViewport.height(contentHeight: DisplayCardsViewport.maximumHeight + 1)
        == DisplayCardsViewport.maximumHeight
    )
  }

  @Test("The cap itself is returned unchanged")
  func theCapIsInclusive() {
    #expect(
      DisplayCardsViewport.height(contentHeight: DisplayCardsViewport.maximumHeight)
        == DisplayCardsViewport.maximumHeight
    )
  }

  @Test("An unmeasured content height falls back instead of collapsing the list")
  func unmeasuredContentFallsBack() {
    // Zero is what a geometry reader reports before it has laid anything out. Taking it
    // literally would give the viewport no height, and content with no height is never laid
    // out — so the measurement would never arrive and the list would stay collapsed forever.
    #expect(DisplayCardsViewport.height(contentHeight: 0) == DisplayCardsViewport.unmeasuredHeight)
    #expect(
      DisplayCardsViewport.height(contentHeight: -40) == DisplayCardsViewport.unmeasuredHeight
    )
    #expect(
      DisplayCardsViewport.height(contentHeight: .nan) == DisplayCardsViewport.unmeasuredHeight
    )
    #expect(
      DisplayCardsViewport.height(contentHeight: .infinity)
        == DisplayCardsViewport.unmeasuredHeight
    )
  }

  @Test("The fallback is a plausible single card, never zero and never over the cap")
  func theFallbackIsOneCardish() {
    // Derived from the slider's own row so it tracks the card it is standing in for. If it ever
    // exceeded the cap, the very first pass would draw a popover taller than the list may go.
    #expect(DisplayCardsViewport.unmeasuredHeight > BrightnessSliderMetrics.hitHeight)
    #expect(DisplayCardsViewport.unmeasuredHeight < DisplayCardsViewport.maximumHeight)
  }

  @Test("The cap leaves room for more than one card, or the list could never show two")
  func theCapFitsSeveralCards() {
    // The reported defect was a second card that could not be reached. A cap below two cards
    // would make that permanent rather than accidental.
    #expect(DisplayCardsViewport.maximumHeight >= DisplayCardsViewport.unmeasuredHeight * 3)
  }
}
