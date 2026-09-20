/// The production Apple Silicon DDC brightness write entry point.
///
/// The CLI uses this entry point after validating its public arguments. Each
/// call creates fresh discovery and service-matching scopes, reads a trustworthy
/// baseline, sends one target Set VCP request, and requires exact read-back. A
/// display that ignores an isolated Set frame gets the frame repeated.
/// Failed or cancelled attempted writes restore and verify the original raw
/// value before returning. Synchronous private IOAV calls still require a
/// killable child process with a wall-clock deadline for hardware acceptance.
public struct AppleSiliconDDCBrightnessWriter: Sendable {
  private static let backend = BackendKind.appleSiliconDDC

  public init() {}

  public func write(
    percent: Double,
    toStableID stableID: String
  ) async throws -> ControlWriteResult {
    let value: DisplayControlValue
    do {
      value = try DisplayControlValue(percent: percent)
    } catch let error as DisplayDJError {
      throw Self.contextualizedValueError(error, displayID: stableID)
    }

    let selector: DisplaySelector
    do {
      selector = try DisplayCLISelector.parse(stableID)
    } catch let error as DisplayDJError {
      throw Self.contextualizedSelectorError(error)
    }

    try Task.checkCancellation()
    let writer = try Self.makeLiveWriter(displayID: stableID)
    return try await HardwareProcessLock.withLock {
      try await writer.write(value, to: selector)
    }
  }

  private static func makeLiveWriter(
    displayID: String
  ) throws -> DDCBrightnessWriter {
    let transport: AppleSiliconDDCTransport
    do {
      transport = try AppleSiliconDDCTransport.current()
    } catch let error as DDCTransportError {
      throw transportInitializationError(error, displayID: displayID)
    } catch {
      throw DisplayDJError(
        code: .internalFailure,
        message: "The Apple Silicon DDC transport could not be initialized.",
        operation: .write,
        displayID: displayID,
        backend: backend,
        details: [
          "phase": "transport-initialization",
          "reason": "unexpected-transport-initialization-error",
          "underlyingError": String(describing: error),
        ]
      )
    }

    return DDCBrightnessWriter(
      discovery: CoreGraphicsDisplayDiscovery(),
      backend: backend,
      serviceMatcher: DDCServiceMatcher.current(for: backend),
      executor: DDCVCPExecutor(
        transport: transport,
        laneRegistry: .processShared
      )
    )
  }

  private static func contextualizedValueError(
    _ error: DisplayDJError,
    displayID: String
  ) -> DisplayDJError {
    var details = error.details
    details["phase"] = "value-validation"

    return DisplayDJError(
      code: error.code,
      message: error.message,
      operation: .write,
      displayID: displayID,
      backend: backend,
      details: details
    )
  }

  private static func contextualizedSelectorError(
    _ error: DisplayDJError
  ) -> DisplayDJError {
    var details = error.details
    details["phase"] = "selection"

    return DisplayDJError(
      code: error.code,
      message: error.message,
      operation: .write,
      displayID: error.displayID,
      backend: backend,
      details: details
    )
  }

  private static func transportInitializationError(
    _ error: DDCTransportError,
    displayID: String
  ) -> DisplayDJError {
    switch error {
    case .unavailable(let reason):
      return DisplayDJError(
        code: .backendUnavailable,
        message: "The Apple Silicon DDC transport is unavailable.",
        operation: .write,
        displayID: displayID,
        backend: backend,
        details: [
          "phase": "transport-initialization",
          "reason": "transport-unavailable",
          "transportReason": reason,
        ]
      )
    case .busy, .timedOut, .noReply, .transientFailure, .permanentFailure:
      return DisplayDJError(
        code: .internalFailure,
        message: "The Apple Silicon DDC transport failed during initialization.",
        operation: .write,
        displayID: displayID,
        backend: backend,
        details: [
          "phase": "transport-initialization",
          "reason": "unexpected-transport-initialization-state",
          "underlyingError": String(describing: error),
        ]
      )
    }
  }
}
