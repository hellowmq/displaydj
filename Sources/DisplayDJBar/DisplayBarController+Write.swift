import DisplayDJCore
import OSLog

private let brightnessWriteLogger = Logger(
  subsystem: "io.github.hellowmq.displaydj", category: "BrightnessWrite"
)

// MARK: - Write

extension DisplayBarController {

  func adjustBrightness(by delta: Int, for stableID: String) {
    guard let current = displayedBrightness(for: stableID) else { return }
    let target = BrightnessAccessibility.adjusted(current, by: delta)
    guard target != current else { return }
    Task { await setBrightness(target, for: stableID) }
  }

  func setBrightness(_ value: Int, for stableID: String, synchronize: Bool = true,
                     showKeyboardFeedback: Bool = false, relativeSteps: [Int]? = nil) async {
    guard !displays.isEmpty, !isChangingConnection, !isRestoringConnections, !isCheckingQuit, !isConfirmingDisconnect else { return }
    guard !isPreparingBrightnessSync else {
      failures.topology = BrightnessFailure(
        summary: "正在准备多屏同步",
        suggestion: "正在读取各屏硬件亮度，请稍后再调节。",
        recovery: .unavailable
      )
      return
    }
    guard !stableID.isEmpty else {
      failures.topology = BrightnessFailurePresenter.noStableIdentity
      return
    }

    let target = BrightnessAccessibility.clamp(value)
    var planned = [BrightnessIntent(value: target, displayStableID: stableID)]
    if synchronize && isBrightnessSyncEnabled {
      let ids = displays.compactMap(\.stableID)
      var values: [String: Int] = [:]
      for id in ids { values[id] = displayedBrightness(for: id) }
      let group: [BrightnessIntent]?
      if let relativeSteps {
        group = BrightnessSyncPlan.intents(sourceID: stableID, steps: relativeSteps,
                                          orderedIDs: ids, current: values)
      } else {
        group = BrightnessSyncPlan.intents(sourceID: stableID, target: target,
                                          orderedIDs: ids, current: values)
      }
      if ids.count == displays.count,
        let group, group.first?.value == target {
        planned = group
        brightnessWriteLogger.info("synchronized brightness intent targetCount=\(group.count)")
      } else {
        stopBrightnessSyncForMissingBaseline()
      }
    }
    brightnessSyncTargets = planned.count > 1 ? Dictionary(uniqueKeysWithValues: planned.map { ($0.displayStableID, $0.value) }) : [:]
    brightnessSyncResults = [:]
    if !showKeyboardFeedback {
      discardKeyboardSteps(for: Set(planned.map(\.displayStableID)))
    }
    for intent in planned {
      beginBrightnessFeedback(for: intent.displayStableID)
      intents.submit(intent)
      setIntendedForDisplay(intent.value, id: intent.displayStableID)
      clearFailure(for: intent.displayStableID)
      if showKeyboardFeedback { keyboardFeedbackIDs.insert(intent.displayStableID) }
      if keyboardFeedbackIDs.contains(intent.displayStableID) {
        self.showKeyboardFeedback(for: intent.displayStableID, state: .changing(intent.value))
      }
    }
    // Starting a write on this display supersedes only this display's own banner. Banners
    // are filed per display, so a nudge on one card can no longer erase a neighbour's error
    // before the user has read it, along with the retry button that was the way out of it.

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
        keyboardFeedbackIDs.remove(intent.displayStableID)
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
    // Even selecting the current value takes manual control from automation.

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
      let index = displays.firstIndex(where: { $0.stableID == intent.displayStableID }) ?? -1
      brightnessWriteLogger.info("brightness write verified displayIndex=\(index) requested=\(intent.value) observed=\(verified)")
      // Succeeding on one display resolves only that display's banner; every other card's
      // failure is still unresolved and keeps its retry button.
      if !intents.hasPending(for: intent.displayStableID) {
        clearFailure(for: intent.displayStableID)
        confirmBrightnessFeedback(for: intent.displayStableID)
        if brightnessSyncTargets[intent.displayStableID] == intent.value {
          brightnessSyncResults[intent.displayStableID] = true
        }
      }
      if keyboardFeedbackIDs.contains(intent.displayStableID),
         !intents.hasPending(for: intent.displayStableID) {
        showKeyboardFeedback(for: intent.displayStableID, state: .confirmed(verified))
      }
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
      let index = displays.firstIndex(where: { $0.stableID == intent.displayStableID }) ?? -1
      let code = (error as? DisplayDJError)?.code.rawValue ?? String(describing: type(of: error))
      brightnessWriteLogger.error("brightness write failed displayIndex=\(index) code=\(code, privacy: .public)")
      guard !intents.hasPending(for: intent.displayStableID) else { return }
      brightnessFeedback[intent.displayStableID] = .failed
      if brightnessSyncTargets[intent.displayStableID] == intent.value {
        brightnessSyncResults[intent.displayStableID] = false
      }
      setFailure(
        BrightnessFailurePresenter.failure(
          for: error,
          operation: .write(value: intent.value, displayStableID: intent.displayStableID)
        ),
        for: intent.displayStableID
      )
      if keyboardFeedbackIDs.contains(intent.displayStableID) {
        showKeyboardFeedback(for: intent.displayStableID,
                             state: .failed(failure(for: intent.displayStableID)?.summary ?? "亮度调节失败"))
      }
    }
  }
}
