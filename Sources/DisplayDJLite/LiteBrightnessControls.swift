import SwiftUI

struct LiteBrightnessControls: View {
  @ObservedObject var model: LiteModel
  @ObservedObject var brightness: LiteBrightnessModel
  let id: String
  let name: String
  @State private var draft: Double = 0
  @State private var dragging = false
  @Environment(\.colorScheme) private var colorScheme

  private var value: Int? { dragging ? Int(draft.rounded()) : brightness.value(for: id) }
  private var valueDescription: String { brightness.valueDescription(for: id, dragging: dragging) }
  private var sliderValue: Binding<Double> {
    Binding(get: { Double(value ?? 0) }, set: { draft = $0 })
  }
  private var enabled: Bool {
    brightness.canAdjust(id) && !model.isRefreshing && model.busyID == nil && !model.isRestoringBeforeQuit
  }
  private var failure: String? {
    if case .failed(let message) = brightness.feedback[id] { return message }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline) {
        Text("硬件亮度").font(.system(size: 11)).foregroundStyle(.secondary)
        Spacer()
        ZStack(alignment: .trailing) {
          HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("100").font(.system(size: 18, weight: .semibold, design: .monospaced)).lineLimit(1)
            Text("%").font(.system(size: 11)).lineLimit(1)
          }
          .hidden()
          .accessibilityHidden(true)

          HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(value.map(String.init) ?? "—")
              .font(.system(size: 18, weight: .semibold, design: .monospaced))
              .lineLimit(1)
            if value != nil {
              Text("%").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
          }
          .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(valueDescription)")
        .accessibilityValue(value.map { "\($0)%" } ?? "未知")
      }
      LiteBrightnessSlider(value: sliderValue, dragging: $dragging, enabled: enabled,
        hasReading: value != nil, name: name) { target in
          Task { await model.setBrightness(target, for: id) }
        }.frame(height: 44)
      if let failure {
        Text(failure)
          .font(.system(size: 11)).foregroundStyle(LiteFeedbackColor.warning(for: colorScheme))
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          Button("重新读取") { Task { await model.rereadBrightness(id) } }
            .buttonStyle(.link).font(.system(size: 11)).disabled(!model.canRereadBrightness(id))
            .accessibilityLabel("重新读取 \(name) 的亮度")
        }
      }
    }
    .onDisappear { dragging = false }
  }
}
