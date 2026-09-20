import AppKit

/// What the wheel has to remember between events: the step it owes, the event it last
/// counted, and the two timers it is waiting on.
///
/// One value rather than four controller fields because all of it belongs to the wheel and
/// nothing else reads it — and because the controller's own file is already at the length
/// limit, which four more fields would have broken.
struct ScrollWheelState {
  var coalescer = ScrollWheelCoalescer()
  var lastEventTimestamp: TimeInterval = 0
  var settleTimer: Timer?
  var failureTimer: Timer?
}

// MARK: - Scroll wheel

extension DisplayBarController {

  /// How long the wheel has to fall quiet before its accumulated step is sent.
  ///
  /// A gesture is a stream, and writing on every event would ask the hardware for each value
  /// the pointer had already swept past. The wait costs the user nothing they can perceive —
  /// the number in the menu bar moves on the first event — and turns a burst of dozens of
  /// events into one write.
  static let scrollSettleInterval: TimeInterval = 0.12

  /// How long a failed scroll stays marked in the menu bar.
  static let scrollFailureInterval: TimeInterval = 2.0

  /// Listens for wheels over the menu bar item, so brightness can be changed without
  /// opening the popover at all.
  ///
  /// Both a local and a global monitor, because which of the two sees this event depends on
  /// where the window server considers the item to belong — and the answer is not knowable
  /// from here. The app's existing click-outside monitor is global and does *not* fire when
  /// the user clicks the item itself, or the popover could never be opened; that is evidence
  /// the item's events stay inside this app, where only a local monitor can see them. It is
  /// not proof, so the global one is installed as well and the two are reconciled by the
  /// event's own timestamp below.
  ///
  /// Neither needs accessibility trust. A monitor observes rather than intercepts, and the
  /// event still goes wherever it was going — which is what separates this from the global
  /// *keyboard* observer the hotkeys need and the app will not install unasked.
  ///
  /// Whether any event arrives at all is the one thing no unit test can settle. It has to be
  /// confirmed on real hardware, by scrolling over the item; the failure to look for first
  /// is a monitor that is installed and silent.
  func installScrollWheelMonitor() {
    guard scrollMonitor == nil, localScrollMonitor == nil else { return }
    localScrollMonitor = NSEvent.addLocalMonitorForEvents(
      matching: .scrollWheel
    ) { [weak self] event in
      Task { @MainActor [weak self] in
        self?.handleScrollWheel(event)
      }
      return event
    }
    scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      Task { @MainActor [weak self] in
        self?.handleScrollWheel(event)
      }
    }
  }

  private func handleScrollWheel(_ event: NSEvent) {
    // The same event can reach the local and the global monitor. The timestamp is the
    // event's own identity, so recognising it is what keeps one notch from becoming two.
    guard event.timestamp != scrollWheel.lastEventTimestamp else { return }
    scrollWheel.lastEventTimestamp = event.timestamp
    // The frame is the button's window, in screen coordinates — the same space
    // `NSEvent.mouseLocation` reports, so the two are compared without converting either.
    guard let frame = statusItem?.button?.window?.frame else { return }
    guard ScrollWheelHitTest.contains(NSEvent.mouseLocation, in: frame) else { return }
    let step = ScrollWheelStep.step(
      deltaY: event.scrollingDeltaY,
      optionHeld: event.modifierFlags.contains(.option)
    )
    guard step != 0 else { return }
    scrollWheel.coalescer.add(step)
    scheduleScrollSettle()
  }

  /// Waits out the gesture, restarting the wait on every event that is still part of it.
  private func scheduleScrollSettle() {
    scrollWheel.settleTimer?.invalidate()
    scrollWheel.settleTimer = Timer.scheduledTimer(
      withTimeInterval: Self.scrollSettleInterval,
      repeats: false
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        await self?.commitPendingScroll()
      }
    }
  }

  private func commitPendingScroll() async {
    scrollWheel.settleTimer = nil
    guard let delta = scrollWheel.coalescer.take() else { return }
    await adjustBrightnessViaScroll(by: delta)
  }

  /// Applies a wheel step to the selected display, and says so when it fails.
  ///
  /// Shaped like the hotkey path because the popover is shut in both cases and there may be
  /// no reading to step from. Returning on that missing reading, as the card's own path does,
  /// would make the control silently do nothing — the discard the intent buffer exists to
  /// prevent, arriving through the one entrance with no button to grey out.
  ///
  /// Unlike the hotkey path it waits for the write and then looks at the outcome. A hotkey
  /// failure has a card to land on; the wheel is used with the popover shut, so unless the
  /// menu bar itself reacts, failure and success look exactly alike.
  func adjustBrightnessViaScroll(by delta: Int) async {
    if displayedBrightness == nil {
      await refreshSelectedDisplayOnDemand()
    }
    guard let stableID = selectedStableID, !stableID.isEmpty else { return }
    guard let current = displayedBrightness(for: stableID) else { return }
    let target = BrightnessAccessibility.adjusted(current, by: delta)
    guard target != current else { return }
    await setBrightness(target, for: stableID)
    if failure(for: stableID) != nil {
      showScrollFailure()
    }
  }

  /// Marks a failed scroll in the menu bar for a moment.
  ///
  /// The banner is still filed against the display and waits on its card, but there is no
  /// card on screen when the wheel is used. Non-modal and self-clearing by design: a mark
  /// that reverts on its own, not an alert the user has to dismiss.
  func showScrollFailure() {
    guard let button = statusItem?.button else { return }
    button.image = NSImage(
      systemSymbolName: "exclamationmark.triangle",
      accessibilityDescription: BrightnessAccessibility.scrollFailureImageName
    )
    scrollWheel.failureTimer?.invalidate()
    scrollWheel.failureTimer = Timer.scheduledTimer(
      withTimeInterval: Self.scrollFailureInterval,
      repeats: false
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.clearScrollFailure()
      }
    }
  }

  private func clearScrollFailure() {
    scrollWheel.failureTimer = nil
    statusItem?.button?.image = DisplayDJStatusIcon.make(
      accessibilityDescription: BrightnessAccessibility.statusItemName
    )
  }
}
