import AppKit
import DisplayDJCore
import SwiftUI

@MainActor
final class LiteApplication: NSObject, NSApplicationDelegate, NSPopoverDelegate {
  private var statusItem: NSStatusItem?
  private let popover = NSPopover()
  private var window: NSWindow?
  private var model: LiteModel?
  private let topology = CGDisplayTopologyChangeSource()
  private var delayedRefresh: Task<Void, Never>?
  private var isPreview = false
  private var isCheckingQuit = false
  private var canTerminate = false
  private var isConfirmingConnection = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    isPreview = CommandLine.arguments.contains("--preview")
    let access: any LiteConnectionAccess = isPreview ? LitePreviewAccess() : LiteConnectionService.live()
    let model = LiteModel(access: access)
    self.model = model
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = LiteStatusIcon.makeImage()
    item.button?.toolTip = "DisplayDJ Lite — 外屏连接控制"
    item.button?.target = self
    item.button?.action = #selector(togglePopover)
    statusItem = item
    let hosting = NSHostingController(rootView: LiteView(model: model, isPreview: isPreview, quit: {
      NSApplication.shared.terminate(nil)
    }, perform: { [weak self] row in self?.requestAction(row) }))
    hosting.sizingOptions = [.preferredContentSize]
    popover.contentViewController = hosting
    popover.behavior = .transient
    popover.delegate = self
    if !isPreview {
      topology.start { [weak self] _ in
        Task { @MainActor in self?.scheduleRefresh() }
      }
    }
    Task { await model.refresh() }
    if CommandLine.arguments.contains("--show") {
      // An explicit local preview can be opened as a regular utility window.
      let window = NSWindow(contentViewController: hosting)
      window.title = isPreview ? "DisplayDJ Lite · 模拟演示" : "DisplayDJ Lite"
      window.styleMask = [.titled, .closable]
      window.isReleasedWhenClosed = false
      window.center()
      window.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
      self.window = window
    }
  }

  @objc private func togglePopover() {
    if popover.isShown { popover.performClose(nil); return }
    guard let button = statusItem?.button else { return }
    if let window { window.close(); self.window = nil }
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    Task { await model?.refresh() }
  }

  private func scheduleRefresh() {
    delayedRefresh?.cancel()
    delayedRefresh = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      await self?.model?.refresh()
    }
  }

  private func requestAction(_ row: LiteDisplayRow) {
    guard let model, !model.isBusy, !isConfirmingConnection, !isCheckingQuit else { return }
    if row.action == .disconnected {
      isConfirmingConnection = true
      // Keep confirmation outside the transient popover, with the exact target captured.
      popover.performClose(nil)
      let approved = LiteDisconnectConfirmation.confirm(name: row.name, isPreview: isPreview)
      isConfirmingConnection = false
      guard approved else { showResult(); return }
    }
    Task { @MainActor in
      // The service checks fresh identity/topology again before any transaction.
      await model.perform(row)
      showResult()
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if canTerminate { return .terminateNow }
    guard let model, model.canQuit, !isCheckingQuit, !isConfirmingConnection else { return .terminateCancel }
    isCheckingQuit = true
    Task { @MainActor in
      await model.refresh()
      if model.error == nil, model.pendingRecoveryCount == 0 {
        finishQuit(true)
        return
      }
      let alert = NSAlert()
      alert.messageText = isPreview ? "模拟演示：退出前恢复示例？" : "退出前恢复外屏？"
      if model.error != nil {
        alert.informativeText = "恢复记录暂时无法确认。选择恢复会重新检查；无法确认恢复时将取消退出。"
      } else {
        alert.informativeText = "Lite 保存了 \(model.pendingRecoveryCount) 块屏幕的恢复记录。恢复并确认成功后才会退出。卸载或覆盖安装前也请先完成恢复。"
      }
      alert.addButton(withTitle: isPreview ? "模拟恢复并退出" : "恢复并退出")
      alert.addButton(withTitle: "取消")
      alert.buttons[1].keyEquivalent = "\u{1b}"
      sender.activate(ignoringOtherApps: true)
      switch alert.runModal() {
      case .alertFirstButtonReturn:
        let restored = await model.restoreForQuit()
        finishQuit(restored)
        if !restored { showResult() }
      default:
        finishQuit(false)
      }
    }
    return .terminateLater
  }

  private func finishQuit(_ approved: Bool) {
    canTerminate = approved
    isCheckingQuit = false
    NSApplication.shared.reply(toApplicationShouldTerminate: approved)
  }

  private func showResult() {
    NSApplication.shared.activate(ignoringOtherApps: true)
    if let window { window.makeKeyAndOrderFront(nil) }
    else if let button = statusItem?.button, !popover.isShown {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    delayedRefresh?.cancel()
    topology.stop()
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = LiteApplication()
app.delegate = delegate
app.run()
