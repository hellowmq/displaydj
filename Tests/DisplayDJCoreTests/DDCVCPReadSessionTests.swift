import Testing

@testable import DisplayDJCore

@Test("A prepared DDC read session associates one service and executes one exact Get VCP request")
func preparedDDCReadSessionExecutesGetVCP() async throws {
  let firstDisplay = makeReadSessionDisplay(runtimeID: 42, serialNumber: 51_580)
  let secondDisplay = makeReadSessionDisplay(runtimeID: 43, serialNumber: 51_581)
  let service = makeReadSessionService(registryEntryID: 0xA100)
  let recorder = ReadSessionMatcherRecorder()
  let matcher = RootReadSessionMatcher(
    outcome: .association(.matched(service)),
    recorder: recorder
  )
  let transport = ScriptedDDCTransport(
    actions: [.complete(.success(maximumValue: 100, currentValue: 64))]
  )
  let executor = DDCVCPExecutor(
    transport: transport,
    policy: DDCExecutionPolicy(maximumAttempts: 1, attemptTimeout: nil)
  )
  let topology = [firstDisplay, secondDisplay]

  let session = try await DDCVCPReadSession.prepare(
    backend: .appleSiliconDDC,
    displays: topology,
    serviceMatcher: matcher,
    executor: executor
  )
  let value = try await session.getFeature(0x10, from: firstDisplay)
  let matcherSnapshot = await recorder.snapshot()
  let transportSnapshot = await transport.snapshot()
  let call = try #require(transportSnapshot.calls.first)

  #expect(value.currentValue == 64)
  #expect(matcherSnapshot.preparedTopologies == [topology])
  #expect(matcherSnapshot.associatedDisplays == [firstDisplay])
  #expect(transportSnapshot.calls.count == 1)
  #expect(call.request.logicalFrame == [0x51, 0x82, 0x01, 0x10, 0xAC])
  #expect(call.request.replyCapacity == 11)
  #expect(call.target.display == firstDisplay)
  #expect(call.target.backend == .appleSiliconDDC)
  #expect(call.target.service == service)
  #expect(
    call.target.serializationKey
      == DDCSerializationKey(
        backend: .appleSiliconDDC,
        resourceID: service.registryEntryID
      )
  )
}

@Test("Non-unique DDC service associations fail before the transport is called")
func nonUniqueDDCReadAssociationsDoNotExecute() async throws {
  let cases = [
    ReadSessionAssociationFailureCase(
      association: .notFound(reason: "No service exists."),
      code: .backendUnavailable,
      reason: "ddc-service-not-found"
    ),
    ReadSessionAssociationFailureCase(
      association: .unresolved(reason: "Identity is incomplete."),
      code: .conflict,
      reason: "ddc-service-association-unresolved"
    ),
    ReadSessionAssociationFailureCase(
      association: .ambiguous(candidateCount: 2, reason: "Two services match."),
      code: .conflict,
      reason: "ddc-service-association-ambiguous",
      candidateCount: "2"
    ),
  ]

  for testCase in cases {
    let display = makeReadSessionDisplay()
    let recorder = ReadSessionMatcherRecorder()
    let matcher = RootReadSessionMatcher(
      outcome: .association(testCase.association),
      recorder: recorder
    )
    let transport = ScriptedDDCTransport(actions: [])
    let session = try await DDCVCPReadSession.prepare(
      backend: .appleSiliconDDC,
      displays: [display],
      serviceMatcher: matcher,
      executor: DDCVCPExecutor(
        transport: transport,
        policy: DDCExecutionPolicy(maximumAttempts: 1, attemptTimeout: nil)
      )
    )

    let error = await capturedDisplayDJError {
      try await session.getFeature(0x10, from: display)
    }

    #expect(error?.code == testCase.code)
    #expect(error?.operation == .read)
    #expect(error?.backend == .appleSiliconDDC)
    #expect(error?.details["reason"] == testCase.reason)
    #expect(error?.details["featureCode"] == "0x10")
    #expect(error?.details["candidateCount"] == testCase.candidateCount)
    #expect(await transport.snapshot().calls.isEmpty)
  }
}

@Test("A DDC read session rejects displays outside its prepared topology")
func ddcReadSessionRejectsUnpreparedDisplay() async throws {
  let stableID = "uuid:same-display-new-runtime-snapshot"
  let preparedDisplay = makeReadSessionDisplay(
    runtimeID: 42,
    stableID: stableID,
    serialNumber: 51_580
  )
  let outsideDisplay = makeReadSessionDisplay(
    runtimeID: 99,
    stableID: stableID,
    serialNumber: 51_580
  )
  let recorder = ReadSessionMatcherRecorder()
  let matcher = RootReadSessionMatcher(
    outcome: .association(.matched(makeReadSessionService())),
    recorder: recorder
  )
  let transport = ScriptedDDCTransport(actions: [])
  let session = try await DDCVCPReadSession.prepare(
    backend: .appleSiliconDDC,
    displays: [preparedDisplay],
    serviceMatcher: matcher,
    executor: DDCVCPExecutor(
      transport: transport,
      policy: DDCExecutionPolicy(maximumAttempts: 1, attemptTimeout: nil)
    )
  )

  let error = await capturedDisplayDJError {
    try await session.getFeature(0x10, from: outsideDisplay)
  }
  let matcherSnapshot = await recorder.snapshot()

  #expect(error?.code == .conflict)
  #expect(error?.operation == .read)
  #expect(error?.details["reason"] == "display-outside-prepared-topology")
  #expect(matcherSnapshot.associatedDisplays.isEmpty)
  #expect(await transport.snapshot().calls.isEmpty)
}

@Test("DDC service inventory failures map to structured read errors without executing")
func ddcReadSessionMapsServiceMatchingFailure() async throws {
  let display = makeReadSessionDisplay()
  let recorder = ReadSessionMatcherRecorder()
  let matcher = RootReadSessionMatcher(
    outcome: .failure(.registryTopologyChanged),
    recorder: recorder
  )
  let transport = ScriptedDDCTransport(actions: [])
  let session = try await DDCVCPReadSession.prepare(
    backend: .appleSiliconDDC,
    displays: [display],
    serviceMatcher: matcher,
    executor: DDCVCPExecutor(
      transport: transport,
      policy: DDCExecutionPolicy(maximumAttempts: 1, attemptTimeout: nil)
    )
  )

  let error = await capturedDisplayDJError {
    try await session.getFeature(0x10, from: display)
  }

  #expect(error?.code == .transportFailure)
  #expect(error?.operation == .read)
  #expect(error?.details["reason"] == "registry-topology-changed")
  #expect(error?.details["featureCode"] == "0x10")
  #expect(await transport.snapshot().calls.isEmpty)
}

@Test("Cancellation during DDC service association propagates without executing")
func ddcReadSessionAssociationCancellationPropagates() async throws {
  let display = makeReadSessionDisplay()
  let gate = TestGate()
  let recorder = ReadSessionMatcherRecorder()
  let matcher = RootReadSessionMatcher(
    outcome: .gatedAssociationIgnoringCancellation(
      gate,
      .matched(makeReadSessionService())
    ),
    recorder: recorder
  )
  let transport = ScriptedDDCTransport(actions: [])
  let session = try await DDCVCPReadSession.prepare(
    backend: .appleSiliconDDC,
    displays: [display],
    serviceMatcher: matcher,
    executor: DDCVCPExecutor(
      transport: transport,
      policy: DDCExecutionPolicy(maximumAttempts: 1, attemptTimeout: nil)
    )
  )
  let task = Task {
    try await session.getFeature(0x10, from: display)
  }

  await recorder.waitUntilAssociationCount(1)
  task.cancel()
  await gate.open()

  do {
    _ = try await task.value
    Issue.record("Expected association cancellation.")
  } catch is CancellationError {
    // Expected.
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
  #expect(await transport.snapshot().calls.isEmpty)
}

@Test("Cancellation takes priority when DDC service matching also fails")
func ddcReadSessionCancellationPrecedesMatchingFailure() async throws {
  let display = makeReadSessionDisplay()
  let gate = TestGate()
  let recorder = ReadSessionMatcherRecorder()
  let matcher = RootReadSessionMatcher(
    outcome: .gatedFailureIgnoringCancellation(
      gate,
      .registryTopologyChanged
    ),
    recorder: recorder
  )
  let transport = ScriptedDDCTransport(actions: [])
  let session = try await DDCVCPReadSession.prepare(
    backend: .appleSiliconDDC,
    displays: [display],
    serviceMatcher: matcher,
    executor: DDCVCPExecutor(
      transport: transport,
      policy: DDCExecutionPolicy(maximumAttempts: 1, attemptTimeout: nil)
    )
  )
  let task = Task {
    try await session.getFeature(0x10, from: display)
  }

  await recorder.waitUntilAssociationCount(1)
  task.cancel()
  await gate.open()

  do {
    _ = try await task.value
    Issue.record("Expected cancellation to take priority over matching failure.")
  } catch is CancellationError {
    // Expected.
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
  #expect(await transport.snapshot().calls.isEmpty)
}
