/// A run-scoped bridge from a complete display topology to DDC/CI execution.
///
/// The prepared matcher remains scoped to the supplied topology. Runtime
/// service identities are resolved immediately before each operation and are
/// never persisted as stable display selectors. Callers should share one
/// executor across sessions that may address the same transport resource so its
/// serialization lanes remain authoritative.
struct DDCVCPReadSession: Sendable {
  private let backend: BackendKind
  private let preparedDisplays: Set<DisplayDescriptor>
  private let serviceMatcher: any DDCServiceMatching
  private let executor: DDCVCPExecutor

  static func prepare(
    backend: BackendKind,
    displays: [DisplayDescriptor],
    serviceMatcher: any DDCServiceMatching,
    executor: DDCVCPExecutor
  ) async throws -> DDCVCPReadSession {
    try Task.checkCancellation()
    let scopedMatcher = await serviceMatcher.prepared(for: displays)
    try Task.checkCancellation()

    return DDCVCPReadSession(
      backend: backend,
      preparedDisplays: Set(displays),
      serviceMatcher: scopedMatcher,
      executor: executor
    )
  }

  func getFeature(
    _ featureCode: UInt8,
    from display: DisplayDescriptor
  ) async throws -> DDCVCPFeatureValue {
    let target = try await transportTarget(
      featureCode,
      for: display,
      operation: .read
    )
    return try await executor.getFeature(featureCode, from: target)
  }

  func transportTarget(
    _ featureCode: UInt8,
    for display: DisplayDescriptor,
    operation: ControlOperation
  ) async throws -> DDCTransportTarget {
    let context = DDCSessionOperationContext(
      featureCode: featureCode,
      display: display,
      operation: operation
    )
    try Task.checkCancellation()
    guard preparedDisplays.contains(display) else {
      throw executionError(
        code: .conflict,
        message: [
          "The display is outside the topology used to prepare",
          "this DDC \(operation.rawValue) session.",
        ].joined(separator: " "),
        context: context,
        details: ["reason": "display-outside-prepared-topology"]
      )
    }

    let association = try await serviceAssociation(context)
    try Task.checkCancellation()
    return try transportTarget(for: association, context: context)
  }

  private func transportTarget(
    for association: DDCServiceAssociation,
    context: DDCSessionOperationContext
  ) throws -> DDCTransportTarget {
    switch association {
    case .matched(let service):
      return DDCTransportTarget(
        display: context.display,
        backend: backend,
        service: service
      )
    case .notFound(let reason):
      throw executionError(
        code: .backendUnavailable,
        message: "No per-display DDC service is available. \(reason)",
        context: context,
        details: [
          "associationReason": reason,
          "reason": "ddc-service-not-found",
        ]
      )
    case .unresolved(let reason):
      throw executionError(
        code: .conflict,
        message: "The DDC service association is indeterminate. \(reason)",
        context: context,
        details: [
          "associationReason": reason,
          "reason": "ddc-service-association-unresolved",
        ]
      )
    case .ambiguous(let candidateCount, let reason):
      throw executionError(
        code: .conflict,
        message: "Multiple DDC services match this display. \(reason)",
        context: context,
        details: [
          "associationReason": reason,
          "candidateCount": String(candidateCount),
          "reason": "ddc-service-association-ambiguous",
        ]
      )
    }
  }

  private func serviceAssociation(
    _ context: DDCSessionOperationContext
  ) async throws -> DDCServiceAssociation {
    do {
      return try await serviceMatcher.association(for: context.display)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as DDCServiceMatchingError {
      try Task.checkCancellation()
      throw executionError(
        code: .transportFailure,
        message: error.message,
        context: context,
        details: error.details
      )
    } catch {
      try Task.checkCancellation()
      throw executionError(
        code: .transportFailure,
        message: [
          "DDC service matching failed unexpectedly during",
          "a \(context.operation.rawValue).",
        ].joined(separator: " "),
        context: context,
        details: [
          "reason": "unexpected-service-matching-error",
          "underlyingError": String(describing: error),
        ]
      )
    }
  }

  private func executionError(
    code: DisplayDJErrorCode,
    message: String,
    context: DDCSessionOperationContext,
    details: [String: String]
  ) -> DisplayDJError {
    var mergedDetails = details
    mergedDetails["featureCode"] = Self.hex(context.featureCode)

    return DisplayDJError(
      code: code,
      message: message,
      operation: context.operation,
      displayID: context.display.stableID ?? "runtime:\(context.display.runtimeID)",
      backend: backend,
      details: mergedDetails
    )
  }

  private static func hex(_ byte: UInt8) -> String {
    let digits = String(byte, radix: 16, uppercase: true)
    return "0x" + String(repeating: "0", count: 2 - digits.count) + digits
  }
}

private struct DDCSessionOperationContext: Sendable {
  let featureCode: UInt8
  let display: DisplayDescriptor
  let operation: ControlOperation
}
