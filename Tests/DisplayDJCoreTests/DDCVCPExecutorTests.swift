import Testing

@testable import DisplayDJCore

@Test("Get VCP execution sends one exact request and returns the parsed value")
func getVCPExecutionReturnsParsedValue() async throws {
  let transport = ScriptedDDCTransport(
    actions: [.complete(.success(maximumValue: 100, currentValue: 50))]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(maximumAttempts: 1, attemptTimeout: nil)
  )
  let target = makeTransportTarget(resourceID: 0x100)

  let value = try await executor.getFeature(0x10, from: target)
  let snapshot = await transport.snapshot()

  #expect(
    value
      == DDCVCPFeatureValue(
        featureCode: 0x10,
        valueType: .setParameter,
        maximumValue: 100,
        currentValue: 50
      )
  )
  #expect(snapshot.calls.count == 1)
  #expect(snapshot.calls[0].request.replyCapacity == 11)
  #expect(snapshot.calls[0].request.logicalFrame == [0x51, 0x82, 0x01, 0x10, 0xAC])
  #expect(snapshot.calls[0].target == target)
}

@Test("Only retryable transport and malformed-frame failures are retried")
func retryableDDCFailuresAreBounded() async throws {
  var badChecksum = getFeatureReply(featureCode: 0x10)
  badChecksum[badChecksum.count - 1] ^= 0x01
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.failure(.busy)),
      .complete(.response(badChecksum)),
      .complete(.success(maximumValue: 100, currentValue: 73)),
    ]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(maximumAttempts: 3, attemptTimeout: nil)
  )

  let value = try await executor.getFeature(
    0x10,
    from: makeTransportTarget(resourceID: 0x101)
  )
  let snapshot = await transport.snapshot()

  #expect(value.currentValue == 73)
  #expect(snapshot.calls.count == 3)
  #expect(
    snapshot.calls.map(\.request.logicalFrame).allSatisfy {
      $0 == [0x51, 0x82, 0x01, 0x10, 0xAC]
    })
}

@Test("Unavailable, unsupported, and semantic DDC failures never retry")
func terminalDDCFailuresDoNotRetry() async {
  let cases = [
    TerminalFailureCase(
      outcome: .failure(.unavailable(reason: "missing-entrypoint")),
      code: .backendUnavailable,
      reason: "transport-unavailable"
    ),
    TerminalFailureCase(
      outcome: .response(
        getFeatureReply(featureCode: 0x10, resultCode: 0x01)
      ),
      code: .unsupported,
      reason: "ddc-feature-unsupported"
    ),
    TerminalFailureCase(
      outcome: .response(
        getFeatureReply(featureCode: 0x12)
      ),
      code: .transportFailure,
      reason: "invalid-ddc-reply"
    ),
    TerminalFailureCase(
      outcome: .response(
        getFeatureReply(featureCode: 0x10, resultCode: 0x7F)
      ),
      code: .transportFailure,
      reason: "ddc-negative-result"
    ),
  ]

  for (index, testCase) in cases.enumerated() {
    let transport = ScriptedDDCTransport(actions: [.complete(testCase.outcome)])
    let executor = DDCVCPExecutor(
      transport: transport,
      policy: DDCExecutionPolicy(maximumAttempts: 3, attemptTimeout: nil)
    )
    let error = await capturedDisplayDJError {
      try await executor.getFeature(
        0x10,
        from: makeTransportTarget(resourceID: UInt64(0x200 + index))
      )
    }
    let snapshot = await transport.snapshot()

    #expect(error?.code == testCase.code)
    #expect(error?.details["reason"] == testCase.reason)
    #expect(error?.details["attempts"] == "1")
    #expect(error?.details["maximumAttempts"] == "3")
    #expect(snapshot.calls.count == 1)
  }
}

@Test("Checksum-valid null replies exhaust retries without becoming timeouts")
func nullDDCRepliesRemainTransportFailures() async {
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.response([0x6E, 0x80, 0xBE])),
      .complete(.response([0x6E, 0x80, 0xBE])),
    ]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(maximumAttempts: 2, attemptTimeout: nil)
  )
  let error = await capturedDisplayDJError {
    try await executor.getFeature(
      0x10,
      from: makeTransportTarget(resourceID: 0x300)
    )
  }

  #expect(error?.code == .transportFailure)
  #expect(error?.details["reason"] == "ddc-null-reply")
  #expect(error?.details["attempts"] == "2")
  #expect(await transport.snapshot().calls.count == 2)
}

@Test("One transport resource stays serial across a complete retry sequence")
func sameDDCResourceIsSerialAcrossRetries() async throws {
  let retryGate = TestGate()
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.failure(.busy)),
      .gated(
        retryGate,
        .success(maximumValue: 100, currentValue: 41)
      ),
      .complete(.success(maximumValue: 100, currentValue: 12)),
    ]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(maximumAttempts: 2, attemptTimeout: nil)
  )
  let target = makeTransportTarget(resourceID: 0x400)

  async let firstValue = executor.getFeature(0x10, from: target)
  await transport.waitUntilCallCount(2)
  async let secondValue = executor.getFeature(0x12, from: target)
  for _ in 0..<20 {
    await Task.yield()
  }
  await retryGate.open()

  let values = try await (firstValue, secondValue)
  let snapshot = await transport.snapshot()

  #expect(values.0.currentValue == 41)
  #expect(values.1.currentValue == 12)
  #expect(snapshot.calls.map(\.featureCode) == [0x10, 0x10, 0x12])
  #expect(snapshot.maximumActiveByKey[target.serializationKey] == 1)
}

@Test("Independent DDC transport resources may overlap")
func independentDDCResourcesCanRunConcurrently() async throws {
  let barrier = TestBarrier(participantCount: 2)
  let transport = ScriptedDDCTransport(
    actions: [
      .barrier(
        barrier,
        .success(maximumValue: 100, currentValue: 10)
      ),
      .barrier(
        barrier,
        .success(maximumValue: 100, currentValue: 20)
      ),
    ]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(maximumAttempts: 1, attemptTimeout: nil)
  )
  let firstTarget = makeTransportTarget(resourceID: 0x501)
  let secondTarget = makeTransportTarget(resourceID: 0x502, runtimeID: 43)

  async let firstValue = executor.getFeature(0x10, from: firstTarget)
  async let secondValue = executor.getFeature(0x12, from: secondTarget)
  let values = try await (firstValue, secondValue)
  let snapshot = await transport.snapshot()

  #expect(Set([values.0.currentValue, values.1.currentValue]) == Set([10, 20]))
  #expect(snapshot.maximumActiveOverall == 2)
  #expect(snapshot.maximumActiveByKey[firstTarget.serializationKey] == 1)
  #expect(snapshot.maximumActiveByKey[secondTarget.serializationKey] == 1)
}

@Test("A soft timeout waits for the cancelled attempt to settle before retrying")
func softTimeoutDrainsAttemptBeforeRetry() async throws {
  let transportGate = TestGate()
  let deadlineGate = TestGate()
  let eventStream = AsyncStream.makeStream(of: TransportEvent.self)
  let transport = ScriptedDDCTransport(
    actions: [
      .cancellationGated(
        transportGate,
        .success(maximumValue: 100, currentValue: 1)
      ),
      .complete(.success(maximumValue: 100, currentValue: 88)),
    ],
    eventContinuation: eventStream.continuation
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    deadlineWaiter: ManualDeadlineWaiter(gate: deadlineGate),
    policy: DDCExecutionPolicy(
      maximumAttempts: 2,
      attemptTimeout: .seconds(60)
    )
  )
  let target = makeTransportTarget(resourceID: 0x600)
  var events = eventStream.stream.makeAsyncIterator()

  async let value = executor.getFeature(0x10, from: target)
  await transport.waitUntilCallCount(1)
  await deadlineGate.open()

  var observedCancellation = false
  while let event = await events.next() {
    if event == .cancelled(callIndex: 0) {
      observedCancellation = true
      break
    }
  }
  #expect(observedCancellation)
  for _ in 0..<20 {
    await Task.yield()
  }
  #expect(await transport.snapshot().calls.count == 1)

  await transportGate.open()
  let resolvedValue = try await value
  let snapshot = await transport.snapshot()

  #expect(resolvedValue.currentValue == 88)
  #expect(snapshot.calls.count == 2)
  #expect(snapshot.maximumActiveByKey[target.serializationKey] == 1)
}

@Test("An exhausted soft timeout maps to the stable timeout error")
func exhaustedSoftTimeoutMapsToTimeout() async {
  let transportGate = TestGate()
  let deadlineGate = TestGate()
  let eventStream = AsyncStream.makeStream(of: TransportEvent.self)
  let timeoutAction = TransportAction.cancellationGated(
    transportGate,
    .success(maximumValue: 100, currentValue: 1)
  )
  let transport = ScriptedDDCTransport(
    actions: [timeoutAction],
    eventContinuation: eventStream.continuation
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    deadlineWaiter: ManualDeadlineWaiter(gate: deadlineGate),
    policy: DDCExecutionPolicy(
      maximumAttempts: 1,
      attemptTimeout: .seconds(60)
    )
  )
  var events = eventStream.stream.makeAsyncIterator()

  async let error = capturedDisplayDJError {
    try await executor.getFeature(
      0x10,
      from: makeTransportTarget(resourceID: 0x601)
    )
  }
  await transport.waitUntilCallCount(1)
  await deadlineGate.open()
  while let event = await events.next() {
    if event == .cancelled(callIndex: 0) {
      break
    }
  }
  await transportGate.open()

  let resolvedError = await error
  #expect(resolvedError?.code == .timeout)
  #expect(resolvedError?.details["reason"] == "attempt-timeout")
  #expect(resolvedError?.details["attempts"] == "1")
  #expect(await transport.snapshot().calls.count == 1)
}

@Test("Caller cancellation propagates and never starts a retry")
func callerCancellationDoesNotRetry() async {
  let transportGate = TestGate()
  let transport = ScriptedDDCTransport(
    actions: [
      .cancellationGated(
        transportGate,
        .success(maximumValue: 100, currentValue: 1)
      ),
      .complete(.success(maximumValue: 100, currentValue: 99)),
    ]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(
      maximumAttempts: 2,
      attemptTimeout: .seconds(60)
    )
  )
  let task = Task {
    try await executor.getFeature(
      0x10,
      from: makeTransportTarget(resourceID: 0x700)
    )
  }

  await transport.waitUntilCallCount(1)
  task.cancel()
  await transportGate.open()

  do {
    _ = try await task.value
    Issue.record("Expected caller cancellation.")
  } catch is CancellationError {
    // Expected.
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
  #expect(await transport.snapshot().calls.count == 1)
}

private struct TerminalFailureCase: Sendable {
  let outcome: TransportOutcome
  let code: DisplayDJErrorCode
  let reason: String
}
