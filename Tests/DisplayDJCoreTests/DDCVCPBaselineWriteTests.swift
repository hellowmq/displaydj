import Testing

@testable import DisplayDJCore

@Test("Baseline write retains one resource lane through final validation")
func baselineWriteRetainsLaneThroughFinalValidation() async throws {
  let validationGate = TestGate()
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.success(maximumValue: 255, currentValue: 17)),
      .complete(.response([])),
      .complete(.success(maximumValue: 255, currentValue: 128)),
      .complete(.success(maximumValue: 100, currentValue: 20)),
    ]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(maximumAttempts: 1, attemptTimeout: nil)
  )
  let target = makeTransportTarget(resourceID: 0x900)
  let writeTask = Task {
    try await executor.setFeatureUsingBaseline(
      0x10,
      on: target,
      rawValue: { _ in 128 },
      finalValidation: { await validationGate.wait() }
    )
  }

  await transport.waitUntilCallCount(3)
  let queuedGet = Task { try await executor.getFeature(0x12, from: target) }
  for _ in 0..<20 {
    await Task.yield()
  }
  #expect(await transport.snapshot().calls.count == 3)
  await validationGate.open()

  let writeResult = try await writeTask.value
  let getResult = try await queuedGet.value
  let snapshot = await transport.snapshot()

  #expect(writeResult.baselineValue.currentValue == 17)
  #expect(writeResult.requestedRawValue == 128)
  #expect(writeResult.verifiedValue.currentValue == 128)
  #expect(writeResult.didWrite)
  #expect(getResult.currentValue == 20)
  #expect(snapshot.calls.map(\.opcode) == [0x01, 0x03, 0x01, 0x01])
  #expect(snapshot.calls.compactMap(\.setRawValue) == [128])
  #expect(snapshot.maximumActiveByKey[target.serializationKey] == 1)
}

@Test("Executors sharing a registry cannot interleave one transport resource")
func sharedRegistrySerializesAcrossExecutors() async throws {
  let validationGate = TestGate()
  let registry = DDCExecutionLaneRegistry()
  let writeTransport = ScriptedDDCTransport(
    actions: [
      .complete(.success(maximumValue: 100, currentValue: 20)),
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 30)),
    ]
  )
  let readTransport = ScriptedDDCTransport(
    actions: [.complete(.success(maximumValue: 100, currentValue: 40))]
  )
  let policy = DDCExecutionPolicy(maximumAttempts: 1, attemptTimeout: nil)
  let writeExecutor = DDCVCPExecutor(
    transport: writeTransport,
    policy: policy,
    laneRegistry: registry
  )
  let readExecutor = DDCVCPExecutor(
    transport: readTransport,
    policy: policy,
    laneRegistry: registry
  )
  let target = makeTransportTarget(resourceID: 0x901)
  let writeTask = Task {
    try await writeExecutor.setFeatureUsingBaseline(
      0x10,
      on: target,
      rawValue: { _ in 30 },
      finalValidation: { await validationGate.wait() }
    )
  }

  await writeTransport.waitUntilCallCount(3)
  let readTask = Task { try await readExecutor.getFeature(0x10, from: target) }
  for _ in 0..<20 {
    await Task.yield()
  }
  #expect(await readTransport.snapshot().calls.isEmpty)
  await validationGate.open()

  _ = try await writeTask.value
  let readValue = try await readTask.value
  #expect(readValue.currentValue == 40)
  #expect(await writeTransport.snapshot().calls.count == 3)
  #expect(await readTransport.snapshot().calls.count == 1)
}
