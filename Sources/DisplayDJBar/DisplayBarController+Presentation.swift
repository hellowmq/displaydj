import AppKit
import DisplayDJCore
import SwiftUI

extension DisplayBarController {
  // MARK: - Display presentation (aliases & order)

  /// The name a card shows for a display: the user's alias when set, else the system name.
  func alias(for display: DisplayDescriptor) -> String {
    DisplayAliasResolver.title(
      for: display.name,
      stableID: display.stableID,
      aliases: preferences.aliases
    )
  }

  /// Sets or clears the alias for a display, keyed by stable ID so it follows the monitor.
  ///
  /// A display with no stable identity cannot be aliased — its key would not survive a
  /// replug. An empty alias clears the entry rather than storing whitespace. Reassigned as a
  /// whole so the `@Published` wrapper fires and the card redraws with the new title.
  func setAlias(_ alias: String, forStableID stableID: String) {
    guard !stableID.isEmpty else { return }
    var next = preferences
    if let normalized = DisplayAliasResolver.normalize(alias) {
      next.aliases[stableID] = normalized
    } else {
      next.aliases[stableID] = nil
    }
    preferences = next
    persistPreferences()
  }

  /// Removes any alias for a display.
  func clearAlias(forStableID stableID: String) {
    guard !stableID.isEmpty else { return }
    var next = preferences
    next.aliases.removeValue(forKey: stableID)
    preferences = next
    persistPreferences()
  }

  /// Sorts displays by the user's chosen order: manual order when set, else
  /// physical left-to-right position derived from the screen geometry.
  ///
  /// Internal rather than `private` because `scanAndRefresh` and the reorder methods live in
  /// the primary file and call it across a file boundary.
  func orderedDisplays(_ displays: [DisplayDescriptor]) -> [DisplayDescriptor] {
    DisplayOrdering.resolve(
      displays: displays,
      manualOrder: preferences.manualOrder,
      physicalMinXById: physicalMinXById()
    )
  }

  /// Maps each display's runtime ID to the left edge of its screen, in points.
  ///
  /// Screen frames are Cocoa (origin bottom-left), but only the X axis is used for ordering,
  /// so the Y flip is irrelevant. A display with no screen entry mid-reconfiguration is simply
  /// absent from the map and sorts last.
  private func physicalMinXById() -> [UInt32: Double] {
    var map: [UInt32: Double] = [:]
    for screen in NSScreen.screens {
      guard
        let number = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber
      else { continue }
      map[number.uint32Value] = screen.frame.minX
    }
    return map
  }

  func loadPreferences() {
    do {
      preferences = try preferencesStore.loadPreferences()
    } catch {
      // Non-fatal: a missing or corrupt file just means "no preferences yet".
      preferences = .empty
    }
  }

  /// Internal rather than `private` because the reorder methods that call it live in the
  /// primary file and cross a file boundary.
  func persistPreferences() {
    do {
      try preferencesStore.savePreferences(preferences)
    } catch {
      // Non-fatal: the in-memory copy still drives the UI this session.
    }
  }
}
