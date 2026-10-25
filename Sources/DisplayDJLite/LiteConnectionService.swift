import ColorSync
import CoreGraphics
import Darwin
import DisplayDJCore
import Foundation

enum LiteIdentity {
  static let version = "0.1.0"
  static let bundleID = "io.github.hellowmq.displaydj.lite"

  static func recordURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                        supportRoot: URL? = nil) -> URL {
    if let home = environment["DISPLAYDJ_LITE_HOME"], !home.isEmpty {
      return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        .appendingPathComponent("disconnected-displays.json")
    }
    let base = supportRoot ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first!
    return base.appendingPathComponent("DisplayDJLite/disconnected-displays.json")
  }

  static func stableID(_ value: String?) -> String? {
    guard let value, value.lowercased().hasPrefix("uuid:"),
          let uuid = UUID(uuidString: String(value.dropFirst(5))) else { return nil }
    return "uuid:" + uuid.uuidString.lowercased()
  }
}

struct LiteSnapshot: Sendable {
  var displays: [DisplayDescriptor]
  var records: [DisplayConnectionRecord]

  var pendingRecords: [DisplayConnectionRecord] {
    records.filter { record in
      record.requiresRediscovery != true || displays.contains {
        LiteIdentity.stableID($0.stableID) == LiteIdentity.stableID(record.stableID)
      }
    }
  }
}

struct LiteRuntimeIdentity: Sendable {
  let stableID: String
  let isBuiltIn: Bool
  let isMirrored: Bool
}

protocol LiteConnectionAccess: Sendable {
  var unavailableReason: String? { get }
  func snapshot() async throws -> LiteSnapshot
  func change(_ state: DisplayConnectionState, stableID: String) async throws -> DisplayConnectionOutcome
}

struct LiteConnectionService: LiteConnectionAccess {
  let discovery: any DisplayDiscovering
  let store: any DisplayConnectionRecordStoring
  let controller: DisplayConnectionController?
  let unavailableReason: String?
  let runtimeIdentity: @Sendable (UInt32) -> LiteRuntimeIdentity?
  var recoveryCutoff: Date = .distantPast
  var ensureRecoveryProtection: @Sendable () async throws -> Void = {}

  static func live(ensureRecoveryProtection: @escaping @Sendable () async throws -> Void = {
    throw LiteRefusal("退出恢复保护未就绪，未断开显示器。")
  }) -> Self {
    let discovery = CoreGraphicsDisplayDiscovery()
    let store = FileDisplayConnectionRecordStore(fileURL: LiteIdentity.recordURL())
    // Physical link/wake-up can exceed the core's 5-second default. Keep the
    // UI pending for up to 15 seconds; still require the exact stable target.
    let controller = try? DisplayConnectionController.live(store: store,
      disconnectionLifetime: .application, verificationAttempts: 75)
    var service = Self(discovery: discovery, store: store, controller: controller,
                unavailableReason: controller == nil ? "当前系统不支持显示器连接控制。" : nil,
                runtimeIdentity: { id in
      guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
      return LiteRuntimeIdentity(stableID: "uuid:" + (CFUUIDCreateString(nil, uuid) as String).lowercased(),
                                 isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                                 isMirrored: CGDisplayIsInMirrorSet(id) != 0)
    })
    var boot = timeval()
    var size = MemoryLayout<timeval>.size
    if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 {
      service.recoveryCutoff = Date(timeIntervalSince1970: Double(boot.tv_sec))
    } else {
      // With no session boundary, do not trust an absent runtime identity.
      service.recoveryCutoff = .distantFuture
    }
    service.ensureRecoveryProtection = ensureRecoveryProtection
    return service
  }

  func snapshot() async throws -> LiteSnapshot {
    let displays = try await discovery.discoverDisplays()
    let saved = try store.loadRecords()
    let records = saved.map { record in
      guard record.requiresRediscovery != true,
            let id = LiteIdentity.stableID(record.stableID),
            !displays.contains(where: { LiteIdentity.stableID($0.stableID) == id }) else { return record }
      let reused = displays.contains { $0.runtimeID == record.runtimeID } ||
        runtimeIdentity(record.runtimeID).map { LiteIdentity.stableID($0.stableID) != id } == true
      guard reused || record.disconnectedAt < recoveryCutoff else { return record }
      return DisplayConnectionRecord(runtimeID: record.runtimeID, stableID: record.stableID,
        name: record.name, disconnectedAt: record.disconnectedAt, requiresRediscovery: true)
    }
    // Persist before allowing a new disconnect: the old ID must remain unsafe
    // even while the new display is temporarily absent or the App restarts.
    if records != saved { try store.saveRecords(records) }
    return LiteSnapshot(displays: displays, records: records)
  }

  func change(_ state: DisplayConnectionState, stableID: String) async throws -> DisplayConnectionOutcome {
    guard let id = LiteIdentity.stableID(stableID), let controller else {
      throw LiteRefusal(unavailableReason ?? "无法确认显示器身份，请刷新后重试。")
    }
    let current = try await snapshot()
    if state == .disconnected, !current.pendingRecords.isEmpty {
      throw LiteRefusal("请先恢复已有记录的外屏，再断开另一台。")
    }
    let online = current.displays.filter { LiteIdentity.stableID($0.stableID) == id }
    guard online.count < 2 else { throw LiteRefusal("显示器身份重复，已停止操作。") }
    if let display = online.first {
      if let reason = Self.refusal(for: display, in: current.displays, disconnecting: state == .disconnected) {
        throw LiteRefusal(reason)
      }
    } else {
      guard state == .connected else { throw LiteRefusal("目标已不在线，请刷新显示器列表。") }
      let records = current.records.filter { LiteIdentity.stableID($0.stableID) == id }
      guard records.count == 1, let record = records.first else {
        throw LiteRefusal("没有唯一的 Lite 恢复记录，已停止操作。")
      }
      guard record.requiresRediscovery != true else {
        throw LiteRefusal("旧屏幕未接入，记录已保留。接好这台屏幕后刷新，不会使用旧编号控制其他屏幕。")
      }
      // A recycled runtime ID must never enable a different screen.
      guard !current.displays.contains(where: { $0.runtimeID == record.runtimeID }) else {
        throw LiteRefusal("原屏幕编号已被另一台显示器使用，已停止操作。")
      }
      if let identity = runtimeIdentity(record.runtimeID) {
        guard LiteIdentity.stableID(identity.stableID) == id,
              !identity.isBuiltIn, !identity.isMirrored else {
          throw LiteRefusal("原屏幕身份已变化，已停止操作。请刷新后重试。")
        }
      } else {
        // Software-disabled displays legitimately lose their queryable UUID.
        // Use the saved exact target as the existing core does, then require its
        // UUID in fresh discovery after restoration. Never use a pre-reboot ID.
        guard record.disconnectedAt >= recoveryCutoff else {
          throw LiteRefusal("恢复记录来自较早的系统会话。请重新接好线缆后刷新。")
        }
      }
    }
    if state == .disconnected { try await ensureRecoveryProtection() }
    return try await controller.setState(state, for: .stableID(id))
  }

  static func refusal(for display: DisplayDescriptor, in displays: [DisplayDescriptor],
                      disconnecting: Bool = true) -> String? {
    if display.isBuiltIn { return "内建屏仅提供亮度调节，不能从这里断开。" }
    if display.isVirtual != false { return "虚拟屏或类型未确认，暂不提供连接控制。" }
    guard let id = LiteIdentity.stableID(display.stableID),
          displays.filter({ LiteIdentity.stableID($0.stableID) == id }).count == 1 else {
      return "无法唯一确认显示器身份，请刷新后重试。"
    }
    if display.isMirrored { return "请先退出镜像模式，再操作这台外屏。" }
    if disconnecting && displays.count < 2 { return "这是最后一块在线屏幕，需要保留桌面。" }
    return nil
  }
}

struct LiteRefusal: Error, LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
