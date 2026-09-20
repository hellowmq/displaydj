import DisplayDJCore
import SwiftUI

extension DisplayBarController {
  // MARK: - Per-display brightness state

  /// What the UI shows for a given display: the newest user intent outranks the last
  /// confirmed value.
  func displayedBrightness(for stableID: String) -> Int? {
    intendedByID[stableID] ?? brightnessByID[stableID]
  }

  /// What the UI shows for the currently selected display. Hotkeys and the status bar
  /// read this path.
  var displayedBrightness: Int? {
    guard let id = selectedStableID else { return nil }
    return displayedBrightness(for: id)
  }

  /// The `brightnessByID` writer lives in the primary file because that property is
  /// `private(set)`; this extension only reads it. `intendedByID` is a plain `var`, so its
  /// writer can stay here.

  func setIntendedForDisplay(_ value: Int?, id: String) {
    var copy = intendedByID
    if let val = value { copy[id] = val } else { copy.removeValue(forKey: id) }
    intendedByID = copy
  }

  /// Whether an absolute brightness can be sent to a given display at all.
  ///
  /// Deliberately independent of whether a reading succeeded: a failed read must not lock
  /// the controls, otherwise the user loses the only path back exactly when they need it.
  func canControl(_ stableID: String) -> Bool {
    !stableID.isEmpty
  }

  /// Relative steps need a known starting point, so they — and only they — require a reading.
  ///
  /// The UI must consult this before offering a `±` button: `adjustBrightness` has no value
  /// to add to without a reading, so an enabled-looking button would silently do nothing.
  func canAdjustRelatively(_ stableID: String) -> Bool {
    canControl(stableID) && displayedBrightness(for: stableID) != nil
  }

  // Deliberately absent: no-argument `canControl` / `canAdjustRelatively` overloads that
  // resolved their target through `selectedStableID`. Every card in the popover is
  // adjustable without being selected, so "the selected display" is not the display the
  // caller is asking about — same defect family that removed `adjustBrightness(by:)`,
  // `setBrightness(_:)` and `var brightness`. Callers must name the display they mean.
  // Do not reintroduce them.
}
