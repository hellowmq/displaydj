import DisplayDJCore
import Foundation

/// Whether this app can stop output to one display right now.
///
/// Decided before the button is pressed rather than after. The window server
/// refuses the same cases the core layer refuses, but a refusal arrives as an
/// error once the user has already committed to the gesture — and the interesting
/// cases here are knowable in advance: whether the system exposes the entry
/// point at all, whether this display is mid-mirror, and whether it is the last
/// screen anyone could look at.
enum DisplayConnectionAvailability: Equatable {
  case available
  /// The private entry point is missing, so no amount of asking will work.
  case unsupported
  case builtInDisplay
  /// Disconnecting a mirrored display changes the mirror set instead.
  case mirroredDisplay
  /// It is the only display left; disconnecting it would empty the desktop.
  case lastOnlineDisplay

  var canDisconnect: Bool {
    self == .available
  }

  /// Why the button is off, phrased for a tooltip and for VoiceOver.
  ///
  /// `nil` exactly when `canDisconnect`: a control that is enabled must not
  /// carry an explanation for being disabled.
  var guidance: String? {
    switch self {
    case .available:
      nil
    case .unsupported:
      "这台 Mac 没有提供停止显示器输出所需的系统接口。"
    case .builtInDisplay:
      "内建屏幕可调节亮度；此处不提供停止其输出的操作。"
    case .mirroredDisplay:
      "这台显示器正在镜像其他屏幕。请先关闭镜像，再断开它。"
    case .lastOnlineDisplay:
      "它是当前唯一在线的显示器，断开后就没有屏幕可看了。"
    }
  }
}

/// The one place the availability rule is stated.
///
/// Kept apart from the controller so the rule can be tested without a window
/// server: every branch below is about numbers the UI already holds.
enum DisplayConnectionAvailabilityResolver {
  static func resolve(
    isSupported: Bool,
    onlineCount: Int,
    isMirrored: Bool,
    isBuiltIn: Bool = false
  ) -> DisplayConnectionAvailability {
    // Unsupported wins over the rest: with no entry point the other two
    // questions have no answer that could ever lead to a working disconnect.
    guard isSupported else { return .unsupported }
    if isBuiltIn { return .builtInDisplay }
    // Mirrored before "last online" because the mirror check is about this
    // display, and a mirrored display may also be the only one left — in which
    // case the mirror set is the thing the user has to change first.
    if isMirrored { return .mirroredDisplay }
    if onlineCount < 2 { return .lastOnlineDisplay }
    return .available
  }
}
