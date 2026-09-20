/// How much of the display list a refresh has to cover.
///
/// A refresh follows one of two events, and they are not the same size. Re-enumerating the
/// topology invalidates *every* card: each one draws its own reading and its own `±` buttons,
/// and a card without a reading shows a placeholder and disables those buttons. Changing which
/// card has focus invalidates only the card that gained it — every other reading is still true.
///
/// Deriving the scope from the event rather than from the selection is the whole point. A
/// whole-topology rescan that finished by reading "the current display" left every other card
/// blank until an unrelated timer happened to fill it in, which is the same defect as a retry
/// that resolves its target from the selection instead of carrying it: the operation knew which
/// displays it concerned, and then asked global focus state instead.
///
/// Split out as plain values so the decision can be tested without a running status item.
enum RefreshScope: Equatable {
  /// Read every attached display.
  case allDisplays
  /// Read one named display.
  case singleDisplay(stableID: String)
  /// There is nothing addressable to read.
  ///
  /// Deliberately not named `none`: as `RefreshScope?` it would collide with `Optional.none`
  /// and silently swallow a branch in every `switch`.
  case nothing

  /// The refresh that follows a fresh enumeration of the attached displays.
  ///
  /// Always the whole list, because a rescan says nothing about any individual card and every
  /// card needs a reading to be usable. The selection deliberately plays no part: which display
  /// has focus has no bearing on whether the *others* still have valid readings, and after a
  /// rescan they do not.
  static func afterTopologyChange(attachedDisplays: Int) -> RefreshScope {
    attachedDisplays > 0 ? .allDisplays : .nothing
  }

  /// The refresh that follows a change of focus.
  ///
  /// One display, named explicitly rather than resolved later. The other cards kept their
  /// readings, so re-reading them would spend a DDC round trip each to confirm what is already
  /// on screen — and would contend for the same hardware lane while doing it.
  static func afterSelectionChange(stableID: String?) -> RefreshScope {
    guard let stableID, !stableID.isEmpty else { return .nothing }
    return .singleDisplay(stableID: stableID)
  }
}
