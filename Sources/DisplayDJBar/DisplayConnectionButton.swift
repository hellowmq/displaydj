import DisplayDJCore
import SwiftUI

/// Secondary actions have their own hit region; opening this menu never
/// changes the wheel selection or disconnects a display.
struct DisplayConnectionButton: View {
  let display: DisplayDescriptor
  @ObservedObject var controller: DisplayBarController
  var body: some View {
    Menu {
      Text(controller.alias(for: display))
      if controller.displays.count > 1 {
        Button {
          controller.selectDisplay(key: display.selectionKey)
        } label: {
          if controller.selectedDisplayKey == display.selectionKey {
            Label("设为菜单栏滚轮目标", systemImage: "checkmark")
          } else { Text("设为菜单栏滚轮目标") }
        }
      }
      Button("显示设置…") { controller.showDisplayTools(section: .display, display: display) }
      if !display.isBuiltIn {
        Divider()
        Button("断开这台显示器…") { controller.requestDisconnect(display) }
          .disabled(!controller.connectionAvailability(for: display).canDisconnect || controller.isLoading || controller.isRestoringConnections)
        if let reason = controller.connectionAvailability(for: display).guidance { Text(reason) }
      }
    } label: { Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 28, height: 28) }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .accessibilityLabel("\(controller.alias(for: display)) 的更多操作")
    .help(controller.connectionAvailability(for: display).guidance ?? "显示设置或断开这台显示器")
  }
}
