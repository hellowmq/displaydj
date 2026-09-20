/// The production, read-only Apple Silicon DDC brightness entry point.
///
/// Each call creates a fresh discovery and service-matching scope, then issues
/// only Get VCP feature `0x10`. It never sends a Set VCP request. The private
/// IOAV calls are synchronous, so callers performing hardware acceptance must
/// still run the CLI in a killable child process with a wall-clock deadline.
public struct AppleSiliconDDCBrightnessReader: Sendable {
  private static let backend = BackendKind.appleSiliconDDC

  public init() {}

  public func read(
    fromStableID displayID: String
  ) async throws -> ControlReadResult {
    let selector: DisplaySelector
    do {
      selector = try DisplayCLISelector.parse(displayID)
    } catch let error as DisplayDJError {
      throw Self.contextualizedSelectorError(error)
    }

    try Task.checkCancellation()
    let reader = try Self.makeLiveReader(displayID: displayID)
    return try await HardwareProcessLock.withLock {
      try await reader.read(from: selector)
    }
  }

  private static func makeLiveReader(
    displayID: String
  ) throws -> DDCBrightnessReader {
    let transport: AppleSiliconDDCTransport
    do {
      transport = try AppleSiliconDDCTransport.current()
    } catch let error as DDCTransportError {
      throw transportInitializationError(error, displayID: displayID)
    } catch {
      throw DisplayDJError(
        code: .internalFailure,
        message: "The Apple Silicon DDC transport could not be initialized.",
        operation: .read,
        displayID: displayID,
        backend: backend,
        details: [
          "phase": "transport-initialization",
          "reason": "unexpected-transport-initialization-error",
          "underlyingError": String(describing: error),
        ]
      )
    }

    return DDCBrightnessReader(
      discovery: CoreGraphicsDisplayDiscovery(),
      backend: backend,
      serviceMatcher: DDCServiceMatcher.current(for: backend),
      executor: DDCVCPExecutor(
        transport: transport,
        laneRegistry: .processShared
      )
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
      operation: .read,
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
        operation: .read,
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
        operation: .read,
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
