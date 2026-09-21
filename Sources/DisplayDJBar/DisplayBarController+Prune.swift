import DisplayDJCore

/// Topology-change bookkeeping: what the controller forgets when a display goes away.
///
/// Kept in its own file so the list of per-display stores stays visible as a list. Buried
/// inside the controller it read as one more line of `scanAndRefresh`, and a store was
/// missed from it for exactly that reason.
extension DisplayBarController {
  /// Drops readings for displays that are no longer attached, keeping every attached one.
  ///
  /// Every attached display has its own card on screen, so a blanket reset would blank the
  /// neighbours' readings — and disable their `±` buttons — merely because one display was
  /// unplugged. Only entries the current topology can no longer explain are removed.
  ///
  /// Every per-display store has to be listed here, including the intent queue. Pruning the
  /// readings and the banners but not the intents left the one store that *writes the others
  /// back*: a value still queued for a departed display gets drained, and draining it records
  /// a reading — and possibly a failure — under a stable ID with no card, so the prune quietly
  /// undoes itself. It also sends that value to hardware the topology no longer lists.
  func pruneDisplayState(keeping attached: [DisplayDescriptor]) {
    let liveIDs = Set(attached.compactMap(\.stableID))
    // Banners are keyed differently from readings, so they get their own live set.
    //
    // A reading or an intent can only exist for a display that has a stable ID — that is what
    // addresses the hardware. A *banner* can also belong to a display that has none, because
    // "this monitor cannot be identified" is precisely the thing such a card has to say. Those
    // banners are filed under `selectionKey`, so pruning them against the stable IDs alone
    // would delete each one on the very next rescan, moments after it was written.
    let liveBannerKeys = liveIDs.union(attached.map(\.selectionKey))
    // Removal goes through the per-display setters rather than reassigning the dictionaries,
    // both because the readings' setter is file-private to the controller and because those
    // setters are the documented way to make `@Published` fire for a dictionary.
    for id in Array(brightnessByID.keys) where !liveIDs.contains(id) {
      setBrightnessForDisplay(nil, id: id)
    }
    for id in Array(intendedByID.keys) where !liveIDs.contains(id) {
      setIntendedForDisplay(nil, id: id)
    }
    readFailureCounts = readFailureCounts.filter { liveIDs.contains($0.key) }
    // A detached display's banner has no card left to live on, but every attached
    // display's banner is still true and must survive the rescan.
    failures.prune(keeping: liveBannerKeys)
    // Queued intents for departed displays are dropped outright; an already-running one is
    // left to Core's write/restore semantics and merely flagged, so its result is discarded
    // rather than filed against a display that is gone.
    intents.prune(keeping: liveIDs)
  }
}
