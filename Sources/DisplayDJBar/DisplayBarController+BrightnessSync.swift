import DisplayDJCore
import OSLog

private let brightnessSyncLogger = Logger(
  subsystem: "io.github.hellowmq.displaydj", category: "BrightnessSync"
)

extension DisplayBarController {
  var isBrightnessSyncEnabled: Bool { preferences.syncBrightness }

  /// Synchronization is opt-in and only starts after every visible physical
  /// display has a fresh hardware brightness reading. Gamma stays a separate
  /// control and is never used as an implicit replacement for failed DDC.
  func setBrightnessSyncEnabled(_ enabled: Bool) async {
    guard enabled else {
      var next = preferences
      next.syncBrightness = false
      preferences = next
      persistPreferences()
      brightnessSyncLogger.info("hardware brightness sync disabled")
      return
    }
    guard !isPreparingBrightnessSync, !isWriting, !intents.hasPending else { return }
    isPreparingBrightnessSync = true
    defer { isPreparingBrightnessSync = false }
    if displays.isEmpty { await scanAndRefresh() }

    let ids = displays.compactMap(\.stableID)
    brightnessSyncLogger.info("hardware brightness sync preparing displayCount=\(ids.count)")
    guard ids.count == displays.count, ids.count > 1, Set(ids).count == ids.count else {
      failures.topology = syncUnavailable("需要至少两台可稳定识别的显示器。")
      return
    }
    var readings: [String: Int] = [:]
    for id in ids {
      do {
        let value = try await brightnessAccess.read(stableID: id)
        guard (0...100).contains(value) else {
          failures.topology = syncUnavailable("有显示器返回了无效的硬件亮度读数。")
          return
        }
        readings[id] = value
      } catch {
        failures.topology = syncUnavailable("有显示器无法读取硬件亮度。请检查各屏的错误并重试。")
        return
      }
    }
    guard displays.count == ids.count, displays.compactMap(\.stableID) == ids else {
      failures.topology = syncUnavailable("读取过程中显示器连接发生变化，请刷新后重试。")
      return
    }
    for (id, value) in readings { setBrightnessForDisplay(value, id: id) }
    var next = preferences
    next.syncBrightness = true
    preferences = next
    persistPreferences()
    failures.topology = nil
    brightnessSyncLogger.info("hardware brightness sync enabled displayCount=\(ids.count)")
  }

  /// A changed topology or failed read invalidates a group gesture. Turn the
  /// option off before performing the explicitly targeted source adjustment.
  func stopBrightnessSyncForMissingBaseline() {
    var next = preferences
    next.syncBrightness = false
    preferences = next
    persistPreferences()
    failures.topology = syncUnavailable("已有显示器的硬件亮度读数缺失，同步已关闭；本次仅尝试调整原目标屏幕。")
    brightnessSyncLogger.warning("hardware brightness sync disabled after missing reading")
  }

  private func syncUnavailable(_ reason: String) -> BrightnessFailure {
    brightnessSyncLogger.warning("hardware brightness sync unavailable: \(reason, privacy: .public)")
    return BrightnessFailure(
      summary: "无法同步调节显示器",
      suggestion: reason,
      recovery: .rescan
    )
  }
}
