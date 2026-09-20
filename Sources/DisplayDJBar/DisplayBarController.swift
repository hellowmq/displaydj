import AppKit
import ApplicationServices
import Combine
import DisplayDJCore
import SwiftUI

@MainActor
final class DisplayBarController: NSObject, ObservableObject {
  /// Internal rather than `private` because the status item unit lives in its own file.
  /// It is never part of the view-facing surface.
  var statusItem: NSStatusItem!
  /// Internal rather than `private` because building it, and showing and hiding
  /// it, live in DisplayBarController+Popover.swift. Never part of the view
  /// surface.
  var popover: NSPopover?
  /// Internal for the same reason as `popover`: the global monitor is installed
  /// and removed from the same file.
  nonisolated(unsafe) var eventMonitor: Any?
  /// The wheel monitors, local and global: which of the two sees a wheel over the item is
  /// not decidable from here, and a monitor is removable only through its own token.
  nonisolated(unsafe) var scrollMonitor: Any?
  nonisolated(unsafe) var localScrollMonitor: Any?
  /// Steps owed, last event seen, and the two timers. One field rather than four so the
  /// controller's own file does not grow by a page for state only the wheel uses.
  var scrollWheel = ScrollWheelState()
  /// Internal setter: the popover delegate that starts and stops the poll lives in its own
  /// file, so this cannot be `private`. Only that delegate writes it; `popoverIsVisible` reads.
  nonisolated(unsafe) var refreshTimer: Timer?
  /// Watches for displays being plugged in and out. Only a process that stays
  /// up can do it, so it lives here and not in the CLI.
  ///
  /// Internal rather than `private` because starting and stopping it lives in
  /// the controller's own extension file; it is never part of the view surface.
  var connectionAutoRelease: DisplayConnectionAutoReleaseRunner?
  /// Internal for the same reason as `statusItem`: the sink that keeps the menu bar in step
  /// with its inputs is defined alongside the drawing code it feeds.
  var cancellables = Set<AnyCancellable>()

  // MARK: - Display list

  @Published private(set) var displays: [DisplayDescriptor] = []
  /// Selection is tracked by display identity, not by array position, so replugging or
  /// re-enumerating displays can never slide the selection onto a different monitor.
  @Published private(set) var selection = DisplaySelection()

  /// Identity key of the selected display, for the picker binding.
  var selectedDisplayKey: String? {
    selection.selectedKey
  }

  var selectedDisplay: DisplayDescriptor? {
    selection.display(in: displays)
  }

  // MARK: - Per-display state

  /// Per-display hardware-confirmed brightness, keyed by stableID.
  @Published private(set) var brightnessByID: [String: Int] = [:]
  /// Per-display latest user intent, keyed by stableID.
  @Published var intendedByID: [String: Int] = [:]

  // A `brightness` accessor once sat here, returning the selected display's *confirmed*
  // reading for the hotkeys and the status bar. Both now read `displayedBrightness`, which
  // additionally lets a not-yet-written user intent outrank the last confirmed value — so the
  // older accessor had no readers left, and reviving it would reintroduce a second, subtly
  // different answer to "what brightness are we showing?".

  /// Failures, filed under the display they belong to. Each is already phrased for the user
  /// and carries its own way out.
  ///
  /// Per-display rather than a single slot because every monitor has its own card and fails
  /// independently: one shared slot let a second failure erase the first before it was ever
  /// seen, so which error the user got told about depended on enumeration order.
  @Published var failures = DisplayFailures()
  /// Read state, owned by whichever read is actually in flight.
  ///
  /// Not a bare `Bool` because a superseded read unwinds after its replacement has started,
  /// and would otherwise clear a flag that had stopped describing it — announcing an idle
  /// lane while a read was still running on it.
  @Published private(set) var reads = ReadActivity()
  @Published var isWriting = false
  /// True only while a read belongs to the silent background polling pass, not to a
  /// user-initiated read (manual refresh, a single-display read, a hotkey). It lets the
  /// top-bar spinner stay hidden on the two-second poll that merely keeps the cards in
  /// step with hardware, while still appearing for reads the user actually asked for.
  @Published var isPollingRead = false

  // MARK: - Display connection

  /// Records of displays this tool disconnected and can therefore reconnect.
  ///
  /// The only way back: a disconnected display is absent from the topology, so
  /// it has no card of its own and its stable ID resolves to nothing.
  ///
  /// Setter is internal because the extension that rebuilds it lives in its own
  /// file; the view reads it and never writes it.
  @Published var disconnectedDisplays: [DisplayConnectionRecord] = []
  /// The last thing that went wrong while connecting or disconnecting.
  ///
  /// One slot rather than one per display: a second attempt replaces the first
  /// explanation rather than stacking two banners on one card.
  ///
  /// Setter is internal for the same reason as `disconnectedDisplays`.
  @Published var connectionNotice: DisplayConnectionNotice?
  /// Whether a connect or disconnect request is in flight.
  ///
  /// Setter is internal for the same reason as `disconnectedDisplays`.
  @Published var isChangingConnection = false
  /// Every display the window server reports online, built-in included.
  ///
  /// Not `displays.count`, which is filtered to non-mirrored physical panels and
  /// undercounts: disconnecting is refused when only one display is online *in
  /// total*, so taking the count from the filtered list would disable the button
  /// on a laptop with one external monitor, where the request is perfectly safe.
  @Published private(set) var onlineDisplayCount = 0
  /// Whether this system exposes the entry point that disconnecting needs.
  ///
  /// Decided once at setup: a missing symbol means every request would fail, so
  /// the control says so up front instead of failing on every tap.
  /// Setter is internal because setup decides it from DisplayBarController+Popover.swift.
  var connectionSupported = false

  /// How a connection controller is built. Replaced by tests; the production
  /// path resolves the private entry point and throws when it is absent.
  var connectionControllerFactory: () throws -> DisplayConnectionController = {
    try DisplayConnectionController.live()
  }

  /// Where disconnect records live. Shared with the CLI, so a display
  /// disconnected from the command line is reconnectable from the popover.
  var connectionStore: any DisplayConnectionRecordStoring = FileDisplayConnectionRecordStore()

  /// Where the user's display presentation choices (aliases, manual order) live.
  var preferencesStore: any DisplayPreferencesStoring = FileDisplayPreferencesStore()

  /// The user's display presentation choices, loaded at setup. Published so a card
  /// re-renders when its alias changes without the topology changing.
  @Published var preferences = DisplayPreferences()

  /// Whether a hardware read is in flight. Read-only to the view.
  var isReading: Bool { reads.isReading }

  /// Marks a read as started, returning the token its cleanup must present.
  func beginRead() -> UInt64 {
    reads.begin()
  }

  /// Marks a read as finished. Ignored when the read has already been superseded.
  func endRead(_ token: UInt64) {
    reads.end(token)
  }

  /// The failure shown on a given display's card, if any.
  func failure(for stableID: String) -> BrightnessFailure? {
    failures[stableID]
  }

  /// Records a failure against the display it happened on.
  ///
  /// A banner is drawn on a card and its retry button is driven by the recovery, so the two
  /// must name the same monitor. Filing a failure whose recovery points elsewhere would put
  /// a retry on one display's card that acts on another — the cross-display defect this
  /// module has already had to fix twice. Rather than trust the call sites, the mismatch is
  /// dropped here and the recovery's own target wins.
  func setFailure(_ failure: BrightnessFailure?, for stableID: String) {
    guard let failure else {
      failures[stableID] = nil
      return
    }
    let target = failure.recovery.targetDisplayStableID ?? stableID
    failures[target] = failure
  }

  /// Dismisses the failure belonging to one display. Used by the recovery path before it
  /// retries, so a retry on one card never silences another card's unresolved error.
  func clearFailure(for stableID: String) {
    failures[stableID] = nil
  }

  // Topology-change pruning lives in DisplayBarController+Prune.swift.

  var isLoading: Bool {
    // A connection change counts as busy: it reconfigures the whole display
    // layout, and a brightness read started across that change would be aimed at
    // a topology that is still moving.
    isReading || isWriting || isChangingConnection
  }

  /// Whether the top-bar activity spinner should be visible.
  ///
  /// Background polling re-reads every display every two seconds so a card stays in step
  /// with hardware another app or the monitor's own OSD may have changed. That is a silent
  /// refresh: the numbers just move, and a spinner on every tick makes the UI look busy when
  /// nothing the user asked for is pending — so the poll is excluded here. The spinner is
  /// reserved for operations that actually block the user: a write, a connection change, or
  /// a read they triggered themselves (manual refresh, a single-display read, a hotkey).
  var showsActivitySpinner: Bool {
    (isReading && !isPollingRead) || isWriting || isChangingConnection
  }

  var intents = BrightnessIntentBuffer()
  var writeTask: Task<Void, Never>?
  /// The in-flight read. Internal rather than `private` because the polling extension
  /// lives in its own file and must be able to cancel a superseded read.
  var refreshTask: Task<Void, Never>?
  var displayDiscovery: any DisplayDiscovering = CoreGraphicsDisplayDiscovery()
  var brightnessAccess = DisplayBrightnessAccess()

  // MARK: - Hotkey opt-in

  /// `fileprivate` would hide this from the recovery/hotkey extension in its own file;
  /// it stays internal to the module and is never part of the view-facing surface.
  ///
  /// Routed through the hotkey-specific entry point rather than the card's one. The card can
  /// assume a reading exists — it only enables `±` when one does — but a shortcut fires with
  /// the popover closed, which is precisely the state in which polling is stopped and no
  /// reading may be on hand.
  lazy var hotkeys = BrightnessHotkeyCoordinator { [weak self] hotkey in
    Task { @MainActor [weak self] in
      await self?.adjustBrightnessViaHotkey(by: hotkey.delta)
    }
  }

  /// Whether the user has opted into the brightness hotkeys. Off by default.
  ///
  /// Written only by the hotkey extension; the view treats it as read-only through the
  /// binding it hands to the toggle.
  @Published var hotkeysEnabled = false
  /// Whether macOS currently grants this app the accessibility trust that a global
  /// keyboard observer requires. Purely informational; never requested silently.
  @Published var hasAccessibilityPermission = false

  // MARK: - Status item
  //
  // Drawing the menu bar number, and the subscription that keeps it current, live in
  // DisplayBarController+StatusItem.swift.

  // MARK: - Display scanning

  func scanAndRefresh() async {
    do {
      let allDisplays = try await displayDiscovery.discoverDisplays()
      let controllableDisplays = DisplayBrightnessAccess.visibleDisplays(allDisplays)
      displays = orderedDisplays(controllableDisplays)
      // Taken before filtering, and before anything is read: the connection
      // controls are enabled or disabled from this, so it has to be the truth
      // about the whole topology rather than about the panels this app drives.
      onlineDisplayCount = allDisplays.count
      refreshDisconnectedDisplays()

      // Re-resolve the selection against the new topology: keep the same physical
      // display if it is still attached, otherwise fall back to the remembered one.
      selection.reconcile(
        with: controllableDisplays,
        remembered: rememberedDisplayKey
      )
      // Values are keyed by display, so a rescan only has to forget the displays that
      // actually went away. Which display is *selected* has no bearing on whether another
      // display's reading is still true — wiping everything blanked every other card.
      pruneDisplayState(keeping: controllableDisplays)

      if controllableDisplays.isEmpty {
        brightnessByID = [:]
        intendedByID = [:]
        // The empty state already explains this on screen; a failure banner on top of it
        // would just repeat itself. Nothing is attached, so no banner can be attributed.
        failures.clearAll()
      } else {
        // The enumeration itself succeeded, so a previous scan failure no longer holds.
        // Per-display banners are left alone: they describe those displays, not the scan.
        failures.topology = nil
        // Every card was just invalidated, so every card is read. Finishing a whole-topology
        // rescan by reading only the *selected* display left the other cards showing `--`
        // with their `±` buttons disabled until an unrelated poll happened to fill them in —
        // and on the very first open, that is the state the popover appears in.
        await refresh(scope: .afterTopologyChange(attachedDisplays: controllableDisplays.count))
      }
    } catch {
      failures.topology = BrightnessFailurePresenter.failure(for: error, operation: .scan)
    }
  }

  // MARK: - Select display

  /// Selects a display by its stable identity. Unknown keys are ignored.
  ///
  /// Selection is a focus change, not a topology change: every display keeps its card, so
  /// the readings stay valid and are left alone. Discarding them here blanked the card the
  /// user was leaving and re-read hardware for no reason.
  func selectDisplay(key: String) {
    guard selection.selectedKey != key else { return }
    guard selection.select(key: key, in: displays) else { return }
    saveLastSelectedDisplay()
    // Focus moved, so only the card that gained it needs a reading; the rest kept theirs.
    Task { await refreshCurrentDisplay() }
  }

  // MARK: - Display presentation (manual order & aliases)

  /// Moves the source display to the drop target's slot and pins the new order as the
  /// manual order. Persisted by stable ID, so the pinned order survives rescans and
  /// reboots; only the displays named in it are held in place — new monitors still fall
  /// in physically. `destinationStableID` is the card the user dropped onto; the source
  /// lands in its slot.
  ///
  /// Lives in the primary file because it assigns `displays`, whose setter is `private(set)`.
  func reorderDisplays(sourceStableID: String, destinationStableID: String) {
    guard
      let from = displays.firstIndex(where: { $0.stableID == sourceStableID }),
      let destinationIndex = displays.firstIndex(where: { $0.stableID == destinationStableID }),
      from != destinationIndex
    else { return }

    var order = displays.compactMap { $0.stableID }
    let moved = order.remove(at: from)
    order.insert(moved, at: destinationIndex)

    var next = preferences
    next.manualOrder = order
    preferences = next
    displays = orderedDisplays(displays)
    persistPreferences()
  }

  /// Drops the manual order so cards follow the physical layout again.
  ///
  /// Lives in the primary file because it assigns `displays`, whose setter is `private(set)`.
  func resetOrderToPhysical() {
    var next = preferences
    next.manualOrder = nil
    preferences = next
    displays = orderedDisplays(displays)
    persistPreferences()
  }

  /// The single in-place writer for `brightnessByID`. Because `@Published` on a dictionary
  /// only fires when the whole value is replaced, it copies then reassigns.
  ///
  /// Lives in the primary file because `brightnessByID` is `private(set)`.
  func setBrightnessForDisplay(_ value: Int?, id: String) {
    var copy = brightnessByID
    if let val = value { copy[id] = val } else { copy.removeValue(forKey: id) }
    brightnessByID = copy
  }

  var selectedStableID: String? {
    selection.stableID(in: displays)
  }

  /// The polling timer exists iff the popover is visible and polling is active.
  var popoverIsVisible: Bool {
    refreshTimer != nil
  }
  // MARK: - Cleanup

  deinit {
    refreshTimer?.invalidate()
    refreshTask?.cancel()
    connectionAutoRelease?.stop()
    if let monitor = eventMonitor {
      NSEvent.removeMonitor(monitor)
    }
    if let monitor = scrollMonitor {
      NSEvent.removeMonitor(monitor)
    }
    if let monitor = localScrollMonitor {
      NSEvent.removeMonitor(monitor)
    }
  }
}
