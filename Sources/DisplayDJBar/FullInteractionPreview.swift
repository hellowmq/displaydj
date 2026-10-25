import DisplayDJCore
import Foundation
import VibeDisplayCore

/// Explicit, memory-only review scene. Never constructed by normal startup.
final class FullInteractionPreview: DisplayDiscovering, DisplayConfigurationTransactionApplying, BrightnessBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var panels: [DisplayDescriptor]
  private var online: Set<UInt32>
  private var levels: [UInt32: Double] = [:]
  let transport = BrightnessTransport.displayServices

  init(count: Int = 6) {
    var configuredPanels: [DisplayDescriptor] = []
    for index in 1...max(1, count) {
      let runtimeID = UInt32(index)
      let stableID = String(format: "uuid:aaaaaaaa-aaaa-aaaa-aaaa-%012d", index)
      let name: String
      switch index {
      case 1: name = "示例内建屏（模拟）"
      case 2: name = "工作屏（模拟）"
      default: name = "长名称外接显示器 \(index)（模拟）"
      }
      let panel = DisplayDescriptor(runtimeID: runtimeID, stableID: stableID, name: name,
        isBuiltIn: index == 1, isVirtual: false, isMirrored: false)
      configuredPanels.append(panel)
    }
    panels = configuredPanels
    online = Set(panels.map(\.runtimeID))
  }
  func discoverDisplays() async throws -> [DisplayDescriptor] { snapshot() }
  private func snapshot() -> [DisplayDescriptor] {
    lock.lock(); defer { lock.unlock() }; return panels.filter { online.contains($0.runtimeID) }
  }
  func setEnabled(_ enabled: Bool, forRuntimeID runtimeID: UInt32) throws {
    lock.lock(); defer { lock.unlock() }
    if enabled { online.insert(runtimeID) } else { online.remove(runtimeID) }
  }
  func supports(_ display: DisplayInfo) -> Bool { true }
  func read(_ display: DisplayInfo) -> Double? {
    lock.lock(); defer { lock.unlock() }; return levels[display.id] ?? 0.45
  }
  func write(_ display: DisplayInfo, value: Double) -> Bool {
    lock.lock(); defer { lock.unlock() }; levels[display.id] = value; return true
  }
  func brightness(_ id: String, value: Double? = nil) -> Double {
    lock.lock(); defer { lock.unlock() }
    let runtime = panels.first { $0.stableID == id }?.runtimeID ?? 0
    if let value { levels[runtime] = value / 100 }
    return (levels[runtime] ?? 0.62) * 100
  }

  @MainActor func configure(_ controller: DisplayBarController, refreshDelayMilliseconds: Int = 0) {
    controller.isInteractionPreview = true
    controller.previewRefreshDelayMilliseconds = min(5000, max(0, refreshDelayMilliseconds))
    controller.displayDiscovery = self
    let store = InMemoryDisplayConnectionRecordStore()
    controller.connectionStore = store
    controller.preferencesStore = InMemoryDisplayPreferencesStore()
    controller.connectionControllerFactory = { [self] in
      DisplayConnectionController(discovery: self, transaction: self, store: store,
        ledger: DisplayConnectionIntentLedger(store: InMemoryDisplayConnectionIntentStore()),
        verificationAttempts: 1, verificationDelay: .zero)
    }
    let qaState = FileManager.default.temporaryDirectory.appendingPathComponent("displaydj-preview-" + UUID().uuidString).appendingPathComponent("state.json")
    controller.brightnessAccess.coordinator = BrightnessCoordinator(store: StateStore(url: qaState))
    controller.brightnessAccess.discovery = self
    controller.brightnessAccess.nativeBackend = self
    controller.brightnessAccess.readDDC = { [self] id in brightness(id) }
    controller.brightnessAccess.writeDDC = { [self] value, id in
      try await Task.sleep(for: .milliseconds(400))
      return brightness(id, value: value)
    }
  }
}
