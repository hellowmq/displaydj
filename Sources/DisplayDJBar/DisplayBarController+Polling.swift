import DisplayDJCore
import Foundation

// MARK: - Polling

extension DisplayBarController {

  /// Reads one display, named explicitly.
  ///
  /// Every card shows its own reading, so a read is addressed to a display rather than to
  /// "the current one". Passing the target in means the result and any failure can onlyever
  /// land on the monitor that was actually read, whatever the user selects meanwhile.
  ///
  /// The trigger is passed in rather than assumed, because the popover gate answers only for
  /// reads whose result is drawn on a card. A hotkey press is a read request from outside the
  /// popover entirely, and refusing it here is what left the shortcut doing nothing.
  ///
  /// The intent test is per display for the same reason the target is. It used to ask whether
  /// *anybody* had a value queued, which a drag makes true on every frame — so while one card
  /// was being steered, a read aimed at any other card was refused. Selecting a second display
  /// mid-drag left it on a placeholder, and a failed card's retry button did nothing at all,
  /// because the recovery path clears the banner before re-reading and the read never ran.
  func refreshDisplay(stableID: String, trigger: ReadTrigger = .popoverContent) async {
    guard trigger.allowsRead(popoverIsVisible: popoverIsVisible) else { return }
    switch TargetedRead.decision(
      stableID: stableID,
      writeInFlight: intents.isDraining,
      targetHasPendingIntent: intents.latestValue(for: stableID) != nil
    ) {
    case .unaddressable:
      // No stable ID means no card to file this against, so it is a topology-level problem.
      failures.topology = BrightnessFailurePresenter.noStableIdentity
      return
    case .laneBusy, .steering:
      return
    case .proceed:
      break
    }
    refreshTask?.cancel()
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      // The token, not a bare flag: this read may be superseded before it unwinds, and a
      // departing read must not report the lane idle while its replacement is still on it.
      let token = beginRead()
      defer { endRead(token) }
      await read(stableID: stableID)
    }
    refreshTask = task
    await task.value
  }

  /// Reads whatever the triggering event invalidated.
  ///
  /// The scope is decided by the caller's own event — a rescan invalidates every card, a focus
  /// change invalidates one — rather than inferred here from the selection. Inferring it is the
  /// cross-display mistake this module keeps having to undo: the operation knows which displays
  /// it concerns, and asking global focus state instead makes it act on the wrong ones.
  func refresh(scope: RefreshScope) async {
    switch scope {
    case .allDisplays:
      await refreshAllDisplays()
    case .singleDisplay(let stableID):
      await refreshDisplay(stableID: stableID)
    case .nothing:
      break
    }
  }

  /// Reads the selected display, reporting a display that cannot be addressed at all.
  func refreshCurrentDisplay() async {
    guard let display = selectedDisplay else { return }
    guard let stableID = display.stableID, !stableID.isEmpty else {
      noteUnaddressable(display)
      return
    }
    await refresh(scope: .afterSelectionChange(stableID: stableID))
  }

  /// Reads the selected display because the user asked for something that needs its value.
  ///
  /// Distinct from `refreshCurrentDisplay` in one respect only: it is not subject to the
  /// popover gate. That gate exists to stop unattended background polling, and a read that
  /// happens because the user pressed a key is neither unattended nor background — it is a
  /// single read with a consumer waiting on it.
  ///
  /// Also re-enumerates when the display list is empty. Nothing populates `displays` except
  /// `scanAndRefresh`, and until this round the only caller was `popoverDidShow`, so a hotkey
  /// pressed in a session where the popover had never been opened had no topology to resolve
  /// a target against.
  func refreshSelectedDisplayOnDemand() async {
    if displays.isEmpty {
      await scanAndRefresh()
    }
    guard let display = selectedDisplay else { return }
    guard let stableID = display.stableID, !stableID.isEmpty else {
      noteUnaddressable(display)
      return
    }
    await refreshDisplay(stableID: stableID, trigger: .userRequest)
  }

  /// Explains a card whose display cannot be addressed at all.
  ///
  /// Filed against that display's own card rather than the topology row. The condition
  /// belongs to one monitor — its neighbours are fine — and with several cards on screen a
  /// shared banner could not say which one it meant. It is keyed by `selectionKey` because
  /// the display has no stable ID to be keyed by; that is the whole problem.
  ///
  /// Saying it at all is the point. Every control on such a card is disabled and its readout
  /// is a placeholder, so without this the user sees a monitor that is simply inert, with
  /// nothing on screen accounting for it.
  func noteUnaddressable(_ display: DisplayDescriptor) {
    setFailure(BrightnessFailurePresenter.noStableIdentity, for: display.selectionKey)
  }

  /// Reads brightness from every physical display in the current topology.
  ///
  /// Registered as `refreshTask` like the single-display read, because it is the only path
  /// the polling timer takes and it is by far the longest: one DDC read per attached display,
  /// hundreds of milliseconds each. Left unregistered, `popoverDidClose` had nothing to
  /// cancel and the pass kept reading hardware after the popover was dismissed — the polling
  /// the lifecycle rules exist to stop — while also colliding with a user-initiated read on
  /// the same hardware lane, since only one of the two was ever cancellable.
  func refreshAllDisplays() async {
    guard popoverIsVisible else { return }
    guard !intents.isDraining, !intents.hasPending else { return }

    refreshTask?.cancel()
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      let token = beginRead()
      defer { endRead(token) }
      await readAllDisplays()
    }
    refreshTask = task
    await task.value
  }

  /// Walks the attached displays, re-checking between each one.
  ///
  /// The conditions are re-tested per display rather than only at the entrance: a pass
  /// outlives them often, so by the time the second display is reached the popover may be
  /// closed, the pass superseded, or the user may have started steering a card. The write
  /// state in particular is re-read here rather than captured, because a pass that began on
  /// an idle lane routinely finds a write underway partway through.
  private func readAllDisplays() async {
    for display in displays {
      guard
        ReadPass.shouldContinue(
          popoverIsVisible: popoverIsVisible,
          isCancelled: Task.isCancelled,
          userIsWriting: isWriting || intents.isDraining || intents.hasPending
        )
      else { return }
      switch ReadPass.step(
        stableID: display.stableID,
        hasPendingIntent: intents.latestValue(for: display.stableID ?? "") != nil
      ) {
      case .read(let stableID):
        await read(stableID: stableID)
      case .steering:
        // The user's own newer intent outranks anything the hardware would report, and it
        // resolves itself the moment the write lands. Nothing to say.
        continue
      case .unaddressable:
        // Not a silent `continue`. This card's controls are disabled and its readout is a
        // placeholder permanently, not just for this pass, so passing over it without a word
        // leaves an inert monitor on screen with nothing accounting for it.
        noteUnaddressable(display)
      }
    }
  }

  /// The single place a reading is taken and applied.
  ///
  /// Both entry points share it so the success and failure handling cannot drift apart —
  /// previously the whole-topology loop discarded a failing display's stale reading nowhere
  /// and reported nothing unless the display happened to be selected.
  private func read(stableID: String) async {
    do {
      let value = try await brightnessAccess.read(stableID: stableID)
      applyReadValue(value, stableID: stableID)
      // This display now has a good reading, so its own banner is stale. Every other
      // display's banner is untouched: succeeding here says nothing about them.
      clearFailure(for: stableID)
    } catch {
      // Cancelling a superseded read, or closing the popover mid-read, is this app's own
      // routine bookkeeping — not something the display did. Surfacing it would accuse a
      // healthy monitor of failing, and discarding the reading below would disable its `±`
      // buttons, so the last known value stands until a real read replaces it.
      if BrightnessFailurePresenter.isCancellation(error) { return }
      // A stale number is worse than none: it claims a reading that no longer holds.
      if intents.latestValue(for: stableID) == nil {
        setBrightnessForDisplay(nil, id: stableID)
      }
      // Filed against the display that actually failed, so the polling loop can report on
      // several displays in one pass without the later ones erasing the earlier ones.
      setFailure(
        BrightnessFailurePresenter.failure(
          for: error,
          operation: .read(displayStableID: stableID)
        ),
        for: stableID
      )
    }
  }

  /// Applies a fresh reading unless the user has expressed a newer intent for that display.
  private func applyReadValue(_ value: Int, stableID: String) {
    guard intents.latestValue(for: stableID) == nil else { return }
    setBrightnessForDisplay(value, id: stableID)
  }
}
