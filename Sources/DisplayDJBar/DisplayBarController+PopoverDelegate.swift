import AppKit

extension DisplayBarController: NSPopoverDelegate {
  func popoverDidShow(_ notification: Notification) {
    // The user may have changed accessibility trust in System Settings while the
    // popover was closed.
    refreshAccessibilityPermission()
    guard refreshTimer == nil else { return }
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self,
          self.refreshTimer != nil,
          !self.isWriting,
          !self.isReading,
          !self.intents.hasPending,
          !self.intents.isDraining
        else { return }
        self.isPollingRead = true
        defer { self.isPollingRead = false }
        await self.refreshAllDisplays()
      }
    }
    Task { await scanAndRefresh() }
  }

  func popoverDidClose(_ notification: Notification) {
    refreshTimer?.invalidate()
    refreshTimer = nil
    refreshTask?.cancel()
    refreshTask = nil
  }
}
