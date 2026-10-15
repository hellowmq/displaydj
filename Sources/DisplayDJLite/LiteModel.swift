import Combine
import DisplayDJCore
import Foundation

struct LiteDisplayRow: Identifiable {
  let id: String
  let stableID: String?
  let runtimeID: UInt32
  let name: String
  let isOnline: Bool
  let hasRecoveryRecord: Bool
  let refusal: String?
  var action: DisplayConnectionState { hasRecoveryRecord ? .connected : .disconnected }
}

enum LiteOperationFeedback: Equatable {
  case pending(DisplayConnectionState)
  case confirmed(DisplayConnectionState)
  case failed(String)

  var message: String {
    switch self {
    case .pending(.disconnected): "正在断开…"
    case .pending(.connected): "正在重新连接…"
    case .confirmed(.disconnected): "已确认退出桌面"
    case .confirmed(.connected): "已确认重新连接"
    case .failed(let message): message
    }
  }
}

@MainActor
final class LiteModel: ObservableObject {
  @Published private(set) var rows: [LiteDisplayRow] = []
  @Published private(set) var isRefreshing = false
  @Published private(set) var busyID: String?
  @Published private(set) var error: String?
  @Published private(set) var feedback: [String: LiteOperationFeedback] = [:]
  @Published private(set) var hasLoaded = false
  @Published private(set) var pendingRecoveryCount = 0
  @Published private(set) var isRestoringBeforeQuit = false
  @Published private(set) var quitRecoveryFailed = false
  var notices: [String: String] { feedback.mapValues(\.message) }
  private let access: any LiteConnectionAccess
  private var refreshAgain = false
  private var rowOrder: [String: Int] = [:]
  var isBusy: Bool { isRefreshing || busyID != nil || isRestoringBeforeQuit }
  var canQuit: Bool { !isBusy }

  init(access: any LiteConnectionAccess) { self.access = access }

  func refresh() async {
    guard !isRestoringBeforeQuit else { refreshAgain = true; return }
    await refreshRows()
  }

  private func refreshRows() async {
    guard !isRefreshing, busyID == nil else { refreshAgain = true; return }
    repeat {
      refreshAgain = false
      isRefreshing = true
      do {
        let snapshot = try await access.snapshot()
        pendingRecoveryCount = snapshot.records.count
        let fresh = Self.rows(from: snapshot, unavailableReason: access.unavailableReason)
        for row in fresh where rowOrder[row.id] == nil { rowOrder[row.id] = rowOrder.count }
        rows = fresh.sorted { rowOrder[$0.id, default: 0] < rowOrder[$1.id, default: 0] }
        for row in rows {
          if case .confirmed(let state) = feedback[row.id],
             (state == .connected) != row.isOnline { feedback[row.id] = nil }
        }
        error = access.unavailableReason
        if pendingRecoveryCount == 0, error == nil, !isRestoringBeforeQuit { quitRecoveryFailed = false }
      } catch {
        if let coded = error as? DisplayDJError, coded.details["phase"] == "record-load" {
          self.error = "恢复记录无法读取，已暂停操作。记录仍保留，请刷新重试。"
        } else {
          self.error = "无法刷新显示器列表，已暂停操作。请刷新重试。"
        }
        // Retain existing recovery rows, but disable actions until a fresh read succeeds.
      }
      hasLoaded = true
      isRefreshing = false
    } while refreshAgain
  }

  func perform(_ row: LiteDisplayRow) async {
    guard !isBusy else { return }
    _ = await apply(row)
  }

  private func apply(_ row: LiteDisplayRow) async -> Bool {
    guard error == nil, row.refusal == nil, let id = row.stableID else { return false }
    var succeeded = false
    busyID = row.id
    feedback[row.id] = .pending(row.action)
    do {
      let outcome = try await access.change(row.action, stableID: id)
      guard outcome.wasVerified, outcome.observedState == row.action else {
        throw LiteRefusal("请求已发送，但没有确认目标状态；请刷新后重试。")
      }
      feedback[row.id] = .confirmed(outcome.observedState)
      succeeded = true
    } catch {
      feedback[row.id] = .failed(Self.failureMessage(error))
    }
    busyID = nil
    await refreshRows()
    return succeeded && error == nil
  }

  /// Only recover targets in Lite's own store. Exit is authorized by the caller
  /// after this returns true, never merely after requests have been sent.
  func restoreForQuit() async -> Bool {
    guard !isBusy else { return false }
    isRestoringBeforeQuit = true
    quitRecoveryFailed = false
    var readyToQuit = false
    defer {
      isRestoringBeforeQuit = false
      quitRecoveryFailed = !readyToQuit
    }
    await refreshRows()
    guard error == nil else { return false }
    let targets = rows.filter(\.hasRecoveryRecord).map(\.id)
    for id in targets {
      guard let row = rows.first(where: { $0.id == id }), row.hasRecoveryRecord else { continue }
      if let refusal = row.refusal {
        feedback[id] = .failed(refusal)
        return false
      }
      guard await apply(row) else { return false }
    }
    await refreshRows()
    guard error == nil else { return false }
    guard pendingRecoveryCount == 0 else {
      error = "仍有恢复记录未确认，已保留记录并取消退出。"
      return false
    }
    readyToQuit = true
    return true
  }

  static func rows(from snapshot: LiteSnapshot, unavailableReason: String?) -> [LiteDisplayRow] {
    var rows = snapshot.displays.filter { !$0.isBuiltIn }.map { display in
      let hasRecord = snapshot.records.contains {
        LiteIdentity.stableID($0.stableID) != nil && LiteIdentity.stableID($0.stableID) == LiteIdentity.stableID(display.stableID)
      }
      return LiteDisplayRow(id: LiteIdentity.stableID(display.stableID) ?? "runtime:\(display.runtimeID)",
                     stableID: LiteIdentity.stableID(display.stableID), runtimeID: display.runtimeID,
                     name: display.name, isOnline: true, hasRecoveryRecord: hasRecord,
                     refusal: unavailableReason ?? LiteConnectionService.refusal(for: display, in: snapshot.displays,
                                                                               disconnecting: !hasRecord) ??
                       (!hasRecord && !snapshot.records.isEmpty ? "请先恢复已有记录的外屏，再断开另一台。" : nil))
    }
    for record in snapshot.records.sorted(by: { $0.disconnectedAt < $1.disconnectedAt }) {
      let id = LiteIdentity.stableID(record.stableID)
      if let id, snapshot.displays.contains(where: { LiteIdentity.stableID($0.stableID) == id }) { continue }
      let reused = snapshot.displays.contains { $0.runtimeID == record.runtimeID }
      let duplicate = id.map { value in snapshot.records.filter { LiteIdentity.stableID($0.stableID) == value }.count > 1 } ?? false
      let refusal = unavailableReason ?? (id == nil || duplicate ? "恢复身份无效或重复，请核对目标。" :
        reused ? "屏幕编号已被占用，暂不能安全重连。" : nil)
      rows.append(.init(id: id ?? "record:\(record.runtimeID)", stableID: id,
                        runtimeID: record.runtimeID, name: record.name, isOnline: false, hasRecoveryRecord: true,
                        refusal: refusal))
    }
    // Keep ambiguous rows visible without duplicate SwiftUI identity.
    let counts = Dictionary(grouping: rows, by: \.id).mapValues(\.count)
    return rows.enumerated().map { index, row in
      guard counts[row.id, default: 0] > 1 else { return row }
      return LiteDisplayRow(id: "ambiguous:\(row.id):\(index)", stableID: row.stableID,
                            runtimeID: row.runtimeID, name: row.name, isOnline: row.isOnline,
                            hasRecoveryRecord: row.hasRecoveryRecord,
                            refusal: "目标身份重复，暂不能安全操作。")
    }
  }

  static func failureMessage(_ error: Error) -> String {
    if let refusal = error as? LiteRefusal { return refusal.message }
    if let error = error as? DisplayDJError {
      switch error.code {
      case .verificationFailed: return "未确认操作结果。恢复入口会保留，请刷新或重试。"
      case .conflict: return "已拒绝操作：需要保留至少一块在线屏幕。"
      case .displayNotFound, .ambiguousDisplay: return "目标已变化或不唯一，请刷新后重试。"
      case .unsupported: return "当前系统或显示状态不支持此操作。"
      case .internalFailure where ["configure-display-enabled", "complete-transaction"].contains(error.details["phase"] ?? ""):
        return "系统未接受连接变更。恢复记录已保留；请核对连接并在系统设置中检测显示器，必要时重启 Mac。"
      default: return "操作失败，恢复记录不会清空。请刷新后重试。"
      }
    }
    return "操作失败：\(error.localizedDescription)"
  }
}
