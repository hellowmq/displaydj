import DisplayDJCore
import Testing

@testable import DisplayDJBar

// Selecting a display is the one interaction that had drifted away from the identity key the
// rest of the module settled on, and it had done so in two directions at once: the gesture
// asked for `stableID` while selection is stored under `selectionKey`, and the gesture was the
// only way in, so the card announced itself as selectable to assistive technology that could
// never activate it.
//
// Both halves are asserted here rather than in a UI test, because neither is observable from
// outside: a card with no stable identity looks like any other, and an unreachable
// accessibility action looks exactly like a present one.

private let hpStableID = "uuid:75490c7d-7258-479e-9bce-da9c8c60ac84"
private let philipsStableID = "uuid:11111111-2222-3333-4444-555555555555"

private func display(
  runtimeID: UInt32,
  stableID: String?,
  name: String
) -> DisplayDescriptor {
  DisplayDescriptor(
    runtimeID: runtimeID,
    stableID: stableID,
    name: name,
    isBuiltIn: false,
    isVirtual: false,
    isMirrored: false
  )
}

// MARK: - Key agreement

@Test("Selecting uses the same key selection is stored under")
func selectActionUsesSelectionKey() {
  let hpMonitor = display(runtimeID: 2, stableID: hpStableID, name: "HP D27k")

  let action = SelectDisplayAction.resolve(
    selectionKey: hpMonitor.selectionKey,
    currentSelection: philipsStableID
  )

  #expect(action == .select(key: hpStableID))
  // The key the action carries is exactly the one `DisplaySelection` resolves and stores.
  #expect(hpMonitor.selectionKey == DisplaySelection.identityKey(for: hpMonitor))
}

@Test("A display without a stable identity can still be selected by the user")
func selectActionAcceptsRuntimeKeyedDisplay() {
  // This is the case the old gesture refused. `reconcile` will happily select such a display
  // — it picks the first attached one by identity key — so the card would show its accent dot
  // and announce `.isSelected` while the user had no way to select it, or to return to it
  // after moving away.
  let unknown = display(runtimeID: 7, stableID: nil, name: "Unknown")

  let action = SelectDisplayAction.resolve(
    selectionKey: unknown.selectionKey,
    currentSelection: hpStableID
  )

  #expect(action == .select(key: "runtime:7"))
  #expect(DisplaySelection.isStableIdentity(unknown.selectionKey) == false)
}

@Test("An empty stableID selects by runtime key rather than by an empty string")
func selectActionRejectsEmptyStableIDAsKey() {
  // The old gesture guarded with `!key.isEmpty` and gave up. Falling through to the runtime
  // key is what keeps the card selectable, and it is also what stops an empty stringever
  // being written into the selection.
  let blank = display(runtimeID: 9, stableID: "", name: "Blank")

  let action = SelectDisplayAction.resolve(selectionKey: blank.selectionKey, currentSelection: nil)

  #expect(action == .select(key: "runtime:9"))
  #expect(action != .select(key: ""))
}

@Test("Every attached display is selectable, with or without a stable identity")
func selectActionCoversWholeTopology() {
  let displays = [
    display(runtimeID: 2, stableID: hpStableID, name: "HP D27k"),
    display(runtimeID: 3, stableID: philipsStableID, name: "PHL 278B1"),
    display(runtimeID: 7, stableID: nil, name: "Unknown"),
    display(runtimeID: 9, stableID: "", name: "Blank"),
  ]

  for candidate in displays {
    var selection = DisplaySelection()
    let action = SelectDisplayAction.resolve(
      selectionKey: candidate.selectionKey,
      currentSelection: nil
    )
    guard case .select(let key) = action else {
      Issue.record("\(candidate.name) offered no way to be selected")
      continue
    }
    // The key the action produced has to be one the selection model actually accepts;
    // that round trip is the whole contract between the two.
    let accepted = selection.select(key: key, in: displays)
    #expect(accepted)
    #expect(selection.selectedKey == candidate.selectionKey)
  }
}

// MARK: - Already selected

@Test("Re-selecting the current display is a no-op rather than a fresh selection")
func selectActionReportsAlreadySelected() {
  let hpMonitor = display(runtimeID: 2, stableID: hpStableID, name: "HP D27k")

  let action = SelectDisplayAction.resolve(
    selectionKey: hpMonitor.selectionKey,
    currentSelection: hpStableID
  )

  #expect(action == .alreadySelected)
}

@Test("A runtime-keyed display is also recognised as already selected")
func selectActionRecognisesAlreadySelectedRuntimeKey() {
  let unknown = display(runtimeID: 7, stableID: nil, name: "Unknown")

  let action = SelectDisplayAction.resolve(
    selectionKey: unknown.selectionKey,
    currentSelection: "runtime:7"
  )

  #expect(action == .alreadySelected)
}

@Test("Nothing selected yet still allows a selection")
func selectActionAllowsFirstSelection() {
  let hpMonitor = display(runtimeID: 2, stableID: hpStableID, name: "HP D27k")

  #expect(
    SelectDisplayAction.resolve(selectionKey: hpMonitor.selectionKey, currentSelection: nil)
      == .select(key: hpStableID)
  )
}

// MARK: - Reach

@Test("The selection action is named, so assistive technology can offer it")
func selectActionIsSpoken() {
  let label = BrightnessAccessibility.selectDisplayActionLabel

  #expect(label.trimmingCharacters(in: .whitespaces).isEmpty == false)
  // The hint says what the card *is*; the action says what can be *done* to it. A card that
  // announces `.isSelected` and offers no action describes a control only a pointer can use.
  #expect(label != BrightnessAccessibility.displayPickerLabel)
}
