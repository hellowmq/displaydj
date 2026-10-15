import CoreGraphics
import Foundation

/// Applies one enable/disable change inside a display configuration transaction.
///
/// Implementations must not be fire-and-forget. `setEnabled` returns only after
/// the transaction has completed or failed, and a failure must be reported
/// instead of being swallowed.
public protocol DisplayConfigurationTransactionApplying: Sendable {
  func setEnabled(_ enabled: Bool, forRuntimeID runtimeID: UInt32) throws
}

/// CLI changes outlive a one-shot process; a Lite disable must not.
public enum DisplayDisconnectionLifetime: Sendable {
  case application
  case loginSession

  var configurationOption: CGConfigureOption {
    switch self {
    case .application: .forAppOnly
    case .loginSession: .forSession
    }
  }
}

/// The production transaction: a public CoreGraphics transaction wrapping one
/// private `CGSConfigureDisplayEnabled` call.
///
/// The transaction is always completed, including after a failed private call,
/// so a rejected change cannot leave a configuration transaction dangling.
public struct CGSConnectionTransaction: DisplayConfigurationTransactionApplying {
  private typealias ConfigureDisplayEnabled =
    @convention(c) (OpaquePointer?, UInt32, Bool) -> Int32

  private let configure: (CGDisplayConfigRef?, UInt32, Bool) -> Int32
  private let begin: (inout CGDisplayConfigRef?) -> CGError
  private let complete: (CGDisplayConfigRef?, CGConfigureOption) -> CGError
  private let disconnectionLifetime: DisplayDisconnectionLifetime

  /// - Throws: A `.unsupported` error when the private entry point is missing.
  ///   An unavailable symbol is a hard failure, never a silently skipped call.
  public init(resolver: any DisplayConnectionSymbolResolving,
              disconnectionLifetime: DisplayDisconnectionLifetime = .loginSession) throws {
    guard let raw = resolver.resolve(.configureDisplayEnabled) else {
      throw DisplayDJError(
        code: .unsupported,
        message: """
          This system does not expose the private display connection entry \
          point, so displays cannot be disconnected through it.
          """,
        operation: .write,
        details: [
          "phase": "symbol-resolution",
          "symbol": DisplayConnectionSymbol.configureDisplayEnabled.rawValue,
        ]
      )
    }

    let function = unsafeBitCast(raw, to: ConfigureDisplayEnabled.self)
    self.init(disconnectionLifetime: disconnectionLifetime,
              begin: { CGBeginDisplayConfiguration(&$0) },
              configure: { function($0, $1, $2) },
              complete: { CGCompleteDisplayConfiguration($0, $1) })
  }

  // Inject the complete transaction boundary for tests; no real display calls.
  init(disconnectionLifetime: DisplayDisconnectionLifetime,
       begin: @escaping (inout CGDisplayConfigRef?) -> CGError,
       configure: @escaping (CGDisplayConfigRef?, UInt32, Bool) -> Int32,
       complete: @escaping (CGDisplayConfigRef?, CGConfigureOption) -> CGError) {
    self.disconnectionLifetime = disconnectionLifetime
    self.begin = begin
    self.configure = configure
    self.complete = complete
  }

  public func setEnabled(_ enabled: Bool, forRuntimeID runtimeID: UInt32) throws {
    var config: CGDisplayConfigRef?
    let beginStatus = begin(&config)

    guard beginStatus == .success else {
      throw Self.error(
        phase: "begin-transaction",
        message: "The display configuration transaction could not be started.",
        runtimeID: runtimeID,
        status: beginStatus.rawValue
      )
    }

    guard let config else {
      throw Self.error(
        phase: "begin-transaction",
        message: """
          The display configuration transaction started without a configuration \
          reference.
          """,
        runtimeID: runtimeID,
        status: beginStatus.rawValue
      )
    }

    let callStatus = configure(config, runtimeID, enabled)
    // Reconnect is committed to the login session, so restoring an old Lite
    // session-scoped disable does not revert to that disabled baseline on exit.
    let completeStatus = complete(config, enabled ? .forSession : disconnectionLifetime.configurationOption)

    guard callStatus == 0 else {
      throw Self.error(
        phase: "configure-display-enabled",
        message: "The display connection change was rejected by the window server.",
        runtimeID: runtimeID,
        status: callStatus,
        extraDetails: ["enabled": String(enabled)]
      )
    }

    guard completeStatus == .success else {
      throw Self.error(
        phase: "complete-transaction",
        message: "The display configuration transaction could not be completed.",
        runtimeID: runtimeID,
        status: completeStatus.rawValue
      )
    }
  }

  private static func error(
    phase: String,
    message: String,
    runtimeID: UInt32,
    status: Int32,
    extraDetails: [String: String] = [:]
  ) -> DisplayDJError {
    var details: [String: String] = [
      "phase": phase,
      "runtimeID": String(runtimeID),
      "status": String(status),
    ]
    details.merge(extraDetails) { _, new in new }

    return DisplayDJError(
      code: .internalFailure,
      message: message,
      operation: .write,
      displayID: String(runtimeID),
      details: details
    )
  }
}

// Declared in an extension so the primary declaration stays on one line.
extension CGSConnectionTransaction: @unchecked Sendable {}
