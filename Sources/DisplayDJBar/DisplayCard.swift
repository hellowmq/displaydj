import DisplayDJCore
import SwiftUI

struct DisplayCard: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let display: DisplayDescriptor
  @ObservedObject var controller: DisplayBarController
  let isEditing: Bool
  @State private var sliderValue: Double
  @State private var isDragging = false
  @FocusState private var aliasIsFocused: Bool

  init(display: DisplayDescriptor, controller: DisplayBarController, isEditing: Bool) {
    self.display = display; self.controller = controller; self.isEditing = isEditing
    _sliderValue = State(initialValue: Double(controller.displayedBrightness(for: display.stableID ?? "") ?? 0))
  }
  private var id: String { display.stableID ?? "" }
  private var name: String { controller.alias(for: display) }
  private var selected: Bool { controller.selectedDisplayKey == display.selectionKey }
  private var reading: Int? { controller.displayedBrightness(for: id) }
  private var status: String? {
    if isDragging { return "调节中" }
    if let feedback = controller.brightnessFeedback[id] { return feedback.message }
    if reading == nil && controller.failure(for: display.selectionKey) == nil { return "正在读取亮度" }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Button { if !isEditing { controller.selectDisplay(key: display.selectionKey) } } label: {
          Text(name).font(.system(size: 13, weight: .medium))
            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(isEditing).help(name)
        .accessibilityLabel("\(name)，设为菜单栏滚轮目标")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        BrightnessReadout(value: isDragging ? Int(sliderValue.rounded()) : reading)
        if !isEditing { DisplayConnectionButton(display: display, controller: controller) }
      }
      if isEditing {
        HStack {
          Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).help("拖动调整顺序")
          TextField("别名（留空使用系统名称）", text: Binding(
            get: { controller.preferences.aliases[id] ?? "" },
            set: { controller.setAlias($0, forStableID: id) }))
            .textFieldStyle(.roundedBorder).focused($aliasIsFocused)
            .disabled(id.isEmpty)
            .onAppear {
              if controller.displays.first?.selectionKey == display.selectionKey {
                Task { @MainActor in await Task.yield(); aliasIsFocused = true }
              }
            }
            .accessibilityLabel("\(name) 的显示器别名")
          Button { controller.moveDisplay(display, offset: -1) } label: { Image(systemName: "chevron.up") }
            .disabled(controller.displays.first?.selectionKey == display.selectionKey || id.isEmpty)
            .accessibilityLabel("上移 \(name)")
          Button { controller.moveDisplay(display, offset: 1) } label: { Image(systemName: "chevron.down") }
            .disabled(controller.displays.last?.selectionKey == display.selectionKey || id.isEmpty)
            .accessibilityLabel("下移 \(name)")
        }.controlSize(.small)
        Text("别名留空使用系统名称").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      BrightnessSlider(value: $sliderValue,
        isEnabled: controller.canAdjustRelatively(id) && !controller.isChangingConnection && !controller.isRestoringConnections,
        hasReading: controller.canAdjustRelatively(id), isDragging: $isDragging,
        onDragChanged: { value in Task { await controller.setBrightness(value, for: id) } },
        onCommit: { value in Task { await controller.setBrightness(value, for: id) } })
        .disabled(isEditing || controller.isPreparingBrightnessSync || controller.isRestoringConnections)
      VStack(alignment: .leading, spacing: 3) {
        if selected && ScrollTargetBadge.shows(displayCount: controller.displays.count) {
          Text(ScrollTargetBadge.title).foregroundStyle(DisplayDJBrandColor.controlAccent)
        }
        Text(status ?? " ").foregroundStyle(.secondary)
          .accessibilityHidden(status == nil)
      }.font(.system(size: 11)).frame(minHeight: 15, alignment: .topLeading)
      if controller.brightnessFeedback[id]?.isFailure == true, controller.brightnessByID[id] != nil {
        Text("百分比为上次确认值").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      if let failure = controller.failure(for: display.selectionKey) {
        FailureBanner(failure: failure, controller: controller)
      }
      if controller.connectionTargetKey == display.selectionKey, controller.isChangingConnection {
        Label("正在断开…", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 12)).foregroundStyle(.secondary)
      }
      if let notice = controller.connectionNotice, notice.id == display.selectionKey {
        ConnectionNoticeRow(notice: notice)
      }
    }
    .padding(8)
    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? DisplayDJBrandColor.controlAccent.opacity(0.07) : Color.clear))
    .onAppear { sync(.cardAppeared) }
    .onChange(of: reading) { _ in sync(.readingChanged) }
    .onChange(of: isEditing) { editing in
      aliasIsFocused = editing && controller.displays.first?.selectionKey == display.selectionKey
    }
    .accessibilityElement(children: .contain).accessibilityLabel("\(name) 亮度控制")
  }

  private func sync(_ occasion: SliderSync.Occasion) {
    guard case .adopt(let value, let animated) = SliderSync.resolve(reading: reading, isDragging: isDragging, occasion: occasion) else { return }
    if animated && !reduceMotion { withAnimation(.easeOut(duration: 0.15)) { sliderValue = value } }
    else { sliderValue = value }
  }
}
