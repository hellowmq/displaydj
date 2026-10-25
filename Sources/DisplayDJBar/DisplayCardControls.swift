import AppKit
import SwiftUI

// The smaller controls a display card is built from, moved out of
// `DisplayBarView.swift` when that file crossed the length limit.
//
// `MiniAdjustButton` lived here until R2 removed the step row it belonged to. It was a 26pt
// wide button with a 10pt glyph — a 416pt² hit area, 53% of the 784pt² macOS asks for — and
// there were six of them per card. Every step it offered is still reachable: arrow keys on the
// focused slider, the menu bar wheel, and the hotkey.

// MARK: - Compact Readout

/// A small inline brightness value for the card header, replacing the old large readout.
///
/// Every glyph here comes from `BrightnessFormatting`. Spelling the unit inline instead
/// would let one readout keep the `%` while another quietly drops it, which is the exact
/// drift the shared formatter exists to prevent.
struct BrightnessReadout: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let value: Int?

  private var hasReading: Bool { BrightnessFormatting.showsUnit(for: value) }

  /// Fixed width so the header never reflows as the digit count swings between `9`, `99` and
  /// `100` mid-slide. The readout sits next to the display's action menu; a
  /// variable-width number would slide left and right under the finger and nudge the name off
  /// the leading edge. Sized to the widest value (`"100"` plus the `%` glyph, the semibold
  /// face it is drawn in) and right-aligned so the digits always hug the action menu rather
  /// than the name.
  private static let maxWidth: CGFloat = {
    let digitsFont = NSFont.monospacedSystemFont(ofSize: 18, weight: .semibold)
    let unitFont = roundedFont(size: 11, weight: .medium)
    let digits = (BrightnessFormatting.readoutDigits(for: 100) as NSString)
      .size(withAttributes: [.font: digitsFont]).width
    let unit = (BrightnessFormatting.unitSuffix as NSString)
      .size(withAttributes: [.font: unitFont]).width
    return ceil(digits + 1 + unit)
  }()

  /// Matches the rounded unit suffix; the digits use a separate monospaced face.
  private static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
    return NSFont(descriptor: descriptor, size: size) ?? base
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 1) {
      Text(BrightnessFormatting.readoutDigits(for: value))
        .font(.system(size: 18, weight: hasReading ? .semibold : .medium, design: .monospaced))
        .foregroundColor(hasReading ? .primary : .secondary)

      if hasReading {
        Text(BrightnessFormatting.unitSuffix)
          .font(.system(size: 11, weight: .medium, design: .rounded))
          .foregroundColor(.secondary)
      }
    }
    .contentTransition(reduceMotion ? .identity : .numericText())
    .frame(width: Self.maxWidth, alignment: .trailing)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(BrightnessAccessibility.currentBrightnessLabel)
    .accessibilityValue(BrightnessAccessibility.valueDescription(for: value))
  }
}
