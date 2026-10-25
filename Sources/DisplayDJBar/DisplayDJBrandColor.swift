import SwiftUI

/// Runtime color tokens shared by the menu-bar interface.
///
/// The source of truth for their meaning is `docs/BRAND.md`; keeping the RGB value here once
/// prevents the slider, focus ring and selected-card treatment from drifting apart.
enum DisplayDJBrandColor {
  static let controlAccent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(red: 85.0/255, green: 217.0/255, blue: 1, alpha: 1)
      : NSColor(red: 0, green: 0.38, blue: 0.52, alpha: 1)
  })
  static let spectralCyan = Color(
    red: 85.0 / 255.0,
    green: 217.0 / 255.0,
    blue: 255.0 / 255.0
  )
}
