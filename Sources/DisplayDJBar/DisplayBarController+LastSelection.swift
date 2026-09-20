import DisplayDJCore
import SwiftUI

extension DisplayBarController {
  // MARK: - Persistence of last selection

  private static let lastSelectedDisplayIDKey = "DisplayDJBar.LastSelectedDisplayStableID"

  /// Only genuinely stable identities are persisted; a runtime fallback key is
  /// meaningless in a later launch and must never be restored.
  func saveLastSelectedDisplay() {
    guard let key = selection.selectedKey, DisplaySelection.isStableIdentity(key) else { return }
    UserDefaults.standard.set(key, forKey: Self.lastSelectedDisplayIDKey)
  }

  var rememberedDisplayKey: String? {
    UserDefaults.standard.string(forKey: Self.lastSelectedDisplayIDKey)
  }
}
