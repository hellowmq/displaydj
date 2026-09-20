import Testing

@testable import DisplayDJCore

@Test("Set VCP writes once and succeeds only after an exact read-back")
func setVCPExecutionVerifiesAppliedValue() async throws {
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 75)),
    ]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(maximumAttempts: 3, attemptTimeout: nil)
  )
  let target = makeTransportTarget(resourceID: 0x800)

  let verifiedValue = try await executor.setFeature(
    0x10,
    to: 75,
    on: target
  )
  let snapshot = await transport.snapshot()

  #expect(verifiedValue.currentValue == 75)
  #expect(snapshot.calls.count == 2)
  #expect(snapshot.calls.map(\.opcode) == [0x03, 0x01])
  #expect(snapshot.calls[0].request.replyCapacity == 0)
  #expect(
    snapshot.calls[0].request.logicalFrame
      == [0x51, 0x84, 0x03, 0x10, 0x00, 0x4B, 0xE3]
  )
  #expect(snapshot.calls[1].request.replyCapacity == 11)
  #expect(snapshot.calls[1].request.logicalFrame == [0x51, 0x82, 0x01, 0x10, 0xAC])
}

@Test("Set VCP transport failures are never blindly retried")
func setVCPTransportFailureDoesNotRetry() async {
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.failure(.busy)),
      .complete(.response([])),
    ]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(maximumAttempts: 3, attemptTimeout: nil)
  )
  let error = await capturedDisplayDJError {
    try await executor.setFeature(
      0x10,
      to: 75,
      on: makeTransportTarget(resourceID: 0x801)
    )
  }
  let snapshot = await transport.snapshot()

  #expect(error?.code == .busy)
  #expect(error?.operation == .write)
  #expect(error?.details["reason"] == "transport-busy")
  #expect(error?.details["phase"] == "write")
  #expect(error?.details["writeState"] == "unknown")
  #expect(error?.details["attempts"] == "1")
  #expect(error?.details["maximumAttempts"] == "1")
  #expect(snapshot.calls.count == 1)
}

@Test("Set VCP retries only the read-back exchange")
func setVCPReadBackRetryDoesNotRepeatWrite() async throws {
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.response([])),
      .complete(.failure(.busy)),
      .complete(.success(maximumValue: 100, currentValue: 75)),
    ]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(maximumAttempts: 2, attemptTimeout: nil)
  )

  let verifiedValue = try await executor.setFeature(
    0x10,
    to: 75,
    on: makeTransportTarget(resourceID: 0x802)
  )
  let snapshot = await transport.snapshot()

  #expect(verifiedValue.currentValue == 75)
  #expect(snapshot.calls.map(\.opcode) == [0x03, 0x01, 0x01])
  #expect(snapshot.calls.filter { $0.opcode == 0x03 }.count == 1)
}

@Test("A Set that one frame cannot apply is repeated as consecutive frames")
func setVCPEscalatesToRepeatedFramesAfterMismatch() async throws {
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 20)),
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 75)),
    ]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(maximumAttempts: 1, attemptTimeout: nil)
  )

  let verifiedValue = try await executor.setFeature(
    0x10,
    to: 75,
    on: makeTransportTarget(resourceID: 0x808)
  )
  let snapshot = await transport.snapshot()

  #expect(verifiedValue.currentValue == 75)
  #expect(snapshot.calls.map(\.opcode) == [0x03, 0x01, 0x03, 0x01])
  #expect(snapshot.calls.compactMap(\.setRawValue) == [75, 75])
  #expect(
    snapshot.calls.filter { $0.opcode == 0x03 }.map(\.request.writeFrameCount)
      == [1, 2]
  )
}

@Test("Set VCP reports a structured error once every frame count is exhausted")
func setVCPReadBackMismatchFailsVerification() async {
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 74)),
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 74)),
    ]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(maximumAttempts: 3, attemptTimeout: nil)
  )
  let error = await capturedDisplayDJError {
    try await executor.setFeature(
      0x10,
      to: 75,
      on: makeTransportTarget(resourceID: 0x803)
    )
  }
  let snapshot = await transport.snapshot()

  #expect(error?.code == .verificationFailed)
  #expect(error?.operation == .write)
  #expect(error?.details["reason"] == "ddc-write-verification-mismatch")
  #expect(error?.details["requestedValue"] == "75")
  #expect(error?.details["observedValue"] == "74")
  #expect(error?.details["maximumValue"] == "100")
  #expect(error?.details["phase"] == "verification-read")
  #expect(error?.details["writeState"] == "verification-mismatch")
  #expect(error?.details["attempts"] == "2")
  #expect(error?.details["maximumAttempts"] == "2")
  #expect(snapshot.calls.map(\.opcode) == [0x03, 0x01, 0x03, 0x01])
}

@Test("A single-attempt Set policy never puts a repeated frame on the bus")
func setVCPHonoursSingleAttemptPolicy() async {
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 74)),
    ]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(
      maximumAttempts: 1,
      attemptTimeout: nil,
      maximumSetAttempts: 1
    )
  )
  let error = await capturedDisplayDJError {
    try await executor.setFeature(
      0x10,
      to: 75,
      on: makeTransportTarget(resourceID: 0x809)
    )
  }
  let snapshot = await transport.snapshot()

  #expect(error?.code == .verificationFailed)
  #expect(error?.details["attempts"] == "1")
  #expect(error?.details["maximumAttempts"] == "1")
  #expect(snapshot.calls.map(\.opcode) == [0x03, 0x01])
  #expect(snapshot.calls[0].request.writeFrameCount == 1)
}

@Test("Set VCP never ignores unexpected transport reply bytes")
func setVCPUnexpectedReplyFailsBeforeVerification() async {
  let transport = ScriptedDDCTransport(
    actions: [.complete(.response([0x00]))]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(maximumAttempts: 3, attemptTimeout: nil)
  )
  let error = await capturedDisplayDJError {
    try await executor.setFeature(
      0x10,
      to: 75,
      on: makeTransportTarget(resourceID: 0x804)
    )
  }

  #expect(error?.code == .transportFailure)
  #expect(error?.operation == .write)
  #expect(error?.details["reason"] == "unexpected-set-reply")
  #expect(error?.details["replyByteCount"] == "1")
  #expect(error?.details["attempts"] == "1")
  #expect(await transport.snapshot().calls.count == 1)
}

@Test("Set VCP soft timeouts fail once without repeating an uncertain write")
func setVCPSoftTimeoutDoesNotRetryWrite() async {
  let transportGate = TestGate()
  let deadlineGate = TestGate()
  let eventStream = AsyncStream.makeStream(of: TransportEvent.self)
  let transport = ScriptedDDCTransport(
    actions: [
      .cancellationGated(transportGate, .response([])),
      .complete(.response([])),
    ],
    eventContinuation: eventStream.continuation
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    deadlineWaiter: ManualDeadlineWaiter(gate: deadlineGate),
    policy: DDCExecutionPolicy(
      maximumAttempts: 3,
      attemptTimeout: .seconds(60)
    )
  )
  var events = eventStream.stream.makeAsyncIterator()

  async let error = capturedDisplayDJError {
    try await executor.setFeature(
      0x10,
      to: 75,
      on: makeTransportTarget(resourceID: 0x805)
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
  #expect(resolvedError?.operation == .write)
  #expect(resolvedError?.details["phase"] == "write")
  #expect(resolvedError?.details["attempts"] == "1")
  #expect(resolvedError?.details["maximumAttempts"] == "1")
  #expect(await transport.snapshot().calls.count == 1)
}

@Test("Caller cancellation stops Set VCP before verification or retry")
func setVCPCallerCancellationStopsOperation() async {
  let transportGate = TestGate()
  let transport = ScriptedDDCTransport(
    actions: [
      .cancellationGated(transportGate, .response([])),
      .complete(.success(maximumValue: 100, currentValue: 75)),
    ]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(maximumAttempts: 3, attemptTimeout: nil)
  )
  let task = Task {
    try await executor.setFeature(
      0x10,
      to: 75,
      on: makeTransportTarget(resourceID: 0x806)
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

@Test("Cancellation wins when a Set transport ignores cancellation")
func setVCPCancellationWinsAgainstNonCooperativeTransport() async {
  let transportGate = TestGate()
  let transport = ScriptedDDCTransport(
    actions: [
      .gated(transportGate, .response([])),
      .complete(.success(maximumValue: 100, currentValue: 75)),
    ]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(maximumAttempts: 3, attemptTimeout: nil)
  )
  let task = Task {
    try await executor.setFeature(
      0x10,
      to: 75,
      on: makeTransportTarget(resourceID: 0x807)
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

@Test("A cancelled lane waiter completes before the active exchange releases")
func cancelledDDCLaneWaiterCompletesPromptly() async throws {
  let activeGate = TestGate()
  let completion = TestCompletionProbe()
  let transport = ScriptedDDCTransport(
    actions: [
      .gated(activeGate, .success(maximumValue: 100, currentValue: 10)),
      .complete(.success(maximumValue: 100, currentValue: 20)),
    ]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(maximumAttempts: 1, attemptTimeout: nil)
  )
  let target = makeTransportTarget(resourceID: 0x808)
  let activeTask = Task { try await executor.getFeature(0x10, from: target) }
  await transport.waitUntilCallCount(1)

  let waitingTask = Task {
    do {
      _ = try await executor.getFeature(0x12, from: target)
      Issue.record("Expected queued-operation cancellation.")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Unexpected error type: \(error)")
    }
    await completion.mark()
  }
  for _ in 0..<20 {
    await Task.yield()
  }
  waitingTask.cancel()
  let completedBeforeRelease = await waitForCompletion(completion)
  await activeGate.open()

  let activeValue = try await activeTask.value
  #expect(activeValue.currentValue == 10)
  await waitingTask.value
  #expect(completedBeforeRelease)
  #expect(await transport.snapshot().calls.count == 1)
}

@Test("Set VCP retains one resource lane through read-back verification")
func setVCPRetainsSerializationLaneThroughVerification() async throws {
  let verificationGate = TestGate()
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.response([])),
      .gated(
        verificationGate,
        .success(maximumValue: 100, currentValue: 75)
      ),
      .complete(.success(maximumValue: 100, currentValue: 20)),
    ]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(maximumAttempts: 1, attemptTimeout: nil)
  )
  let target = makeTransportTarget(resourceID: 0x807)

  async let setValue = executor.setFeature(0x10, to: 75, on: target)
  await transport.waitUntilCallCount(2)
  async let getValue = executor.getFeature(0x12, from: target)
  for _ in 0..<20 {
    await Task.yield()
  }
  #expect(await transport.snapshot().calls.count == 2)
  await verificationGate.open()

  let values = try await (setValue, getValue)
  let snapshot = await transport.snapshot()

  #expect(values.0.currentValue == 75)
  #expect(values.1.currentValue == 20)
  #expect(snapshot.calls.map(\.opcode) == [0x03, 0x01, 0x01])
  #expect(snapshot.maximumActiveByKey[target.serializationKey] == 1)
}
