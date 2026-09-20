import Testing

@testable import DisplayDJBar

@Suite("Read pass lifecycle")
struct ReadPassTests {

  // MARK: - Abandoning the rest of the pass

  @Test("A visible popover with an uncancelled pass keeps reading")
  func continuesWhileVisibleAndUncancelled() {
    #expect(
      ReadPass.shouldContinue(popoverIsVisible: true, isCancelled: false, userIsWriting: false))
  }

  /// The defect this guards: a multi-display pass takes hundreds of milliseconds per
  /// display, so the popover is routinely dismissed partway through. Checking only at the
  /// entrance let the pass finish reading every remaining monitor for nobody.
  @Test("A dismissed popover abandons the remaining displays")
  func stopsWhenPopoverClosed() {
    #expect(
      !ReadPass.shouldContinue(popoverIsVisible: false, isCancelled: false, userIsWriting: false))
  }

  @Test("A cancelled pass abandons the remaining displays")
  func stopsWhenCancelled() {
    #expect(
      !ReadPass.shouldContinue(popoverIsVisible: true, isCancelled: true, userIsWriting: false))
  }

  @Test("Cancellation stops the pass even while the popover is still open")
  func cancellationWinsOverVisibility() {
    // A superseding read cancels its predecessor while the popover stays open, so
    // visibility alone must not be enough to keep going.
    #expect(
      !ReadPass.shouldContinue(popoverIsVisible: true, isCancelled: true, userIsWriting: false))
  }

  // MARK: - Yielding the lane to the user

  /// The defect this guards: the entrance refused to start a pass while a write was in
  /// flight, but nothing re-tested it afterwards. Since the timer fires every two seconds
  /// and a pass spends hundreds of milliseconds per display, the ordinary case is that the
  /// user starts steering *after* the pass has begun — and the pass then kept reading the
  /// rest of the display list on the same hardware lane as the write.
  @Test("A pass yields the remaining displays once the user starts writing")
  func stopsWhenUserStartsWriting() {
    #expect(
      !ReadPass.shouldContinue(popoverIsVisible: true, isCancelled: false, userIsWriting: true))
  }

  /// A write is a whole-pass stop rather than a per-display skip: it occupies the shared
  /// hardware lane, so continuing on to the *other* monitors would collide just the same.
  @Test("A write stops the pass rather than skipping one display")
  func writeIsAStopNotASkip() {
    // The per-display decision is about one display and knows nothing about writes, so the
    // stop decision is the only thing that can protect the lane.
    #expect(
      ReadPass.step(stableID: "uuid:hp", hasPendingIntent: false) == .read(stableID: "uuid:hp"))
    #expect(
      !ReadPass.shouldContinue(popoverIsVisible: true, isCancelled: false, userIsWriting: true))
  }

  // MARK: - What happens to a single display

  @Test("A display with a stable identity and no pending intent is read")
  func readsAddressableIdleDisplay() {
    #expect(
      ReadPass.step(stableID: "uuid:hp", hasPendingIntent: false) == .read(stableID: "uuid:hp"))
  }

  @Test("A display the user is steering is left alone, not read")
  func skipsDisplayWithPendingIntent() {
    // Polling underneath an active drag would overwrite the user's newer intent with an
    // older hardware value.
    #expect(ReadPass.step(stableID: "uuid:hp", hasPendingIntent: true) == .steering)
  }

  @Test("A display with no stable identity is reported as unaddressable, not merely skipped")
  func unaddressableDisplayIsDistinguishedFromSteering() {
    // The defect this guards: both outcomes used to collapse into one `nil`, so the pass
    // passed over an unidentifiable monitor in silence. That card's controls are disabled
    // and its readout is a placeholder permanently — unlike steering, which resolves itself
    // the moment the write lands — so it is the one skip that owes the user a sentence.
    #expect(ReadPass.step(stableID: nil, hasPendingIntent: false) == .unaddressable)
    #expect(ReadPass.step(stableID: "", hasPendingIntent: false) == .unaddressable)
    #expect(ReadPass.step(stableID: nil, hasPendingIntent: false) != .steering)
  }

  @Test("Being unaddressable outranks being steered")
  func unaddressableWinsOverSteering() {
    // A display with no stable identity cannot be written to either, so a pending intent
    // for it cannot be real. Reporting it as `steering` would hide a permanent condition
    // behind a transient one that clears itself.
    #expect(ReadPass.step(stableID: nil, hasPendingIntent: true) == .unaddressable)
    #expect(ReadPass.step(stableID: "", hasPendingIntent: true) == .unaddressable)
  }

  /// Neither non-reading outcome may abandon the displays after it: an unaddressable or
  /// actively steered monitor says nothing about its neighbours, which still need readings.
  @Test("Passing over one display is independent of continuing the pass")
  func skipIsNotAStop() {
    #expect(ReadPass.step(stableID: nil, hasPendingIntent: false) == .unaddressable)
    #expect(ReadPass.step(stableID: "uuid:hp", hasPendingIntent: true) == .steering)
    #expect(
      ReadPass.shouldContinue(popoverIsVisible: true, isCancelled: false, userIsWriting: false))
  }
}
