/// Whether a card offers to become the selected display, and under which key.
///
/// Two separate mistakes met on this one gesture, and both are ones this module has already
/// had to fix elsewhere — just never on the *selection* path.
///
/// **The key.** Selection is stored, reconciled and rendered by `selectionKey`: the stable ID
/// when the display has one, and a namespaced `runtime:` key when it does not. The tap gesture
/// alone reached for `stableID` and refused when it was absent. So a display without a stable
/// identity could be selected *by the app* — `reconcile` picks the first attached display by
/// `identityKey`, runtime keys included — and would then draw its accent dot and announce
/// itself as selected, while the user could never select it, or re-select it after moving
/// away. The same key has to be used to write a selection, to read it back, and to prune it;
/// that has been true of the readings and the banners since round29, and this was the last
/// place still asking with a different one.
///
/// **The reach.** Selecting is a bare `onTapGesture`, which is a pointer and nothing else. The
/// card nevertheless declares `.isSelected` and carries a hint describing itself as a display
/// picker, so VoiceOver announces an affordance it is then given no way to operate, and
/// keyboard users get the same announcement and the same dead end. Selection used to be a real
/// `Picker`, which supplied that reach for free; it was lost with the layout change and nothing
/// replaced it. PRD 1.5 requires the controls to be operable, not merely described — an
/// announced control that only a mouse can reach is the more misleading half of that failure,
/// because it reads as supported.
///
/// Split out as a plain value for the same reason as `ReadPass`, `ReadTrigger`, `SliderStep`,
/// `TargetedRead` and `HotkeyObservers`: the rule can then be asserted directly, and both the
/// pointer path and the accessibility path can be made to consume the *same* decision rather
/// than each deciding for itself — which is how they came to disagree in the first place.
enum SelectDisplayAction: Equatable {
  /// Make this display the selected one, using this key.
  case select(key: String)
  /// This display is already selected; selecting it again would be a no-op.
  ///
  /// Deliberately distinct from "cannot": the card must still expose the action to assistive
  /// technology so its selected state is discoverable, and re-selecting must not re-read
  /// hardware. The controller's own `selectDisplay` guards against this too — this case exists
  /// so the view can tell the two apart without asking the controller.
  case alreadySelected

  /// Resolves what tapping — or activating via VoiceOver, or pressing return — should do.
  ///
  /// `selectionKey` is the parameter name on purpose. Taking a `stableID` here would let the
  /// original mismatch back in through the type: the caller would have to decide which key to
  /// supply, and the one it supplied was the wrong one.
  static func resolve(selectionKey: String, currentSelection: String?) -> SelectDisplayAction {
    guard selectionKey != currentSelection else { return .alreadySelected }
    return .select(key: selectionKey)
  }
}
