import AppKit
import SwiftUI

extension DisplayBarController {
  // MARK: - Setup

  func setup() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    if let button = statusItem.button {
      button.image = DisplayDJStatusIcon.make(
        accessibilityDescription: BrightnessAccessibility.statusItemName
      )
      button.action = #selector(togglePopover)
      button.target = self
      button.toolTip = "DisplayDJ — 显示器与 Agent 控制"
    }
    // Applied here too, not only from the sink: the sink fires on its inputs, and the item is
    // already on screen before any of them has moved. The image's own description does not
    // cover it — `NSButton` keeps that only while the title is empty, which is exactly the
    // no-reading state, so the item would announce a brightness it does not have and then
    // fall silent about the app the moment one arrives.
    updateStatusItemTitle()

    let popover = NSPopover()
    popover.behavior = .transient
    popover.delegate = self
    let content = NSHostingController(rootView: DisplayBarView(controller: self))
    // A popover resizes itself from its content view controller's `preferredContentSize`, and
    // this is what keeps that value in step with the SwiftUI layout. Stated rather than left to
    // the default because the popover is shown before the topology is known — the cards arrive
    // after the window already exists, and a window that does not follow its content is the
    // whole of the "first open is clipped" defect.
    content.sizingOptions = [.preferredContentSize]
    popover.contentViewController = content
    self.popover = popover

    eventMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      self?.closePopover()
    }

    // The wheel is the other thing the menu bar item answers to, and it needs no popover.
    installScrollWheelMonitor()

    // Brightness hotkeys are opt-in. Nothing observes the keyboard until the user
    // enables them, so ⌘= / ⌘- keep their meaning in every other app.
    hotkeys.activateStoredPreference()
    hotkeysEnabled = hotkeys.isEnabled
    refreshAccessibilityPermission()

    // Polling is started only when the popover becomes visible (see NSPopoverDelegate).

    observeStatusItemInputs()
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
      let observer = NSWorkspace.shared.notificationCenter.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.invalidateBrightnessAfterWake() }
      }
      wakeObservers.append(observer)
    }
    startConnectionAutoRelease()
    // Whether disconnecting is possible at all is settled here rather than on
    // first use: it never changes while the app runs, and discovering it late
    // would leave the control looking available until the first tap failed.
    connectionSupported = probeConnectionSupport()
    refreshDisconnectedDisplays()
    loadPreferences()
  }

  // MARK: - Popover

  @objc private func togglePopover() {
    guard let popover else { return }
    if popover.isShown {
      closePopover()
    } else if let button = statusItem.button {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      popover.contentViewController?.view.window?.makeKey()
    }
  }

  private func closePopover() {
    popover?.performClose(nil)
  }
}
