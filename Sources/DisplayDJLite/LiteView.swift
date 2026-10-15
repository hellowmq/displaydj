import SwiftUI

struct LiteView: View {
  @ObservedObject var model: LiteModel
  let isPreview: Bool
  let quit: () -> Void
  let perform: (LiteDisplayRow) -> Void
  @State private var showsHelp = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 5) {
          Text(isPreview ? "模拟演示 · DisplayDJ Lite" : "DisplayDJ Lite").font(.system(size: 13, weight: .semibold))
          Text(summary).font(.system(size: 12))
            .foregroundStyle(model.quitRecoveryFailed ? Color.orange : Color.secondary)
        }
        Spacer()
        Button { Task { await model.refresh() } } label: {
          Group {
            if model.isRefreshing { ProgressView().controlSize(.mini) }
            else { Image(systemName: "arrow.clockwise") }
          }.frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless).disabled(model.isBusy)
        .accessibilityLabel("刷新显示器").help("刷新显示器（⌘R）")
        .keyboardShortcut("r", modifiers: .command)
      }
      .padding(.bottom, 16)

      if isPreview {
        Label("虚构示例 · 未读取本机设备", systemImage: "testtube.2")
          .font(.caption).foregroundStyle(.orange).padding(.bottom, 12)
      }
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
      }

      if model.rows.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          if model.isRefreshing || !model.hasLoaded { ProgressView().controlSize(.small) }
          else { Image(systemName: "display").foregroundStyle(.secondary) }
          Text(emptyMessage).font(.callout).foregroundStyle(.secondary)
          if model.hasLoaded && !model.isRefreshing && model.error == nil {
            Text("接上外屏后刷新。这里仅显示外屏和 Lite 保存的恢复入口。")
              .font(.system(size: 12)).foregroundStyle(.secondary)
          }
        }.padding(.vertical, 22)
      } else if model.rows.count <= 3 {
        displayRows
      } else {
        ScrollView { displayRows }.frame(height: 330)
      }

      Divider().padding(.top, 12)
      HStack(spacing: 16) {
        Button { showsHelp.toggle() } label: { Label("连接说明", systemImage: "questionmark.circle") }
          .buttonStyle(.borderless).accessibilityLabel("连接操作说明")
          .popover(isPresented: $showsHelp) {
            VStack(alignment: .leading, spacing: 10) {
              Text("DisplayDJ Lite").font(.headline)
              Text("版本 \(LiteIdentity.version)").font(.caption).foregroundStyle(.secondary)
              Divider()
              Text(isPreview ? "当前示例全部虚构。操作只改变模拟数据，不代表真实连接结果。" :
                "断开后，窗口会移到其他在线屏幕；这不等于关闭显示器电源，也不会切换它的输入源。")
              Text(isPreview ? "关闭演示后，模拟数据会重置，不写入真实恢复记录。" : "退出前会恢复并确认外屏；失败会取消退出并保留记录。卸载或覆盖安装前请先恢复并退出。")
              if !isPreview {
                Text("新断开仅在本应用运行期间生效。异常结束后仍无画面时，重新接线，在系统显示器设置中检测；必要时保存工作并重启 Mac。")
              }
              Text("内建屏、镜像屏及最后一块在线屏幕受到保护。")
              if !isPreview {
                Link("恢复、覆盖安装与卸载说明", destination: URL(string: "https://github.com/hellowmq/displaydj/blob/master/docs/LITE-RECOVERY.md")!)
              }
            }.font(.callout).padding(18).frame(width: 280)
          }
        Spacer()
        Button("退出", action: quit)
          .buttonStyle(.borderless)
          .disabled(!model.canQuit)
          .accessibilityLabel("退出 DisplayDJ Lite")
          .keyboardShortcut("q", modifiers: .command)
      }
      .font(.system(size: 12)).padding(.top, 10).padding(.vertical, 4)
    }
    .padding(16).frame(width: 360)
  }

  private var summary: String {
    if model.isRestoringBeforeQuit { return "正在恢复外屏，全部确认后退出…" }
    if model.quitRecoveryFailed { return "恢复未完成，已取消退出" }
    guard model.hasLoaded else { return isPreview ? "正在载入模拟状态…" : "正在读取当前连接…" }
    if model.error != nil { return "连接状态暂未确认" }
    let online = model.rows.filter(\.isOnline).count
    let offline = model.rows.count - online
    return offline == 0 ? "\(online) 台外屏已连接" : "\(online) 台已连接 · \(offline) 台待恢复"
  }

  private var emptyMessage: String {
    if !model.hasLoaded || model.isRefreshing { return isPreview ? "正在载入模拟状态…" : "正在查找外接显示器…" }
    if model.error != nil { return "请刷新以重新确认列表。" }
    return isPreview ? "没有更多模拟示例" : "没有外接显示器"
  }

  private var displayRows: some View {
    VStack(spacing: 0) {
      ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
        if index > 0 { Divider() }
        LiteDisplayRowView(model: model, row: row, isPreview: isPreview, perform: perform)
      }
    }
  }
}

private struct LiteDisplayRowView: View {
  @ObservedObject var model: LiteModel
  let row: LiteDisplayRow
  let isPreview: Bool
  let perform: (LiteDisplayRow) -> Void
  @Environment(\.colorScheme) private var colorScheme
  private var accent: Color { colorScheme == .dark ? .cyan : Color(red: 0, green: 0.38, blue: 0.52) }
  private var pending: Bool { model.busyID == row.id }
  private var failure: String? {
    if case .failed(let message) = model.feedback[row.id] { return message }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 12) {
        Image(systemName: "display")
          .font(.system(size: 18, weight: .regular))
          .foregroundStyle(row.isOnline ? Color.primary : Color.secondary)
          .frame(width: 28, height: 32)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 5) {
          Text(row.name).font(.system(size: 13, weight: .medium)).lineLimit(2).help(row.name)
          HStack(spacing: 5) {
            Circle().fill(statusColor).frame(width: 5, height: 5).accessibilityHidden(true)
            Text((isPreview ? "模拟 · " : "") + statusText)
              .font(.system(size: 12)).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          if model.rows.filter({ $0.name == row.name }).count > 1 {
            Text("屏幕编号 \(row.runtimeID)").font(.caption2).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 2)
        Group {
          if row.action == .connected {
            actionButton.buttonStyle(.borderedProminent).tint(accent)
          } else {
            actionButton.buttonStyle(.bordered)
          }
        }
        .disabled(model.isBusy || model.error != nil || row.refusal != nil)
        .accessibilityLabel("\(isPreview ? "模拟" : "")\(actionTitle) \(row.name)")
        .help(row.action == .disconnected ? "将这块屏幕从当前 Mac 的桌面中移除" : "恢复这块屏幕在当前 Mac 上的桌面连接")
      }
      if let explanation = row.refusal ?? failure {
        Label((isPreview ? "模拟提示：" : "") + explanation, systemImage: "exclamationmark.circle")
          .font(.system(size: 12)).foregroundStyle(failure == nil ? Color.secondary : Color.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }.padding(.vertical, 15)
  }

  private var actionButton: some View {
    Button { perform(row) } label: {
      HStack(spacing: 5) {
        if pending { ProgressView().controlSize(.mini) }
        Text((isPreview ? "模拟" : "") + actionTitle)
      }.font(.system(size: 12, weight: .medium)).frame(width: isPreview ? 94 : 78, height: 22)
    }
  }

  private var statusColor: Color {
    if pending { return .orange }
    if failure != nil || row.refusal != nil { return .secondary }
    return row.isOnline ? .green : .secondary
  }

  private var statusText: String {
    if pending { return row.action == .connected ? "正在恢复连接…" : "正在断开…" }
    if row.hasRecoveryRecord && row.isOnline { return "已在线，待确认恢复" }
    if case .confirmed(let state) = model.feedback[row.id], (state == .connected) == row.isOnline {
      return state == .connected ? "已恢复连接" : "已断开，可恢复"
    }
    return row.isOnline ? "已连接" : "有恢复记录，可尝试连接"
  }

  private var actionTitle: String {
    if pending { return "处理中" }
    if row.action == .connected {
      if row.isOnline { return "确认恢复" }
      return failure == nil ? "重新连接" : "重试连接"
    }
    return failure == nil ? "断开" : "重试断开"
  }
}
