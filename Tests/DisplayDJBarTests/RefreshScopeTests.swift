import Testing

@testable import DisplayDJBar

/// A refresh must cover what its triggering event invalidated — no more, and crucially no less.
///
/// The defect these guard: `scanAndRefresh` re-enumerates the whole topology and then finished
/// by reading only the *selected* display. Every card renders its own reading and disables its
/// own `±` buttons without one, so on the first open — and after every rescan, replug or manual
/// refresh — every card except one showed `--` with its relative steps greyed out, until a
/// two-second poll happened to fill them in. The scan knew perfectly well which displays it had
/// just found; it asked the selection instead.
private let hpDisplay = "uuid:75490c7d-7258-479e-9bce-da9c8c60ac84"

// MARK: - After a topology change

@Test("A rescan reads every attached display, not just the selected one")
func topologyChangeReadsEveryDisplay() {
  // Two displays were found, so two cards are on screen and both need readings.
  #expect(RefreshScope.afterTopologyChange(attachedDisplays: 2) == .allDisplays)
  #expect(RefreshScope.afterTopologyChange(attachedDisplays: 5) == .allDisplays)
}

@Test("A single attached display is still read as a whole-topology pass")
func topologyChangeWithOneDisplayStillReadsAll() {
  // The scope follows the event, not the count. Special-casing one display would make the
  // one-monitor and two-monitor paths diverge for no reason.
  #expect(RefreshScope.afterTopologyChange(attachedDisplays: 1) == .allDisplays)
}

@Test("A rescan that finds nothing reads nothing")
func topologyChangeWithNoDisplaysReadsNothing() {
  // The empty state explains itself; there is no card to fill in.
  #expect(RefreshScope.afterTopologyChange(attachedDisplays: 0) == .nothing)
}

// MARK: - After a selection change

@Test("Moving focus reads only the display that gained it")
func selectionChangeReadsOneDisplay() {
  // The other cards kept their readings, so re-reading them would spend a DDC round trip
  // each to confirm what is already on screen, and contend for the same hardware lane.
  #expect(
    RefreshScope.afterSelectionChange(stableID: hpDisplay)
      == .singleDisplay(stableID: hpDisplay))
}

@Test("A selection that names no addressable display reads nothing")
func selectionChangeWithoutIdentityReadsNothing() {
  #expect(RefreshScope.afterSelectionChange(stableID: nil) == .nothing)
  #expect(RefreshScope.afterSelectionChange(stableID: "") == .nothing)
}

// MARK: - The two scopes are genuinely different

@Test("A topology change is never narrowed to a single display")
func topologyChangeIsNeverASingleDisplay() {
  // The regression in one line: a whole-topology refresh resolving to one display.
  let scope = RefreshScope.afterTopologyChange(attachedDisplays: 2)

  #expect(scope != .singleDisplay(stableID: hpDisplay))
  #expect(scope != .nothing)
}

@Test("A focus change is never widened to the whole topology")
func selectionChangeIsNeverAllDisplays() {
  // The opposite error would poll every monitor each time the user clicked a card.
  #expect(RefreshScope.afterSelectionChange(stableID: hpDisplay) != .allDisplays)
}
