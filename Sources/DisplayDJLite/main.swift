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
  private var previewRefreshDelayMilliseconds = 0
  private var isCheckingQuit = false
  private var canTerminate = false
  private var isConfirmingConnection = false
  private var wakeObservers: [NSObjectProtocol] = []
  private let guardian = LiteRecoveryGuardian()

  func applicationDidFinishLaunching(_ notification: Notification) {
    isPreview = CommandLine.arguments.contains("--preview")
    let access: any LiteConnectionAccess
    let brightnessAccess: any LiteBrightnessAccess
    if isPreview {
      let args = CommandLine.arguments
      func value(after flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
      }
      // Preview-only overrides never change system preferences or the live adapter.
      if let appearance = value(after: "--appearance"), appearance != "system" {
        NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
      }
      let failure = LitePreviewBrightnessFailure(rawValue: value(after: "--failure") ?? "none") ?? .none
      let delay = min(5000, max(0, Int(value(after: "--refresh-delay-ms") ?? "0") ?? 0))
      previewRefreshDelayMilliseconds = delay
      let preview = LitePreviewAccess(compact: !args.contains("--all-scenarios"), brightnessFailure: failure,
        refreshDelay: .milliseconds(delay))
      access = preview
      brightnessAccess = preview
    } else {
      access = LiteConnectionService.live(ownerID: guardian.ownerID,
        ensureRecoveryProtection: { [guardian] in try await guardian.ensureStarted() })
      brightnessAccess = LiteHardwareBrightnessAccess()
    }
    let model = LiteModel(access: access, brightnessAccess: brightnessAccess)
    self.model = model
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = LiteStatusIcon.makeImage()
    item.button?.toolTip = "DisplayDJ Lite — 亮度与外屏连接"
    item.button?.target = self
    item.button?.action = #selector(togglePopover)
    statusItem = item
    let hosting = NSHostingController(rootView: LiteView(model: model, isPreview: isPreview,
      previewRefreshDelayMilliseconds: previewRefreshDelayMilliseconds, quit: {
      NSApplication.shared.terminate(nil)
    }, perform: { [weak self] row in self?.requestAction(row) }))
    hosting.sizingOptions = [.preferredContentSize]
    popover.contentViewController = hosting
    popover.behavior = .transient
    popover.delegate = self
    if !isPreview {
      for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
        wakeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
          forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
          })
      }
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
    model?.invalidateForTopologyChange()
    delayedRefresh?.cancel()
    delayedRefresh = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      guard let self else { return }
      for attempt in 0..<3 {
        guard !Task.isCancelled else { return }
        await model?.refresh()
        guard model?.needsLifecycleRetry == true, attempt < 2 else { return }
        do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
      }
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

// The same signed executable has a headless recovery mode. Enter it before
// creating NSApplication, a menu item, topology callbacks or another guardian.
if let index = CommandLine.arguments.firstIndex(of: "--recovery-guardian") {
  guard CommandLine.arguments.indices.contains(index + 1),
        let parent = Int32(CommandLine.arguments[index + 1]),
        CommandLine.arguments.indices.contains(index + 2),
        let ownerID = UUID(uuidString: CommandLine.arguments[index + 2]) else { exit(2) }
  Task { @MainActor in exit(await LiteRecoveryGuardian.run(parentPID: parent, ownerID: ownerID)) }
  RunLoop.main.run()
  exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = LiteApplication()
app.delegate = delegate
app.run()
