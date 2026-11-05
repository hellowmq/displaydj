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

  var body: some View {
    ZStack(alignment: .trailing) {
      // Prototype view: naturally measures the maximum boundary for "100%" using the exact font
      // metrics of the current system, avoiding any hardcoded magic numbers while preventing header
      // reflow (jitter) as brightness varies between 0 and 100.
      prototypeRow
        .hidden()
        .accessibilityHidden(true)

      HStack(alignment: .firstTextBaseline, spacing: 1) {
        Text(BrightnessFormatting.readoutDigits(for: value))
          .font(.system(size: 18, weight: hasReading ? .semibold : .medium, design: .monospaced))
          .foregroundColor(hasReading ? .primary : .secondary)
          .lineLimit(1)

        if hasReading {
          Text(BrightnessFormatting.unitSuffix)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
      }
      .lineLimit(1)
      .contentTransition(reduceMotion ? .identity : .numericText())
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(BrightnessAccessibility.currentBrightnessLabel)
    .accessibilityValue(BrightnessAccessibility.valueDescription(for: value))
  }

  private var prototypeRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 1) {
      Text(BrightnessFormatting.readoutDigits(for: 100))
        .font(.system(size: 18, weight: .semibold, design: .monospaced))
        .lineLimit(1)
      Text(BrightnessFormatting.unitSuffix)
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .lineLimit(1)
    }
    .lineLimit(1)
  }
}
