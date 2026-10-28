import Combine
import DisplayDJCore
import Foundation

enum LiteBrightnessFeedback: Equatable {
  case reading, confirming, confirmed
  case failed(String)

  var message: String {
    switch self {
    case .reading: "正在读取亮度"
    case .confirming: "正在确认"
    case .confirmed: "已确认"
    case .failed(let reason): reason
    }
  }
}

@MainActor
final class LiteBrightnessModel: ObservableObject {
  @Published private(set) var confirmed: [String: Int] = [:]
  @Published private(set) var intended: [String: Int] = [:]
  @Published private(set) var feedback: [String: LiteBrightnessFeedback] = [:]
  @Published private(set) var isWriting = false
  @Published private(set) var isReading = false
  private let access: any LiteBrightnessAccess
  private var eligible: [String: UInt32] = [:]
  private var epochs: [String: UInt64] = [:]
  private var nextEpoch: UInt64 = 0
  private var pending: [(id: String, value: Int)] = []
  private var worker: Task<Void, Never>?
  private var dismissals: [String: Task<Void, Never>] = [:]
  private var generation: UInt64 = 0
  private var needsReadAfterWrite = false
  var isWorking: Bool { isReading || isWriting }
  var hasReadFailures: Bool { eligible.keys.contains { confirmed[$0] == nil } }

  init(access: any LiteBrightnessAccess) { self.access = access }

  func value(for id: String) -> Int? { intended[id] ?? confirmed[id] }
  func canAdjust(_ id: String) -> Bool { eligible[id] != nil && value(for: id) != nil && !isReading }
  func canReread(_ id: String) -> Bool { eligible[id] != nil && !isWorking }

  func valueDescription(for id: String, dragging: Bool = false) -> String {
    if dragging || intended[id] != nil { return "目标亮度" }
    if confirmed[id] == nil { return "亮度未知" }
    if feedback[id] == .reading { return "上次确认亮度" }
    if case .failed = feedback[id] { return "上次确认亮度" }
    return "已确认亮度"
  }

  /// A row's retry belongs only to that screen, leaving other feedback intact.
  func reread(_ id: String) async {
    guard canReread(id) else { return }
    generation &+= 1
    let pass = generation
    isReading = true
    defer { if pass == generation { isReading = false } }
    await readValue(id, pass: pass)
  }

  /// Snapshot reconciliation never writes. A detached/replaced target loses its
  /// pending intentions, and old results cannot repopulate its new incarnation.
  func refresh(displays: [DisplayDescriptor]) async {
    generation &+= 1
    let pass = generation
    let groups = Dictionary(grouping: displays.compactMap { display -> (String, DisplayDescriptor)? in
      guard let id = LiteIdentity.stableID(display.stableID) else { return nil }
      return (id, display)
    }, by: { $0.0 })
    let next = groups.compactMapValues { group -> UInt32? in
      guard group.count == 1, let display = group.first?.1,
            !display.isMirrored, display.isVirtual == false else { return nil }
      return display.runtimeID
    }
    let retained = Set(next.keys.filter { eligible[$0] == next[$0] })
    confirmed = confirmed.filter { retained.contains($0.key) }
    intended = intended.filter { retained.contains($0.key) }
    pending = pending.filter { retained.contains($0.id) }
    for id in Array(feedback.keys) where !retained.contains(id) {
      dismissals[id]?.cancel(); dismissals[id] = nil; feedback[id] = nil
    }
    eligible = next
    epochs = epochs.filter { next[$0.key] != nil }
    for id in next.keys where !retained.contains(id) {
      nextEpoch &+= 1
      epochs[id] = nextEpoch
    }
    for (id, group) in groups where next[id] == nil {
      let reason = group.count > 1 ? "屏幕身份重复，暂不能安全调节。" :
        group.first?.1.isMirrored == true ? "镜像屏幕暂不提供亮度调节。" : "这类屏幕暂不支持硬件亮度调节。"
      feedback[id] = .failed(reason)
    }
    guard !isWriting else { return }
    isReading = true
    defer { if generation == pass { isReading = false } }
    for id in next.keys.sorted() {
      guard pass == generation else { return }
      await readValue(id, pass: pass)
    }
  }

  private func readValue(_ id: String, pass: UInt64) async {
    dismissals[id]?.cancel(); dismissals[id] = nil
    feedback[id] = .reading
    do {
      let value = try await access.read(stableID: id)
      guard pass == generation else { return }
      guard (0...100).contains(value) else { throw LiteRefusal("屏幕未返回有效亮度。") }
      confirmed[id] = value
      feedback[id] = nil
    } catch {
      guard pass == generation else { return }
      SupportDiagnosticEvents.shared.record(error, operation: .read, stableID: id)
      confirmed[id] = nil
      feedback[id] = .failed(Self.reason(error, reading: true))
    }
  }

  func invalidate(clearReadings: Bool = false) {
    if clearReadings && isWriting { needsReadAfterWrite = true }
    let affected = Set(confirmed.keys).union(intended.keys).union(feedback.keys)
    generation &+= 1
    eligible = [:]; epochs = [:]; pending = []; intended = [:]
    if clearReadings { confirmed = [:] }
    isReading = false
    for id in affected {
      dismissals[id]?.cancel(); dismissals[id] = nil
      feedback[id] = clearReadings ? .reading : .failed("屏幕状态未确认，请刷新重试。")
    }
  }

  func set(_ value: Int, for id: String) async {
    guard (0...100).contains(value), canAdjust(id) else { return }
    dismissals[id]?.cancel(); dismissals[id] = nil
    intended[id] = value
    feedback[id] = .confirming
    if let index = pending.firstIndex(where: { $0.id == id }) { pending[index].value = value }
    else { pending.append((id, value)) }
    if let worker { await worker.value; return }
    isWriting = true
    let task = Task<Void, Never> { @MainActor [weak self] in
      guard let self else { return }
      await self.drain()
    }
    worker = task
    await task.value
  }

  private func drain() async {
    while !pending.isEmpty {
      let request = pending.removeFirst()
      let identity = epochs[request.id]
      do {
        let actual = try await access.write(percent: request.value, stableID: request.id)
        guard identity != nil, epochs[request.id] == identity else { continue }
        guard (0...100).contains(actual) else { throw LiteRefusal("屏幕返回了无效亮度，未确认本次调节。") }
        confirmed[request.id] = actual
        guard !pending.contains(where: { $0.id == request.id }) else { continue }
        intended[request.id] = nil
        feedback[request.id] = .confirmed
        dismissals[request.id] = Task { @MainActor [weak self] in
          try? await Task.sleep(for: .milliseconds(1200))
          guard !Task.isCancelled else { return }
          self?.feedback[request.id] = nil
          self?.dismissals[request.id] = nil
        }
      } catch {
        SupportDiagnosticEvents.shared.record(error, operation: .write, stableID: request.id)
        guard identity != nil, epochs[request.id] == identity,
              !pending.contains(where: { $0.id == request.id }) else { continue }
        intended[request.id] = nil
        feedback[request.id] = .failed(Self.reason(error, reading: false))
      }
    }
    isWriting = false
    worker = nil
    // A topology refresh can replace the identity epoch while the old write is
    // still completing. Re-read those targets once it finishes; do not leave
    // them on an unconfirmed placeholder until another user action.
    guard needsReadAfterWrite else { return }
    needsReadAfterWrite = false
    let missing = eligible.keys.filter { confirmed[$0] == nil }.sorted()
    guard !missing.isEmpty else { return }
    let pass = generation
    isReading = true
    defer { if pass == generation { isReading = false } }
    for id in missing {
      guard pass == generation else { return }
      await readValue(id, pass: pass)
    }
  }

  private static func reason(_ error: Error, reading: Bool) -> String {
    if let refusal = error as? LiteRefusal { return refusal.message }
    return reading ? "无法读取硬件亮度，请重试；未启用软件调光。" : "未确认本次调节，请重新读取后重试。"
  }
}
