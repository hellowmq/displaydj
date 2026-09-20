struct DDCVCPFeatureWriteResult: Equatable, Sendable {
  let baselineValue: DDCVCPFeatureValue
  let requestedRawValue: UInt16
  let verifiedValue: DDCVCPFeatureValue
  let didWrite: Bool
}

private struct DDCBaselineWriteContext: Sendable {
  let featureCode: UInt8
  let baselineValue: DDCVCPFeatureValue
  let requestedRawValue: UInt16
  let target: DDCTransportTarget
  let dependencies: DDCExecutionDependencies
}

private enum DDCRestorationOutcome: Sendable {
  case verified
  case failed(DisplayDJError)
}

extension DDCVCPExecutor {
  static func executeBaselineWrite(
    _ featureCode: UInt8,
    on target: DDCTransportTarget,
    using dependencies: DDCExecutionDependencies,
    rawValue: @escaping @Sendable (DDCVCPFeatureValue) throws -> UInt16,
    finalValidation: @escaping @Sendable () async throws -> Void
  ) async throws -> DDCVCPFeatureWriteResult {
    let baselineValue = try await executeGetFeature(
      featureCode,
      from: target,
      using: dependencies,
      errorContext: DDCExecutionErrorContext(
        operation: .write,
        details: [
          "phase": "baseline-read",
          "writeState": "not-sent",
        ]
      )
    )
    let requestedRawValue = try rawValue(baselineValue)
    try Task.checkCancellation()

    guard requestedRawValue != baselineValue.currentValue else {
      try await finalValidation()
      try Task.checkCancellation()
      return DDCVCPFeatureWriteResult(
        baselineValue: baselineValue,
        requestedRawValue: requestedRawValue,
        verifiedValue: baselineValue,
        didWrite: false
      )
    }

    return try await executeAttemptedBaselineWrite(
      DDCBaselineWriteContext(
        featureCode: featureCode,
        baselineValue: baselineValue,
        requestedRawValue: requestedRawValue,
        target: target,
        dependencies: dependencies
      ),
      finalValidation: finalValidation
    )
  }

  private static func executeAttemptedBaselineWrite(
    _ context: DDCBaselineWriteContext,
    finalValidation: @escaping @Sendable () async throws -> Void
  ) async throws -> DDCVCPFeatureWriteResult {
    do {
      let verifiedValue = try await executeSetFeature(
        context.featureCode,
        to: context.requestedRawValue,
        on: context.target,
        using: context.dependencies,
        operation: .write
      )
      try requireCompatibleReadBack(
        verifiedValue,
        baselineValue: context.baselineValue,
        requestedRawValue: context.requestedRawValue,
        target: context.target,
        operation: .write
      )
      try await finalValidation()
      try Task.checkCancellation()
      return DDCVCPFeatureWriteResult(
        baselineValue: context.baselineValue,
        requestedRawValue: context.requestedRawValue,
        verifiedValue: verifiedValue,
        didWrite: true
      )
    } catch {
      let restoration = await restoreFeatureIgnoringCancellation(context)
      try throwAfterRestoration(
        restoration,
        primaryError: error,
        context: context
      )
    }
  }

  private static func restoreFeatureIgnoringCancellation(
    _ context: DDCBaselineWriteContext
  ) async -> DDCRestorationOutcome {
    let restorationTask = Task {
      let restoredValue = try await executeSetFeature(
        context.featureCode,
        to: context.baselineValue.currentValue,
        on: context.target,
        using: context.dependencies,
        operation: .restore
      )
      try requireCompatibleReadBack(
        restoredValue,
        baselineValue: context.baselineValue,
        requestedRawValue: context.baselineValue.currentValue,
        target: context.target,
        operation: .restore
      )
      return restoredValue
    }

    do {
      _ = try await restorationTask.value
      return .verified
    } catch let error as DisplayDJError {
      return .failed(error)
    } catch {
      return .failed(
        unexpectedRestorationFailure(
          error,
          target: context.target,
          baselineValue: context.baselineValue.currentValue,
          requestedRawValue: context.requestedRawValue
        )
      )
    }
  }

  private static func throwAfterRestoration(
    _ restoration: DDCRestorationOutcome,
    primaryError: any Error,
    context: DDCBaselineWriteContext
  ) throws -> Never {
    switch restoration {
    case .verified:
      if primaryError is CancellationError {
        throw CancellationError()
      }
      if let displayError = primaryError as? DisplayDJError {
        throw failureWithVerifiedRestoration(
          displayError,
          baselineValue: context.baselineValue.currentValue,
          requestedRawValue: context.requestedRawValue
        )
      }
      throw unexpectedWriteFailure(
        primaryError,
        target: context.target,
        baselineValue: context.baselineValue.currentValue,
        requestedRawValue: context.requestedRawValue,
        restorationState: "verified"
      )
    case .failed(let restorationError):
      throw restorationFailure(
        restorationError,
        primaryError: primaryError,
        baselineValue: context.baselineValue.currentValue,
        requestedRawValue: context.requestedRawValue
      )
    }
  }
}
