import AppKit

@MainActor
enum LiteDisconnectConfirmation {
  static func confirm(name: String, isPreview: Bool) -> Bool {
    let alert = NSAlert()
    alert.messageText = isPreview ? "模拟断开「\(name)」？" : "断开「\(name)」？"
    alert.informativeText = isPreview ? "仅改变虚构示例，不会操作真实显示器。" :
      "这台屏幕会从 Mac 桌面布局中移除，窗口移到其他在线屏幕。之后可在 Lite 中重新连接。"
    alert.addButton(withTitle: "取消").keyEquivalent = "\r"
    alert.addButton(withTitle: isPreview ? "模拟断开" : "断开这台显示器").keyEquivalent = ""
    // NSAlert does not give a localized, nonstandard cancel position an Escape
    // equivalent when Return is already assigned. Scope both safe keys to this
    // modal window only, and remove the local responder when the modal ends.
    let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let cancelled = MainActor.assumeIsolated {
        guard event.window === alert.window, [UInt16(53), 36, 76].contains(event.keyCode) else { return false }
        NSApplication.shared.stopModal(withCode: .alertFirstButtonReturn)
        return true
      }
      return cancelled ? nil : event
    }
    defer { if let monitor { NSEvent.removeMonitor(monitor) } }
    NSApplication.shared.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertSecondButtonReturn
  }
}
