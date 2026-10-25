import DisplayDJCore
import DisplayDJUI
import SwiftUI

struct DisplayBarView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject var controller: DisplayBarController
  @State private var isEditing = false
  @State private var contentHeight: CGFloat = 0
  @State private var footerHeight: CGFloat = 120
  @FocusState private var moreIsFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      topBar
      if controller.isInteractionPreview {
        VStack(alignment: .leading, spacing: 4) {
          Text("模拟演示 · 虚构显示器，操作只改变内存数据")
          if controller.previewRefreshDelayMilliseconds > 0 {
            Text("图标动画预览 · 模拟读取延迟 \(controller.previewRefreshDelayMilliseconds)ms")
          }
        }.font(.system(size: 11)).foregroundStyle(.orange).padding(.bottom, 8)
      }
      ScrollView {
        VStack(spacing: 8) {
          if controller.displays.isEmpty { emptyState }
          ForEach(controller.displays, id: \.selectionKey) { display in
            DisplayCard(display: display, controller: controller, isEditing: isEditing)
              .reordering(when: isEditing, display: display, controller: controller)
          }
          if !controller.disconnectedDisplays.isEmpty {
            DisconnectedDisplaySection(records: controller.disconnectedDisplays,
              notice: controller.connectionNotice, controller: controller)
          }
          if let failure = controller.failures.topology {
            FailureBanner(failure: failure, controller: controller)
          }
          if let notice = controller.connectionNotice,
             !controller.displays.contains(where: { $0.selectionKey == notice.id }),
             !controller.disconnectedDisplays.contains(where: { DisplayConnectionList.key(for: $0) == notice.id }) {
            ConnectionNoticeRow(notice: notice)
          }
          if controller.quitRecoveryFailed {
            Text("恢复未完成，已取消退出。记录仍保留，请处理对应提示后重试。")
              .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
          }
          if let error = controller.connectionRecordError {
            Label(error, systemImage: "exclamationmark.triangle")
              .font(.system(size: 12)).foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }
        }.measuringHeight(into: $contentHeight)
      }
      .frame(height: DisplayCardsViewport.height(contentHeight: contentHeight,
        availableHeight: controller.panelAvailableHeight, chromeHeight: footerHeight + 74))
      footer.measuringHeight(into: $footerHeight)
    }
    .padding(.horizontal, 12).padding(.vertical, 10).frame(width: 320)
  }

  private var topBar: some View {
    HStack(spacing: 6) {
      Text(isEditing ? "整理显示器" : "DisplayDJ").font(.system(size: 12, weight: .medium))
      Spacer()
      if isEditing {
        Button("恢复物理顺序") { controller.resetOrderToPhysical() }
          .font(.system(size: 11)).buttonStyle(.borderless)
        Button("完成") { finishEditing() }.buttonStyle(.borderless)
      } else {
        RefreshFeedbackButton(isRefreshing: controller.isRefreshingFromToolbar,
          isDisabled: controller.isLoading || controller.isRestoringConnections) {
          await controller.refreshFromToolbar()
        }
        Menu {
          Button("整理显示器") {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { isEditing = true }
          }.disabled(controller.displays.isEmpty || controller.isLoading)
          Button("操作偏好…") { controller.showDisplayTools(section: .preferences) }
          Divider()
          Button("退出 DisplayDJ") { NSApplication.shared.terminate(nil) }
            .disabled(controller.isLoading || controller.isRestoringConnections)
        } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .focusable().focused($moreIsFocused).accessibilityLabel("更多操作")
      }
    }.padding(.top, 6).padding(.bottom, 10)
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      Divider().padding(.top, 8)
      if controller.displays.count > 1 {
        VStack(alignment: .leading, spacing: 4) {
          Toggle("同步调节亮度", isOn: Binding(
            get: { controller.isBrightnessSyncEnabled },
            set: { enabled in Task { await controller.setBrightnessSyncEnabled(enabled) } }))
            .toggleStyle(.switch).controlSize(.mini)
            .disabled(controller.isPreparingBrightnessSync || controller.isWriting || isEditing)
          if controller.isPreparingBrightnessSync {
            Text("正在检查各屏亮度").foregroundStyle(.secondary)
          } else if controller.isBrightnessSyncEnabled {
            Text("其他屏按相同百分点变化").foregroundStyle(.secondary)
          }
        }
      }
      if controller.brightnessSyncResults.values.contains(false) {
        Text("部分屏幕未完成，请查看对应提示").foregroundStyle(.orange)
          .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
      }
      if let title = controller.keyboardSummary {
        Button { controller.showDisplayTools(section: .preferences) } label: {
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(title)
              Text("操作偏好").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
          }.frame(minHeight: 38).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(title)，操作偏好")
      }
      Button { controller.showDisplayTools(section: .display) } label: {
        HStack { Text("显示设置…"); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
          .frame(minHeight: 28).contentShape(Rectangle())
      }.buttonStyle(.plain)
      if controller.isRestoringConnections {
        Label("正在恢复外屏，确认后退出…", systemImage: "arrow.triangle.2.circlepath")
          .foregroundStyle(.secondary)
      }
    }.font(.system(size: 12)).padding(.bottom, 2)
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("未检测到可控制的显示器", systemImage: "display")
      Text("连接显示器后刷新；恢复记录会单独保留。")
    }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20)
  }

  private func finishEditing() {
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { isEditing = false }
    Task { @MainActor in await Task.yield(); moreIsFocused = true }
  }
}
