import DisplayDJCore

// MARK: - Write

extension DisplayBarController {

  /// Applies a relative step to the selected display, on behalf of the hotkeys.
  ///
  /// Unlike the card's `±` buttons, this runs with the popover closed, which is the whole
  /// point of a shortcut — and in that state there may be no reading to step from. Polling is
  /// deliberately stopped while the popover is shut, and if it was never opened this session
  /// the display list is empty too, so `displayedBrightness` is routinely `nil` exactly when
  /// the hotkey is used. Returning on that `nil`, as the card path does, made the feature the
  /// user opted into silently do nothing — the same silent discard the intent buffer exists to
  /// prevent, arriving through the one entrance that has no button to grey out and no card to
  /// show a banner on.
  ///
  /// So a missing starting point is fetched rather than treated as a refusal. The read is
  /// awaited before stepping because a relative change is meaningless without it.
  func adjustBrightnessViaHotkey(by delta: Int) async {
    if displayedBrightness == nil {
      await refreshSelectedDisplayOnDemand()
    }
    guard let stableID = selectedStableID, !stableID.isEmpty else { return }
    adjustBrightness(by: delta, for: stableID)
  }

  func adjustBrightness(by delta: Int, for stableID: String) {
    guard let current = displayedBrightness(for: stableID) else { return }
    let target = BrightnessAccessibility.adjusted(current, by: delta)
    guard target != current else { return }
    Task { await setBrightness(target, for: stableID) }
  }

  func setBrightness(_ value: Int, for stableID: String) async {
    guard !displays.isEmpty else { return }
    guard !stableID.isEmpty else {
      failures.topology = BrightnessFailurePresenter.noStableIdentity
      return
    }

    let target = BrightnessAccessibility.clamp(value)
    intents.submit(BrightnessIntent(value: target, displayStableID: stableID))
    setIntendedForDisplay(target, id: stableID)
    // Starting a write on this display supersedes only this display's own banner. Banners
    // are filed per display, so a nudge on one card can no longer erase a neighbour's error
    // before the user has read it, along with the retry button that was the way out of it.
    clearFailure(for: stableID)

    if let existing = writeTask {
      await existing.value
      return
    }

    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await drainIntents()
    }
    writeTask = task
    await task.value
  }

  // `setBrightness(_:)` and `adjustBrightness(by:)` — the selection-resolving siblings of the
  // two calls above — were removed once the last caller went away. Both inferred their target
  // from `selectedStableID` at the moment the write ran, which is the cross-display mistake
  // this module keeps having to undo: any card can be adjusted without being selected, so a
  // value aimed at one monitor could land on another if the selection moved in between. The
  // targeted forms make the caller name the display, and the compiler now enforces it.

  private func drainIntents() async {
    isWriting = true
    while let intent = intents.beginNext() {
      await performWrite(intent)
      intents.finishActive()
      // Retire only the intent just written, and only if the user has not already queued a
      // newer one for that same display. The loop can still be carrying intents for other
      // displays, and clearing the whole map would drop their pending values back to the
      // last confirmed reading — the cards would visibly snap backwards mid-drain.
      if intents.latestValue(for: intent.displayStableID) == nil {
        setIntendedForDisplay(nil, id: intent.displayStableID)
      }
    }
    isWriting = false
    writeTask = nil
  }

  private func performWrite(_ intent: BrightnessIntent) async {
    setIntendedForDisplay(intent.value, id: intent.displayStableID)

    // Skip a write that would change nothing. Whether the display happens to be *selected*
    // has no bearing on whether its brightness already equals the target, so it is not part
    // of the test — including it made every unselected card re-send a value it already had.
    if intent.value == brightnessByID[intent.displayStableID] { return }

    do {
      let verified = try await brightnessAccess.write(
        percent: Double(intent.value),
        stableID: intent.displayStableID
      )
      // A write started before a rescan can land after it. Filing its reading against a
      // display the topology no longer contains would re-create the very entry the prune
      // just removed — invisible state with no card, waiting to reappear on replug.
      guard !intents.isActiveOrphaned else { return }
      setBrightnessForDisplay(verified, id: intent.displayStableID)
      // Succeeding on one display resolves only that display's banner; every other card's
      // failure is still unresolved and keeps its retry button.
      clearFailure(for: intent.displayStableID)
    } catch {
      // Deliberately *not* filtered for cancellation, unlike the read path. Writes are never
      // cancelled by this app, and Core only raises a bare `CancellationError` here after it
      // has verified the baseline was restored. Anything else that mentions cancellation is
      // a DisplayDJError meaning the restoration itself failed — the display may be holding
      // a value the user never asked for, which is precisely when they must be told.
      //
      // A banner for a departed display is the one exception, and for the opposite reason:
      // there is no card to draw it on, so it would not be shown at all — it would only sit
      // in the store waiting to surface on a monitor the user has since plugged back in.
      guard !intents.isActiveOrphaned else { return }
      setFailure(
        BrightnessFailurePresenter.failure(
          for: error,
          operation: .write(value: intent.value, displayStableID: intent.displayStableID)
        ),
        for: intent.displayStableID
      )
    }
  }
}
