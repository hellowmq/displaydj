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

/// The production transaction: a public CoreGraphics transaction wrapping one
/// private `CGSConfigureDisplayEnabled` call.
///
/// The transaction is always completed, including after a failed private call,
/// so a rejected change cannot leave a configuration transaction dangling.
public struct CGSConnectionTransaction: DisplayConfigurationTransactionApplying {
  private typealias ConfigureDisplayEnabled =
    @convention(c) (OpaquePointer?, UInt32, Bool) -> Int32

  private let configure: ConfigureDisplayEnabled

  /// - Throws: A `.unsupported` error when the private entry point is missing.
  ///   An unavailable symbol is a hard failure, never a silently skipped call.
  public init(resolver: any DisplayConnectionSymbolResolving) throws {
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

    configure = unsafeBitCast(raw, to: ConfigureDisplayEnabled.self)
  }

  public func setEnabled(_ enabled: Bool, forRuntimeID runtimeID: UInt32) throws {
    var config: CGDisplayConfigRef?
    let beginStatus = CGBeginDisplayConfiguration(&config)

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
    let completeStatus = CGCompleteDisplayConfiguration(config, .forSession)

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
