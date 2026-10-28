import AppKit
import DisplayDJCore
import SwiftUI
import VibeDisplayCore

public struct DiagnosticExportButton: View {
  private let product: DiagnosticProduct
  private let version: String
  private let store: any DisplayConnectionRecordStoring
  private let keyboard: SupportDiagnosticReport.Keyboard?
  private let simulated: Bool
  @ObservedObject private var exporter = DiagnosticExporter.shared

  public init(product: DiagnosticProduct, version: String, store: any DisplayConnectionRecordStoring,
    keyboard: SupportDiagnosticReport.Keyboard? = nil, simulated: Bool = false) {
    self.product = product; self.version = version; self.store = store
    self.keyboard = keyboard; self.simulated = simulated
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Button(exporter.isWorking ? "正在生成诊断…" : "导出诊断…") {
          exporter.chooseDirectory(product: product, version: version, store: store, keyboard: keyboard)
        }.disabled(exporter.isWorking || simulated)
        if exporter.isWorking {
          ProgressView().controlSize(.small)
          Button("取消") { exporter.cancel() }
        }
      }
      if !exporter.message.isEmpty { Text(exporter.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }
  }

}

/// The task outlives Lite's transient help popover, so reopening help can still
/// show progress or cancel the same export instead of starting another one.
@MainActor
private final class DiagnosticExporter: ObservableObject {
  static let shared = DiagnosticExporter()
  @Published private(set) var isWorking = false
  @Published private(set) var message = ""
  private var task: Task<Void, Never>?

  func cancel() { task?.cancel() }

  func chooseDirectory(product: DiagnosticProduct, version: String,
    store: any DisplayConnectionRecordStoring, keyboard: SupportDiagnosticReport.Keyboard?) {
    guard !isWorking else { return }
    isWorking = true
    let panel = NSOpenPanel()
    panel.title = "保存 DisplayDJ 诊断"
    panel.message = "选择保存位置。报告已脱敏，只读检查设备，不会自动上传。"
    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false; panel.prompt = "保存诊断"
    panel.begin { response in
      guard response == .OK, let directory = panel.url else { self.isWorking = false; return }
      self.message = ""
      self.task = Task { @MainActor in
        defer { self.isWorking = false; self.task = nil }
        do {
          let report = try await SupportDiagnosticCollector(discovery: CoreGraphicsDisplayDiscovery(), store: store,
            readBrightness: Self.readBrightness).collect(product: product, version: version,
              build: Bundle.main.object(forInfoDictionaryKey: "DisplayDJSourceRevision") as? String ?? "unknown",
              keyboard: keyboard)
          try Task.checkCancellation()
          let folder = try report.save(in: directory)
          self.message = "已保存诊断报告"
          NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch is CancellationError { self.message = "已取消生成诊断" }
        catch { self.message = "诊断未能完整保存，请检查保存位置后重试。" }
      }
    }
  }

  private static func readBrightness(_ display: DisplayDescriptor) async -> DiagnosticBrightness {
    let transport: BackendKind = display.isBuiltIn ? .nativeBrightness : .appleSiliconDDC
    guard !display.isMirrored, display.isVirtual == false else { return .init(transport: transport, state: .notChecked) }
    if display.isBuiltIn {
      // A new read-only backend; never use BrightnessService's fallback routing.
      let backend = DisplayServicesBackend()
      guard backend.isAvailable else { return .init(transport: transport, state: .unavailable) }
      let info = DisplayInfo(id: display.runtimeID, uuid: "", slug: "", name: "", isBuiltin: true,
        isMain: false, vendorID: 0, modelID: 0, serialNumber: 0, index: 0, width: 0, height: 0)
      return .init(transport: transport, state: backend.read(info) == nil ? .failed : .supported)
    }
    guard let id = display.stableID else { return .init(transport: transport, state: .unknown) }
    do {
      _ = try await AppleSiliconDDCBrightnessReader().read(fromStableID: id)
      return .init(transport: transport, state: .supported)
    } catch {
      let code = (error as? DisplayDJError)?.code ?? .internalFailure
      let state: DiagnosticReadState = code == .unsupported ? .unsupported : code == .backendUnavailable ? .unavailable : .failed
      return .init(transport: transport, state: state, error: code)
    }
  }
}
