import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// MARK: - Main Menu

let mainMenu = NSMenu()

// App menu
let appMenu = NSMenu()
appMenu.addItem(
  NSMenuItem(
    title: "关于 DisplayDJ",
    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
    keyEquivalent: ""
  )
)
appMenu.addItem(.separator())
appMenu.addItem(
  NSMenuItem(
    title: "退出 DisplayDJ",
    action: #selector(NSApplication.terminate(_:)),
    keyEquivalent: "q"
  )
)
let appMenuItem = NSMenuItem()
appMenuItem.submenu = appMenu
mainMenu.addItem(appMenuItem)

// Edit menu
let editMenu = NSMenu(title: "编辑")
editMenu.addItem(
  NSMenuItem(
    title: "撤销",
    action: #selector(UndoManager.undo),
    keyEquivalent: "z"
  )
)
editMenu.addItem(
  NSMenuItem(
    title: "重做",
    action: #selector(UndoManager.redo),
    keyEquivalent: "Z"
  )
)
editMenu.addItem(.separator())
editMenu.addItem(
  NSMenuItem(
    title: "剪切",
    action: #selector(NSText.cut(_:)),
    keyEquivalent: "x"
  )
)
editMenu.addItem(
  NSMenuItem(
    title: "复制",
    action: #selector(NSText.copy(_:)),
    keyEquivalent: "c"
  )
)
editMenu.addItem(
  NSMenuItem(
    title: "粘贴",
    action: #selector(NSText.paste(_:)),
    keyEquivalent: "v"
  )
)
editMenu.addItem(
  NSMenuItem(
    title: "全选",
    action: #selector(NSText.selectAll(_:)),
    keyEquivalent: "a"
  )
)
let editMenuItem = NSMenuItem()
editMenuItem.submenu = editMenu
mainMenu.addItem(editMenuItem)

NSApplication.shared.mainMenu = mainMenu

// MARK: - Controller

let controller = DisplayBarController()
if CommandLine.arguments.contains("--interaction-preview") {
  let count = CommandLine.arguments.contains("--two-displays") ? 2 : 6
  let args = CommandLine.arguments
  let delay = args.firstIndex(of: "--refresh-delay-ms").flatMap { index in
    args.indices.contains(index + 1) ? Int(args[index + 1]) : nil
  } ?? 0
  FullInteractionPreview(count: count).configure(controller, refreshDelayMilliseconds: delay)
}
let applicationDelegate = FullApplicationDelegate(controller: controller)
app.delegate = applicationDelegate
controller.setup()
if CommandLine.arguments.contains("--display-tools") { controller.showDisplayTools() }
if CommandLine.arguments.contains("--show") { controller.showPanelWindow() }

app.run()
