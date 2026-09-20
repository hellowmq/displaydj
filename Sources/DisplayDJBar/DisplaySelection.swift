import DisplayDJCore

/// Which *display* the user picked — never "the n-th element of an array".
///
/// Array positions change whenever a display is plugged, unplugged, or re-enumerated,
/// so an index-based selection silently slides onto a different monitor. This model
/// keeps an identity key instead and re-resolves it against every fresh topology.
struct DisplaySelection: Equatable {
  /// Identity of the currently selected display, or `nil` when nothing is selected.
  private(set) var selectedKey: String?

  init(selectedKey: String? = nil) {
    self.selectedKey = selectedKey
  }

  // MARK: - Identity

  /// The key a display is tracked by.
  ///
  /// AColorSync/hardware stable ID is used whenever the Core layer produced one.
  /// Displays without a stable identity cannot be controlled anyway, so they fall back
  /// to a clearly namespaced runtime key that is never persisted and never mistaken
  /// for a stable identity.
  static func identityKey(for display: DisplayDescriptor) -> String {
    if let stableID = display.stableID, !stableID.isEmpty {
      return stableID
    }
    return runtimeKeyPrefix + String(display.runtimeID)
  }

  static let runtimeKeyPrefix = "runtime:"

  /// Whether the key denotes a genuinely stable identity rather than a runtime fallback.
  static func isStableIdentity(_ key: String) -> Bool {
    !key.hasPrefix(runtimeKeyPrefix)
  }

  // MARK: - Resolution

  /// Position of the selected display in the given topology, or `nil` if it is absent.
  func index(in displays: [DisplayDescriptor]) -> Int? {
    guard let selectedKey else { return nil }
    return displays.firstIndex { Self.identityKey(for: $0) == selectedKey }
  }

  /// The selected display in the given topology, or `nil` if it is absent.
  func display(in displays: [DisplayDescriptor]) -> DisplayDescriptor? {
    guard let index = index(in: displays) else { return nil }
    return displays[index]
  }

  /// The stable ID of the selected display, or `nil` when it is gone or has no stable ID.
  func stableID(in displays: [DisplayDescriptor]) -> String? {
    display(in: displays)?.stableID
  }

  // MARK: - Mutation

  /// Selects a display by identity key. Unknown keys are rejected so the selection can
  /// never point at something the current topology does not contain.
  @discardableResult
  mutating func select(key: String, in displays: [DisplayDescriptor]) -> Bool {
    guard displays.contains(where: { Self.identityKey(for: $0) == key }) else { return false }
    selectedKey = key
    return true
  }

  /// Re-resolves the selection against a freshly enumerated topology.
  ///
  /// Priority, highest first:
  /// 1. the display that is currently selected, if it is still attached;
  /// 2. the remembered display from a previous launch, if it is attached;
  /// 3. the first attached display.
  ///
  /// Returns `true` when the resulting selection points at a different display than before.
  @discardableResult
  mutating func reconcile(
    with displays: [DisplayDescriptor],
    remembered rememberedKey: String? = nil
  ) -> Bool {
    let previousKey = selectedKey

    if displays.isEmpty {
      selectedKey = nil
      return previousKey != nil
    }

    let attachedKeys = displays.map(Self.identityKey(for:))

    if let selectedKey, attachedKeys.contains(selectedKey) {
      return false
    }

    if let rememberedKey, attachedKeys.contains(rememberedKey) {
      selectedKey = rememberedKey
    } else {
      selectedKey = attachedKeys[0]
    }

    return selectedKey != previousKey
  }
}

extension DisplayDescriptor {
  /// Identity used by the menu bar UI for selection and `ForEach` diffing.
  var selectionKey: String {
    DisplaySelection.identityKey(for: self)
  }
}
