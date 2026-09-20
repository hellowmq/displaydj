import DisplayDJCore
import Testing

@testable import DisplayDJBar

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

private let hpDisplay = display(runtimeID: 2, stableID: hpStableID, name: "HP D27k")
private let philipsDisplay = display(runtimeID: 3, stableID: philipsStableID, name: "PHL 278B1")

@Test("A display with a stable ID is keyed by that identity, not by position")
func selectionKeyPrefersStableIdentity() {
  #expect(DisplaySelection.identityKey(for: hpDisplay) == hpStableID)
  #expect(DisplaySelection.isStableIdentity(hpStableID))
}

@Test("A display without a stable ID gets a namespaced runtime key")
func selectionKeyFallsBackToNamespacedRuntimeID() {
  let unknown = display(runtimeID: 7, stableID: nil, name: "Unknown")
  let key = DisplaySelection.identityKey(for: unknown)

  #expect(key == "runtime:7")
  #expect(DisplaySelection.isStableIdentity(key) == false)
}

@Test("An empty stable ID is not treated as an identity")
func selectionKeyRejectsEmptyStableID() {
  let blank = display(runtimeID: 9, stableID: "", name: "Blank")

  #expect(DisplaySelection.identityKey(for: blank) == "runtime:9")
}

@Test("Reconciling an empty selection picks the first attached display")
func selectionReconcileSelectsFirstWhenUnset() {
  var selection = DisplaySelection()

  let changed = selection.reconcile(with: [philipsDisplay, hpDisplay])

  #expect(changed)
  #expect(selection.selectedKey == philipsStableID)
}

@Test("Reconciling prefers the remembered display over the first one")
func selectionReconcilePrefersRememberedDisplay() {
  var selection = DisplaySelection()

  selection.reconcile(with: [philipsDisplay, hpDisplay], remembered: hpStableID)

  #expect(selection.selectedKey == hpStableID)
}

@Test("A remembered display that is not attached does not win")
func selectionReconcileIgnoresAbsentRememberedDisplay() {
  var selection = DisplaySelection()

  selection.reconcile(with: [philipsDisplay], remembered: hpStableID)

  #expect(selection.selectedKey == philipsStableID)
}

@Test("Reordering the topology keeps the selection on the same physical display")
func selectionSurvivesTopologyReordering() {
  var selection = DisplaySelection()
  selection.select(key: hpStableID, in: [philipsDisplay, hpDisplay])
  #expect(selection.index(in: [philipsDisplay, hpDisplay]) == 1)

  // The user unplugs and replugs, and the HP now enumerates first.
  let reordered = [hpDisplay, philipsDisplay]
  let moved = selection.reconcile(with: reordered)

  #expect(moved == false)
  #expect(selection.selectedKey == hpStableID)
  #expect(selection.index(in: reordered) == 0)
  #expect(selection.display(in: reordered)?.name == "HP D27k")
}

@Test("Removing an unselected display does not move the selection")
func selectionUnaffectedByRemovingOtherDisplay() {
  var selection = DisplaySelection()
  selection.select(key: hpStableID, in: [philipsDisplay, hpDisplay])

  let moved = selection.reconcile(with: [hpDisplay])

  #expect(moved == false)
  #expect(selection.selectedKey == hpStableID)
}

@Test("Unplugging the selected display moves the selection and reports the change")
func selectionReportsMoveWhenSelectedDisplayDisappears() {
  var selection = DisplaySelection()
  selection.select(key: hpStableID, in: [philipsDisplay, hpDisplay])

  let moved = selection.reconcile(with: [philipsDisplay])

  #expect(moved)
  #expect(selection.selectedKey == philipsStableID)
}

@Test("An empty topology clears the selection")
func selectionClearsWhenNoDisplaysRemain() {
  var selection = DisplaySelection()
  selection.select(key: hpStableID, in: [hpDisplay])

  let moved = selection.reconcile(with: [])

  #expect(moved)
  #expect(selection.selectedKey == nil)
  #expect(selection.index(in: []) == nil)
  #expect(selection.stableID(in: []) == nil)
}

@Test("Selecting an unknown key is rejected")
func selectionRejectsUnknownKey() {
  var selection = DisplaySelection()
  selection.select(key: hpStableID, in: [hpDisplay])

  let accepted = selection.select(key: "uuid:does-not-exist", in: [hpDisplay])

  #expect(accepted == false)
  #expect(selection.selectedKey == hpStableID)
}

@Test("The selected stable ID resolves through the current topology")
func selectionResolvesStableIDForCurrentTopology() {
  var selection = DisplaySelection()
  selection.select(key: hpStableID, in: [philipsDisplay, hpDisplay])

  #expect(selection.stableID(in: [philipsDisplay, hpDisplay]) == hpStableID)
  // Same identity, different array position.
  #expect(selection.stableID(in: [hpDisplay, philipsDisplay]) == hpStableID)
  // Gone: no stable ID to control.
  #expect(selection.stableID(in: [philipsDisplay]) == nil)
}

@Test("A display without a stable identity is selectable but exposes no stable ID")
func selectionHandlesDisplayWithoutStableIdentity() {
  let unknown = display(runtimeID: 7, stableID: nil, name: "Unknown")
  var selection = DisplaySelection()

  let accepted = selection.select(key: "runtime:7", in: [unknown])

  #expect(accepted)
  #expect(selection.stableID(in: [unknown]) == nil)
  #expect(selection.display(in: [unknown])?.name == "Unknown")
}
