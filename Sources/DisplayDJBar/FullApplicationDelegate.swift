import AppKit

@MainActor
final class FullApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let controller: DisplayBarController
  private var canTerminate = false
  init(controller: DisplayBarController) { self.controller = controller }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if canTerminate { return .terminateNow }
    guard !controller.isLoading, !controller.isCheckingQuit, !controller.isConfirmingDisconnect else { return .terminateCancel }
    controller.isCheckingQuit = true
    Task { @MainActor in
      controller.refreshDisconnectedDisplays()
      let current = controller.disconnectedDisplays.filter { record in
        record.requiresRediscovery != true || controller.connectionTopology.contains { $0.stableID == record.stableID }
      }
      if current.isEmpty && controller.connectionRecordError == nil { finish(true); return }
      controller.popover?.performClose(nil)
      let alert = NSAlert()
      alert.messageText = "退出前恢复外屏？"
      alert.informativeText = "DisplayDJ 保存的当前恢复记录会逐台核验。恢复并确认成功后才会退出；失败将保留记录并取消退出。"
      alert.addButton(withTitle: "恢复并退出")
      alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
      sender.activate(ignoringOtherApps: true)
      guard alert.runModal() == .alertFirstButtonReturn else { finish(false); controller.showConnectionResult(); return }
      let restored = await controller.restoreConnectionsForQuit()
      finish(restored)
      if !restored { controller.showConnectionResult() }
    }
    return .terminateLater
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === controller.panelWindow else { return }
    controller.panelWindow = nil
    if controller.popover?.isShown != true { controller.popoverDidClose(notification) }
  }

  private func finish(_ approved: Bool) {
    canTerminate = approved
    controller.isCheckingQuit = false
    NSApp.reply(toApplicationShouldTerminate: approved)
  }
}
