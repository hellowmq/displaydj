import DisplayDJCore
import Foundation

/// Watches for physical display changes and releases any disable they disturb.
///
/// Watching has to be continuous, so it belongs to the menu bar app and not to
/// the CLI: a one-shot invocation has already exited by the time a cable moves,
/// and a disable left unreleased by it would have nothing looking out for it.
@MainActor
final class DisplayConnectionAutoReleaseRunner {
  private let release: DisplayConnectionAutoRelease
  private let source: any DisplayTopologyChangeSource
  private let onChange: () -> Void

  init(
    release: DisplayConnectionAutoRelease,
    source: any DisplayTopologyChangeSource = CGDisplayTopologyChangeSource(),
    onChange: @escaping () -> Void = {}
  ) {
    self.release = release
    self.source = source
    self.onChange = onChange
  }

  /// - Returns: `nil` when this system cannot drive display connections at all.
  ///   There is nothing to watch in that case, and the refusal is logged rather
  ///   than swallowed, so an unguarded session never looks like a guarded one.
  static func make(onChange: @escaping () -> Void) -> DisplayConnectionAutoReleaseRunner? {
    do {
      return DisplayConnectionAutoReleaseRunner(
        release: try DisplayConnectionAutoRelease.live(),
        onChange: onChange
      )
    } catch {
      NSLog("DisplayDJ: 无法监视显示器的物理连接变化，%@", String(describing: error))
      return nil
    }
  }

  func start() {
    source.start { [weak self] change in
      guard let self else { return }
      Task { @MainActor in self.handle(change) }
    }
  }

  /// Nonisolated because teardown runs from `deinit`, which is not on the main
  /// actor. Unregistering a callback touches nothing else.
  nonisolated func stop() {
    source.stop()
  }

  private func handle(_ change: DisplayTopologyChange) {
    do {
      guard let outcome = try release.handle(change) else { return }
      note(outcome)
      onChange()
    } catch {
      NSLog(
        "DisplayDJ: 解除显示器禁用失败 runtime:%u — %@",
        change.runtimeID,
        String(describing: error)
      )
    }
  }

  /// Outcomes are logged rather than shown: the point of releasing a disable is
  /// that the display simply works again, and a screen that lights up needs no
  /// explanation. The log is what makes it findable when it does not.
  private func note(_ outcome: DisplayConnectionAutoReleaseOutcome) {
    let name = outcome.displayName ?? "runtime:\(outcome.runtimeID)"

    switch outcome.action {
    case .clearedOnUnplug:
      NSLog("DisplayDJ: 检测到「%@」被拔出，已清除禁用记录，重新插入将正常点亮。", name)
    case .restoredOnReconnect:
      NSLog(
        "DisplayDJ: 检测到「%@」重新连接，已恢复输出%@。",
        name,
        outcome.wasVerified ? "" : "（未能确认）"
      )
    }
  }
}
