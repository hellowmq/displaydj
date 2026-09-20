import DisplayDJCore
import Foundation

/// Something that went wrong while connecting or disconnecting a display.
///
/// Deliberately not a `BrightnessFailure`. Those are keyed to brightness
/// operations and offer retries that resend a brightness value; the way out of a
/// failed disconnect is a different act against a display that, by definition,
/// may no longer be on screen to carry a card of its own.
struct DisplayConnectionNotice: Equatable, Identifiable {
  /// The display this notice is about: a selection key while it is online, a
  /// `runtime:` key once it is not.
  let id: String
  let summary: String
  let suggestion: String
  let technicalDetail: String?

  init(
    id: String,
    summary: String,
    suggestion: String,
    technicalDetail: String? = nil
  ) {
    self.id = id
    self.summary = summary
    self.suggestion = suggestion
    self.technicalDetail = technicalDetail
  }

  var spokenDescription: String {
    "\(summary)。\(suggestion)"
  }
}

/// Turns a connection error into a sentence, keyed off the stable error code.
enum DisplayConnectionNoticePresenter {
  static func notice(
    for error: Error,
    intent: DisplayConnectionState,
    displayName: String,
    targetKey: String
  ) -> DisplayConnectionNotice {
    let detail = detailText(for: error)

    guard let coded = error as? DisplayDJError else {
      return DisplayConnectionNotice(
        id: targetKey,
        summary: "\(verb(for: intent))「\(displayName)」失败",
        suggestion: "请重试一次；若反复失败，请重新插拔显示器线缆。",
        technicalDetail: detail
      )
    }

    return DisplayConnectionNotice(
      id: targetKey,
      summary: summary(for: coded.code, intent: intent, displayName: displayName),
      suggestion: suggestion(for: coded.code, intent: intent),
      technicalDetail: detail
    )
  }

  // MARK: - Wording

  private static func verb(for intent: DisplayConnectionState) -> String {
    switch intent {
    case .disconnected: "断开"
    case .connected: "恢复"
    }
  }

  private static func summary(
    for code: DisplayDJErrorCode,
    intent: DisplayConnectionState,
    displayName: String
  ) -> String {
    switch code {
    case .conflict:
      "不能断开「\(displayName)」"
    case .unsupported:
      "这台 Mac 无法\(verb(for: intent))显示器输出"
    case .verificationFailed:
      "\(verb(for: intent))「\(displayName)」未生效"
    case .displayNotFound, .ambiguousDisplay:
      "找不到「\(displayName)」"
    case .invalidSelector, .invalidArguments, .invalidValue:
      "无法对「\(displayName)」执行该操作"
    case .backendUnavailable, .timeout, .busy, .transportFailure, .internalFailure:
      "\(verb(for: intent))「\(displayName)」失败"
    }
  }

  private static func suggestion(
    for code: DisplayDJErrorCode,
    intent: DisplayConnectionState
  ) -> String {
    switch code {
    case .conflict:
      "断开它会让桌面没有任何屏幕可用。请保留至少一台在线显示器。"
    case .unsupported:
      "系统没有提供所需的显示配置接口。请升级 macOS 后重试。"
    case .verificationFailed:
      verificationSuggestion(for: intent)
    case .displayNotFound, .ambiguousDisplay:
      "它可能已经被拔出。请重新扫描显示器。"
    case .invalidSelector, .invalidArguments, .invalidValue:
      "请重新扫描显示器后重试。"
    case .backendUnavailable, .timeout, .busy, .transportFailure, .internalFailure:
      serviceSuggestion(for: code)
    }
  }

  /// Disconnecting and reconnecting fail the same way but leave opposite states,
  /// so the advice names the one the user is actually looking at.
  private static func verificationSuggestion(
    for intent: DisplayConnectionState
  ) -> String {
    switch intent {
    case .disconnected:
      "它仍在正常显示。请重试，或重新插拔线缆后再断开。"
    case .connected:
      "它还没有恢复显示。请重试，或重新插拔线缆让它自动恢复。"
    }
  }

  private static func serviceSuggestion(for code: DisplayDJErrorCode) -> String {
    switch code {
    case .backendUnavailable:
      "显示服务暂时不可用。请稍后重试。"
    case .timeout, .busy:
      "系统正忙或响应超时。请稍后重试。"
    case .transportFailure:
      "显示服务没有完成请求；这不代表线缆未插紧。请稍后重试。"
    default:
      "请重试一次；若反复失败，请重新插拔显示器线缆。"
    }
  }

  private static func detailText(for error: Error) -> String? {
    if let coded = error as? DisplayDJError {
      return coded.message
    }
    let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }
}
