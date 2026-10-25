import DisplayDJCore
import Foundation

enum LitePreviewBrightnessFailure: String, Sendable {
  case none, read, write
}

/// Memory-only UI preview. It never creates the live service or touches recovery files.
actor LitePreviewAccess: LiteConnectionAccess, LiteBrightnessAccess {
  nonisolated let unavailableReason: String? = nil
  var displays = [
    DisplayDescriptor(runtimeID: 1, stableID: "uuid:11111111-1111-1111-1111-111111111111",
                      name: "示例内建屏（模拟）", isBuiltIn: true, isVirtual: false, isMirrored: false),
    DisplayDescriptor(runtimeID: 2, stableID: "uuid:22222222-2222-2222-2222-222222222222",
                      name: "示例外屏 A（模拟）", isBuiltIn: false, isVirtual: false, isMirrored: false),
    DisplayDescriptor(runtimeID: 3, stableID: "uuid:33333333-3333-3333-3333-333333333333",
                      name: "示例镜像屏 B（模拟）", isBuiltIn: false, isVirtual: false, isMirrored: true),
  ]
  var records = [DisplayConnectionRecord(runtimeID: 4,
    stableID: "uuid:44444444-4444-4444-4444-444444444444", name: "示例恢复屏 C（模拟）")]
  private var brightnessValues: [String: Int] = [:]
  private let brightnessFailure: LitePreviewBrightnessFailure
  private var failureConsumed = false
  private let refreshDelay: Duration

  init(compact: Bool = false, brightnessFailure: LitePreviewBrightnessFailure = .none,
       refreshDelay: Duration = .zero) {
    self.brightnessFailure = brightnessFailure
    self.refreshDelay = refreshDelay
    if compact {
      displays = displays.filter { !$0.isMirrored }
      records = []
    }
  }

  func read(stableID: String) async throws -> Int {
    guard let display = displays.first(where: { $0.stableID == stableID }), !display.isMirrored else {
      throw LiteRefusal("模拟目标不在线或不支持调光。")
    }
    if !display.isBuiltIn, brightnessFailure == .read, !failureConsumed {
      failureConsumed = true
      throw LiteRefusal("模拟：未能读取外屏亮度，请重新读取。")
    }
    return brightnessValues[stableID] ?? (display.isBuiltIn ? 45 : 62)
  }

  func write(percent: Int, stableID: String) async throws -> Int {
    _ = try await read(stableID: stableID)
    try await Task.sleep(for: .milliseconds(400))
    _ = try await read(stableID: stableID)
    if displays.contains(where: { $0.stableID == stableID && !$0.isBuiltIn }),
       brightnessFailure == .write, !failureConsumed {
      failureConsumed = true
      throw LiteRefusal("模拟：未确认本次调节，请重新读取后重试。")
    }
    brightnessValues[stableID] = percent
    return percent
  }

  func snapshot() async throws -> LiteSnapshot {
    if refreshDelay > .zero { try await Task.sleep(for: refreshDelay) }
    return .init(displays: displays, records: records)
  }

  func change(_ state: DisplayConnectionState, stableID: String) async throws -> DisplayConnectionOutcome {
    try await Task.sleep(for: .milliseconds(450))
    if state == .disconnected, !records.isEmpty {
      throw LiteRefusal("请先恢复已有记录的示例，再断开另一台。")
    }
    let target: DisplayDescriptor
    if state == .disconnected, let display = displays.first(where: { $0.stableID == stableID }) {
      if let reason = LiteConnectionService.refusal(for: display, in: displays) { throw LiteRefusal(reason) }
      target = display
      records.append(.init(runtimeID: display.runtimeID, stableID: display.stableID, name: display.name))
      displays.removeAll { $0.stableID == stableID }
    } else if state == .connected, let record = records.first(where: { $0.stableID == stableID }) {
      target = displays.first(where: { $0.stableID == stableID }) ?? .init(runtimeID: record.runtimeID,
        stableID: record.stableID, name: record.name, isBuiltIn: false, isVirtual: false, isMirrored: false)
      if !displays.contains(where: { $0.stableID == stableID }) { displays.append(target) }
      records.removeAll { $0.stableID == stableID }
    } else { throw LiteRefusal("预览目标不存在。") }
    return .init(display: target, requestedState: state, observedState: state, wasVerified: true)
  }
}
