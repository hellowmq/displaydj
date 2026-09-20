import CoreGraphics
import Testing

@testable import DisplayDJBar

/// R2's geometry, stated as criteria rather than left as literals in a view body.
///
/// The card was cut down to two controls — the track and the power button — and the track's
/// acceptance criterion was that it stop looking like a progress bar. "Significantly thicker"
/// and "actually hittable" are numbers, and these tests are where they are written down: the
/// next refactor that finds `13` untidy has to delete a failing test rather than quietly shrink
/// the only control a card still has.
@Suite("Brightness slider geometry")
struct BrightnessSliderMetricsTests {

  @Test("The track is thicker than the hairline it replaced, and inside the reviewed band")
  func trackIsVisiblyThicker() {
    // 5pt was thin enough to read as a value indicator while the six `±` buttons below it read
    // as the control. Both ends are asserted so the number cannot drift back down a little at a
    // time, and cannot grow into a banner either.
    #expect(BrightnessSliderMetrics.trackHeight > 5)
    #expect(BrightnessSliderMetrics.trackHeight >= 12)
    #expect(BrightnessSliderMetrics.trackHeight <= 16)
  }

  @Test("The pointer's row meets the minimum target height, and the bar is not the target")
  func hitRowMeetsTheMinimumTarget() {
    // 28×28 is the smallest target macOS expects a control to offer. The bar is a third of the
    // row on purpose: a pointer aimed at a 13pt bar lands on the padding as often as on the
    // paint, and that padding is the slider's.
    #expect(BrightnessSliderMetrics.hitHeight >= 28)
    #expect(BrightnessSliderMetrics.hitHeight > BrightnessSliderMetrics.trackHeight)
  }

  @Test("The thumb fits inside the row it is drawn in")
  func thumbFitsInItsRow() {
    // A 22pt knob in a shorter row is clipped top and bottom — on what is now the card's
    // primary control, and exactly while the user is dragging it.
    #expect(BrightnessSliderMetrics.thumbSize <= BrightnessSliderMetrics.hitHeight)
  }

  @Test("The thumb is not smaller than the track it sits on")
  func thumbIsNotSmallerThanTheTrack() {
    // The knob has to read as the thing being moved. Once the bar is at thumb scale, a knob
    // narrower than the bar turns the control back into a slider with a bead on a plank.
    #expect(BrightnessSliderMetrics.thumbSize >= BrightnessSliderMetrics.trackHeight)
  }

  @Test("The focus ring fits inside the row, so keyboard focus is never clipped")
  func focusRingFitsInItsRow() {
    // The ring is the only thing that tells a keyboard user the arrow keys will do something.
    // Drawn taller than its row it is cut off on the one occasion it exists for.
    #expect(BrightnessSliderMetrics.focusRingHeight > BrightnessSliderMetrics.trackHeight)
    #expect(BrightnessSliderMetrics.focusRingHeight <= BrightnessSliderMetrics.hitHeight)
  }
}
