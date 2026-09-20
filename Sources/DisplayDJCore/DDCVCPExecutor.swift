import Foundation

struct DDCExecutionDependencies: Sendable {
  let transport: any DDCTransport
  let deadlineWaiter: any DDCDeadlineWaiting
  let policy: DDCExecutionPolicy
}

struct DDCExecutionErrorContext: Sendable {
  let operation: ControlOperation
  let details: [String: String]

  static let read = DDCExecutionErrorContext(operation: .read, details: [:])
}

/// Executes transport-neutral DDC/CI VCP requests.
///
/// A serialization lane covers the complete logical operation, including
/// retries, verification, and timeout cleanup, while different resource keys
/// may proceed independently. Production executors share a process registry;
/// injected test executors remain isolated unless given the same registry.
actor DDCVCPExecutor {
  private static let getFeatureReplyCapacity = 11
  private static let setFeatureReplyCapacity = 0
  /// Consecutive Set frames sent once a single frame failed verification. A
  /// display that ignores an isolated frame applies the value when an identical
  /// frame immediately follows it.
  private static let repeatedSetFrameCount = 2

  private let dependencies: DDCExecutionDependencies
  private let laneRegistry: DDCExecutionLaneRegistry

  init(
    transport: any DDCTransport,
    deadlineWaiter: any DDCDeadlineWaiting = ContinuousDDCDeadlineWaiter(),
    policy: DDCExecutionPolicy = DDCExecutionPolicy(),
    laneRegistry: DDCExecutionLaneRegistry = DDCExecutionLaneRegistry()
  ) {
    dependencies = DDCExecutionDependencies(
      transport: transport,
      deadlineWaiter: deadlineWaiter,
      policy: policy
    )
    self.laneRegistry = laneRegistry
  }

  func getFeature(
    _ featureCode: UInt8,
    from target: DDCTransportTarget
  ) async throws -> DDCVCPFeatureValue {
    let lane = await laneRegistry.lane(for: target.serializationKey)
    let dependencies = dependencies

    return try await lane.perform {
      try await Self.executeGetFeature(
        featureCode,
        from: target,
        using: dependencies
      )
    }
  }

  /// Sends one Set VCP request, then reads the same feature back while retaining
  /// the target's serialization lane. A transport failure is never retried,
  /// because whether the display applied that write can be unknown. A read-back
  /// disagreement is different: the write demonstrably reached the display and
  /// was ignored, so the frame is repeated up to the policy's Set attempt limit.
  func setFeature(
    _ featureCode: UInt8,
    to rawValue: UInt16,
    on target: DDCTransportTarget
  ) async throws -> DDCVCPFeatureValue {
    let lane = await laneRegistry.lane(for: target.serializationKey)
    let dependencies = dependencies

    return try await lane.perform {
      try await Self.executeSetFeature(
        featureCode,
        to: rawValue,
        on: target,
        using: dependencies
      )
    }
  }

  /// Reads a baseline, derives one raw target value, and keeps the resource lane
  /// through the Set attempts, read-back, final validation, and any required
  /// restoration. A failed or cancelled attempted write is restored to the exact
  /// baseline raw value before its original failure is returned.
  func setFeatureUsingBaseline(
    _ featureCode: UInt8,
    on target: DDCTransportTarget,
    rawValue: @escaping @Sendable (DDCVCPFeatureValue) throws -> UInt16,
    finalValidation: @escaping @Sendable () async throws -> Void
  ) async throws -> DDCVCPFeatureWriteResult {
    let lane = await laneRegistry.lane(for: target.serializationKey)
    let dependencies = dependencies

    return try await lane.perform {
      try await Self.executeBaselineWrite(
        featureCode,
        on: target,
        using: dependencies,
        rawValue: rawValue,
        finalValidation: finalValidation
      )
    }
  }
}

extension DDCVCPExecutor {
  static func executeSetFeature(
    _ featureCode: UInt8,
    to rawValue: UInt16,
    on target: DDCTransportTarget,
    using dependencies: DDCExecutionDependencies,
    operation: ControlOperation = .write
  ) async throws -> DDCVCPFeatureValue {
    let errorContext = setVerificationErrorContext(
      operation: operation,
      rawValue: rawValue
    )
    let maximumSetAttempts = dependencies.policy.maximumSetAttempts

    for attempt in 1...maximumSetAttempts {
      try await performSetExchange(
        featureCode,
        rawValue: rawValue,
        target: target,
        dependencies: dependencies,
        operation: operation,
        writeFrameCount: attempt == 1 ? 1 : repeatedSetFrameCount
      )
      let verifiedValue = try await executeGetFeature(
        featureCode,
        from: target,
        using: dependencies,
        errorContext: errorContext,
        replyDelay: 0.15
      )
      if verifiedValue.currentValue == rawValue {
        return verifiedValue
      }
      guard attempt < maximumSetAttempts else {
        throw finalized(
          verificationFailure(
            featureCode: featureCode,
            requestedValue: rawValue,
            verifiedValue: verifiedValue,
            target: target,
            operation: operation
          ),
          attempts: attempt,
          maximumAttempts: maximumSetAttempts
        )
      }
    }

    var details = errorContext.details
    details["reason"] = "unreachable-set-attempt-loop"
    throw DisplayDJError(
      code: .internalFailure,
      message: "The DDC executor exhausted an unreachable Set attempt loop.",
      operation: errorContext.operation,
      displayID: selector(for: target.display),
      backend: target.backend,
      details: details
    )
  }

  private static func performSetExchange(
    _ featureCode: UInt8,
    rawValue: UInt16,
    target: DDCTransportTarget,
    dependencies: DDCExecutionDependencies,
    operation: ControlOperation,
    writeFrameCount: Int
  ) async throws {
    let request = DDCTransportRequest(
      logicalFrame: DDCVCPCodec.setFeatureRequest(
        featureCode: featureCode,
        value: rawValue
      ),
      replyCapacity: setFeatureReplyCapacity,
      replyDelay: 0,
      writeFrameCount: writeFrameCount
    )
    let errorContext = setExchangeErrorContext(operation: operation)

    do {
      let response = try await exchange(
        request,
        on: target,
        using: dependencies
      )
      guard response.exactFrame.isEmpty else {
        throw DDCUnexpectedSetReply(byteCount: response.exactFrame.count)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      let failure = mappedFailure(
        for: error,
        featureCode: featureCode,
        target: target,
        errorContext: errorContext
      )
      throw finalized(
        failure.error,
        attempts: 1,
        maximumAttempts: 1
      )
    }
  }

  private static func setExchangeErrorContext(
    operation: ControlOperation
  ) -> DDCExecutionErrorContext {
    if operation == .restore {
      return DDCExecutionErrorContext(
        operation: .restore,
        details: [
          "phase": "restore-write",
          "restorationState": "unknown",
        ]
      )
    }
    return DDCExecutionErrorContext(
      operation: .write,
      details: [
        "phase": "write",
        "writeState": "unknown",
      ]
    )
  }

  private static func setVerificationErrorContext(
    operation: ControlOperation,
    rawValue: UInt16
  ) -> DDCExecutionErrorContext {
    if operation == .restore {
      return DDCExecutionErrorContext(
        operation: .restore,
        details: [
          "phase": "restore-verification-read",
          "restorationState": "sent-unverified",
          "restoredValue": String(rawValue),
        ]
      )
    }
    return DDCExecutionErrorContext(
      operation: .write,
      details: [
        "phase": "verification-read",
        "requestedValue": String(rawValue),
        "writeState": "sent-unverified",
      ]
    )
  }

  static func executeGetFeature(
    _ featureCode: UInt8,
    from target: DDCTransportTarget,
    using dependencies: DDCExecutionDependencies,
    errorContext: DDCExecutionErrorContext = .read,
    replyDelay: TimeInterval = 0.05
  ) async throws -> DDCVCPFeatureValue {
    let request = DDCTransportRequest(
      logicalFrame: DDCVCPCodec.getFeatureRequest(featureCode: featureCode),
      replyCapacity: getFeatureReplyCapacity,
      replyDelay: replyDelay
    )

    for attempt in 1...dependencies.policy.maximumAttempts {
      try Task.checkCancellation()

      do {
        return try await getFeatureAttempt(
          request,
          featureCode: featureCode,
          target: target,
          dependencies: dependencies,
          errorContext: errorContext
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        try Task.checkCancellation()
        let failure = mappedFailure(
          for: error,
          featureCode: featureCode,
          target: target,
          errorContext: errorContext
        )
        guard
          failure.isRetryable,
          attempt < dependencies.policy.maximumAttempts
        else {
          throw finalized(
            failure.error,
            attempts: attempt,
            maximumAttempts: dependencies.policy.maximumAttempts
          )
        }
      }
    }

    var details = errorContext.details
    details["reason"] = "unreachable-attempt-loop"
    throw DisplayDJError(
      code: .internalFailure,
      message: "The DDC executor exhausted an unreachable attempt loop.",
      operation: errorContext.operation,
      displayID: selector(for: target.display),
      backend: target.backend,
      details: details
    )
  }

  private static func getFeatureAttempt(
    _ request: DDCTransportRequest,
    featureCode: UInt8,
    target: DDCTransportTarget,
    dependencies: DDCExecutionDependencies,
    errorContext: DDCExecutionErrorContext
  ) async throws -> DDCVCPFeatureValue {
    let response = try await exchange(
      request,
      on: target,
      using: dependencies
    )
    let reply = try DDCVCPCodec.parseGetFeatureReply(
      response.exactFrame,
      expectedFeatureCode: featureCode
    )
    return try featureValue(
      from: reply,
      featureCode: featureCode,
      target: target,
      errorContext: errorContext
    )
  }

  /// This is a cooperative, soft timeout. Cancelling the transport task cannot
  /// forcibly stop a blocking driver call, so the task group is drained before
  /// the attempt returns, retries, or releases its serialization lane.
  private static func exchange(
    _ request: DDCTransportRequest,
    on target: DDCTransportTarget,
    using dependencies: DDCExecutionDependencies
  ) async throws -> DDCTransportResponse {
    guard let timeout = dependencies.policy.attemptTimeout else {
      let response = try await dependencies.transport.exchange(request, on: target)
      try Task.checkCancellation()
      return response
    }

    return try await withThrowingTaskGroup(
      of: DDCExchangeRaceResult.self,
      returning: DDCTransportResponse.self
    ) { group in
      group.addTask {
        .response(
          try await dependencies.transport.exchange(request, on: target)
        )
      }
      group.addTask {
        try await dependencies.deadlineWaiter.wait(for: timeout)
        return .deadline
      }

      do {
        guard let first = try await group.next() else {
          throw DDCExecutionInvariantError.missingRaceResult
        }
        group.cancelAll()
        while !group.isEmpty {
          do {
            _ = try await group.next()
          } catch {
            // The winning result is authoritative. Losing-task cancellation or
            // failure is still awaited, but must not replace that result.
          }
        }
        try Task.checkCancellation()

        switch first {
        case .response(let response):
          return response
        case .deadline:
          throw DDCAttemptDeadlineExceeded()
        }
      } catch {
        group.cancelAll()
        while !group.isEmpty {
          do {
            _ = try await group.next()
          } catch {
            // Drain every child so no exchange outlives this attempt.
          }
        }
        try Task.checkCancellation()
        throw error
      }
    }
  }
}

struct DDCMappedFailure: Error, Sendable {
  let error: DisplayDJError
  let isRetryable: Bool
}

struct DDCAttemptDeadlineExceeded: Error, Sendable {}

struct DDCUnexpectedSetReply: Error, Sendable {
  let byteCount: Int
}

private enum DDCExchangeRaceResult: Sendable {
  case response(DDCTransportResponse)
  case deadline
}

private enum DDCExecutionInvariantError: Error, Sendable {
  case missingRaceResult
}
