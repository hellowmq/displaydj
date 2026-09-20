import DisplayDJCore
import Foundation

/// What the user can actually do after a failure.
///
/// A failure that offers no way forward is just a complaint, so every mapping below has to
/// decide deliberately whether retrying makes sense — and, for writes, retrying has to carry
/// the value the user asked for rather than whatever the hardware happens to report later.
enum BrightnessRecovery: Equatable {
  /// Read one display's brightness again.
  ///
  /// It carries its target for exactly the same reason `retryWrite` does. Every card polls
  /// and reports on its own, so the display whose read failed need not still be the selected
  /// one when the user presses the button — resolving the target later would re-read the
  /// wrong monitor and leave the failing one stuck.
  case retryRead(displayStableID: String)
  /// Send the same target again.
  ///
  /// It carries both the value the user asked for *and* the display it was meant for.
  /// Any card can be adjusted without first selecting it, so a retry that resolved the
  /// target from the current selection would send one monitor's value to another.
  case retryWrite(value: Int, displayStableID: String)
  /// Re-enumerate the attached displays.
  case rescan
  /// Nothing the user can do from here; the suggestion explains what to change first.
  ///
  /// Deliberately not named `none`: as `BrightnessRecovery?` it would collide with
  /// `Optional.none` and silently swallow a branch in every `switch`.
  case unavailable

  /// The display this recovery would act on, or `nil` when it names none.
  ///
  /// Stated once here so callers can tell *whose* failure is on screen instead of assuming
  /// it belongs to whatever is selected.
  var targetDisplayStableID: String? {
    switch self {
    case .retryRead(let displayStableID): displayStableID
    case .retryWrite(_, let displayStableID): displayStableID
    case .rescan, .unavailable: nil
    }
  }
}

/// A failure phrased for the person looking at the popover.
///
/// `summary` says what happened, `suggestion` says what to do next, and `technicalDetail`
/// keeps the raw engineering text available as a tooltip without putting it on screen.
struct BrightnessFailure: Equatable {
  let summary: String
  let suggestion: String
  let recovery: BrightnessRecovery
  let technicalDetail: String?

  init(
    summary: String,
    suggestion: String,
    recovery: BrightnessRecovery,
    technicalDetail: String? = nil
  ) {
    self.summary = summary
    self.suggestion = suggestion
    self.recovery = recovery
    self.technicalDetail = technicalDetail
  }

  /// Whether the failure offers the user any way forward.
  ///
  /// The view reads this through `recoveryActionTitle`; it is stated here as well so the
  /// "a dead end must explain itself" contract can be asserted without a live controller.
  var isRetryable: Bool {
    recovery != .unavailable
  }

  /// One-line form used by VoiceOver, which cannot rely on visual grouping.
  var spokenDescription: String {
    "\(summary)。\(suggestion)"
  }
}

/// The operation a failure came out of. It decides which retry the user is offered.
enum BrightnessOperation: Equatable {
  case scan
  /// A read always names the display it was aimed at. The polling loop reads every attached
  /// display in turn, so without a target the resulting failure could not say which monitor
  /// it belongs to, and its retry would silently re-read a different one.
  case read(displayStableID: String)
  /// A write always names its target display, because the retry has to reach the same
  /// monitor the user originally aimed at rather than whichever card is selected later.
  case write(value: Int, displayStableID: String)

  /// The display this operation acted on, or `nil` for a topology-wide scan.
  var displayStableID: String? {
    switch self {
    case .scan: nil
    case .read(let displayStableID): displayStableID
    case .write(_, let displayStableID): displayStableID
    }
  }

  var retry: BrightnessRecovery {
    switch self {
    case .scan: .rescan
    case .read(let displayStableID): .retryRead(displayStableID: displayStableID)
    case .write(let value, let displayStableID):
      .retryWrite(value: value, displayStableID: displayStableID)
    }
  }

  var verb: String {
    switch self {
    case .scan: "查找显示器"
    case .read: "读取亮度"
    case .write: "调节亮度"
    }
  }
}

/// Turns engineering errors into sentences a user can act on.
///
/// `DisplayDJError.localizedDescription` is written for logs and exit codes; surfacing it
/// verbatim tells the user nothing and hides the one thing that matters — what to try next.
/// The mapping keys off the stable `DisplayDJErrorCode`, never off message text.
enum BrightnessFailurePresenter {
  /// Whether an error is this app cancelling its own work rather than the hardware failing.
  ///
  /// Superseded reads are cancelled deliberately — a newer read replaces an older one, and
  /// closing the popover cancels whatever was in flight. Those are routine and expected, so
  /// they must never reach the user: reported as failures they say "读取亮度失败, 请重新插拔
  /// 显示器线缆" about a monitor that is working perfectly, and the accompanying discard of
  /// the reading also disables that display's relative steps.
  ///
  /// Only a bare `CancellationError` counts. When a *write* is cancelled and the restoration
  /// afterwards also fails, Core reports a `DisplayDJError` that merely records
  /// `primaryCode: cancelled` in its details — that one is a genuine failure, because the
  /// display may be left holding a value the user never asked for, and it must still be
  /// shown.
  static func isCancellation(_ error: Error) -> Bool {
    error is CancellationError
  }

  static func failure(for error: Error, operation: BrightnessOperation) -> BrightnessFailure {
    if let nativeError = error as? NativeBrightnessError {
      return nativeFailure(for: nativeError, operation: operation)
    }
    let detail = detailText(for: error)
    guard let coded = error as? DisplayDJError else {
      return BrightnessFailure(
        summary: "\(operation.verb)失败",
        suggestion: "请重试一次；若反复失败，请重新插拔显示器线缆。",
        recovery: operation.retry,
        technicalDetail: detail
      )
    }
    return failure(for: coded.code, operation: operation, detail: detail)
  }

  /// Selected display exists but carries no stable identity, so it cannot be addressed safely.
  static var noStableIdentity: BrightnessFailure {
    BrightnessFailure(
      summary: "这台显示器无法被稳定识别",
      suggestion: "它没有提供可靠的识别信息，为避免误调其他屏幕，已停止控制。请改用其他接口或线缆连接。",
      recovery: .rescan
    )
  }

  // MARK: - Code mapping

  private static func nativeFailure(
    for error: NativeBrightnessError, operation: BrightnessOperation
  ) -> BrightnessFailure {
    let summary: String
    switch error {
    case .unavailable: summary = "内建屏幕亮度控制暂不可用"
    case .readFailed: summary = "无法读取内建屏幕亮度"
    case .writeRejected: summary = "系统未接受这个亮度"
    case .unverified: summary = "无法确认内建屏幕的实际亮度"
    }
    return BrightnessFailure(
      summary: summary,
      suggestion: "请稍候重试；若持续失败，可先使用系统设置或键盘亮度键调节。",
      recovery: operation.retry,
      technicalDetail: "[display-services] \(error)"
    )
  }

  private static func failure(
    for code: DisplayDJErrorCode,
    operation: BrightnessOperation,
    detail: String?
  ) -> BrightnessFailure {
    let wording = self.wording(for: code, operation: operation)
    return BrightnessFailure(
      summary: wording.summary,
      suggestion: wording.suggestion,
      recovery: wording.way.recovery(for: operation),
      technicalDetail: detail
    )
  }

  /// How a wording's suggested next step turns into an actual affordance.
  ///
  /// It is resolved here rather than at the call site so the button can never disagree with
  /// the sentence above it — telling the user to rescan while offering "retry" is worse than
  /// offering nothing at all.
  private enum WayOut {
    /// Repeat whatever the user was doing.
    case repeatOperation
    /// Re-enumerate first; repeating the same call would fail the same way.
    case rescan
    /// Something outside the app has to change before any button would help.
    case unavailable

    func recovery(for operation: BrightnessOperation) -> BrightnessRecovery {
      switch self {
      case .repeatOperation: operation.retry
      case .rescan: .rescan
      case .unavailable: .unavailable
      }
    }
  }

  private struct Wording {
    let summary: String
    let suggestion: String
    let way: WayOut
  }

  private static func wording(
    for code: DisplayDJErrorCode,
    operation: BrightnessOperation
  ) -> Wording {
    identityWording(for: code)
      ?? linkWording(for: code)
      ?? appWording(for: code, operation: operation)
  }

  /// Failures about *which* display is being addressed. The user fixes these by changing
  /// what is plugged in, not by pressing the same button again.
  private static func identityWording(for code: DisplayDJErrorCode) -> Wording? {
    switch code {
    case .displayNotFound:
      return Wording(
        summary: "找不到这台显示器",
        suggestion: "它可能已被拔掉或进入了休眠。请重新扫描。",
        way: .rescan
      )
    case .ambiguousDisplay:
      return Wording(
        summary: "有多台显示器无法区分",
        suggestion: "它们上报了相同的识别信息。为避免调错屏幕，请先拔掉其中一台。",
        way: .unavailable
      )
    case .unsupported, .backendUnavailable, .timeout, .busy, .conflict, .transportFailure,
      .verificationFailed, .invalidValue, .invalidArguments, .invalidSelector, .internalFailure:
      return nil
    }
  }

  /// Failures on the wire between the Mac and the panel. These are theones worth
  /// repeating verbatim, because the same request may well succeed a moment later.
  private static func linkWording(for code: DisplayDJErrorCode) -> Wording? {
    switch code {
    case .unsupported:
      return Wording(
        summary: "这台显示器不支持通过电脑调节亮度",
        suggestion: "请在显示器自带的菜单里打开 DDC/CI 后重试；部分型号需改用 DisplayPort 或 USB-C 连接。",
        way: .repeatOperation
      )
    case .backendUnavailable:
      return Wording(
        summary: "当前环境无法与显示器通信",
        suggestion: "请确认 App 运行在 Apple 芯片的Mac 上，并且不是通过 Rosetta 启动的。",
        way: .unavailable
      )
    case .timeout:
      return Wording(
        summary: "显示器没有及时响应",
        suggestion: "它可能正在切换输入或刚从休眠中唤醒。请稍候几秒再试。",
        way: .repeatOperation
      )
    case .busy, .conflict:
      return Wording(
        summary: "显示器正忙",
        suggestion: "另一个程序或上一次操作还在占用它。请稍候片刻再试。",
        way: .repeatOperation
      )
    case .transportFailure:
      return Wording(
        summary: "与显示器的通信中断",
        suggestion: "请检查线缆是否插紧；若使用扩展坞或转接头，直连试试。",
        way: .repeatOperation
      )
    case .displayNotFound, .ambiguousDisplay, .verificationFailed, .invalidValue,
      .invalidArguments, .invalidSelector, .internalFailure:
      return nil
    }
  }

  /// Everything left: the request itself was malformed or the app tripped over its own feet.
  private static func appWording(
    for code: DisplayDJErrorCode,
    operation: BrightnessOperation
  ) -> Wording {
    switch code {
    case .verificationFailed:
      return verificationWording(for: operation)
    case .invalidValue, .invalidArguments, .invalidSelector:
      return Wording(
        summary: "\(operation.verb)的请求不被接受",
        suggestion: "这是 App 内部的问题。请重新打开菜单再试。",
        way: .repeatOperation
      )
    case .internalFailure:
      return Wording(
        summary: "\(operation.verb)时出现内部错误",
        suggestion: "请重试一次；若持续出现，请重启 App。",
        way: .repeatOperation
      )
    case .displayNotFound, .ambiguousDisplay, .unsupported, .backendUnavailable, .timeout,
      .busy, .conflict, .transportFailure:
      // Handled by the two groups above; reaching here would mean the routing changed.
      return Wording(
        summary: "\(operation.verb)时出现内部错误",
        suggestion: "请重试一次；若持续出现，请重启 App。",
        way: .repeatOperation
      )
    }
  }

  /// The hardware refused or misapplied the value. The write path already restored the
  /// original brightness before surfacing this, so the wording must not imply a half-applied
  /// state the user has to clean up.
  private static func verificationWording(for operation: BrightnessOperation) -> Wording {
    guard case .write = operation else {
      return Wording(
        summary: "读到的亮度无法确认",
        suggestion: "显示器返回了不可信的数值。请重试一次。",
        way: .repeatOperation
      )
    }
    return Wording(
      summary: "显示器没有接受这个亮度",
      suggestion: "原来的亮度已经恢复。请换一个数值，或稍候再试。",
      way: .repeatOperation
    )
  }

  private static func detailText(for error: Error) -> String? {
    if let coded = error as? DisplayDJError {
      return "[\(coded.code.rawValue)] \(coded.message)"
    }
    let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }
}
