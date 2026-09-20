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
controller.setup()

app.run()
