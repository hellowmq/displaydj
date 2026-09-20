import Testing

@testable import DisplayDJCore

@Test("Selector resolver errors keep their code but gain read context")
func brightnessSelectorErrorsGainReadContext() async throws {
  let display = makeReadSessionDisplay(stableID: "uuid:available")
  let discovery = SequencedBrightnessDiscovery(snapshots: [[display]])
  let recorder = ReadSessionMatcherRecorder()
  let transport = ScriptedDDCTransport(actions: [])
  let reader = makeBrightnessReader(
    discovery: discovery,
    matcher: RootReadSessionMatcher(
      outcome: .association(.matched(makeReadSessionService())),
      recorder: recorder
    ),
    transport: transport
  )

  let error = await capturedDisplayDJError {
    try await reader.read(from: .stableID("uuid:missing"))
  }

  #expect(error?.code == .displayNotFound)
  #expect(error?.operation == .read)
  #expect(error?.backend == .appleSiliconDDC)
  #expect(error?.displayID == "uuid:missing")
  #expect(error?.details["phase"] == "selection")
  #expect(await recorder.snapshot().preparedTopologies.isEmpty)
  #expect(await transport.snapshot().calls.isEmpty)
}

@Test("Stable selector collisions retain ambiguity evidence in read context")
func brightnessSelectorCollisionGainsReadContext() async throws {
  let stableID = "uuid:duplicate"
  let first = makeReadSessionDisplay(runtimeID: 1, stableID: stableID, serialNumber: 1)
  let second = makeReadSessionDisplay(runtimeID: 2, stableID: stableID, serialNumber: 2)
  let discovery = SequencedBrightnessDiscovery(snapshots: [[first, second]])
  let recorder = ReadSessionMatcherRecorder()
  let transport = ScriptedDDCTransport(actions: [])
  let reader = makeBrightnessReader(
    discovery: discovery,
    matcher: RootReadSessionMatcher(
      outcome: .association(.matched(makeReadSessionService())),
      recorder: recorder
    ),
    transport: transport
  )

  let error = await capturedDisplayDJError {
    try await reader.read(from: .stableID(stableID))
  }

  #expect(error?.code == .ambiguousDisplay)
  #expect(error?.operation == .read)
  #expect(error?.backend == .appleSiliconDDC)
  #expect(error?.details["phase"] == "selection")
  #expect(error?.details["runtimeIDs"] == "1,2")
  #expect(await recorder.snapshot().preparedTopologies.isEmpty)
  #expect(await transport.snapshot().calls.isEmpty)
}

@Test("Typed discovery failures preserve evidence and gain read phase context")
func brightnessDiscoveryErrorGainsReadContext() async throws {
  let upstream = DisplayDJError(
    code: .transportFailure,
    message: "CoreGraphics could not provide a stable snapshot.",
    operation: .discover,
    details: ["reason": "topology-changed"]
  )
  let recorder = ReadSessionMatcherRecorder()
  let transport = ScriptedDDCTransport(actions: [])
  let reader = makeBrightnessReader(
    discovery: DisplayDJFailingBrightnessDiscovery(error: upstream),
    matcher: RootReadSessionMatcher(
      outcome: .association(.matched(makeReadSessionService())),
      recorder: recorder
    ),
    transport: transport
  )

  let error = await capturedDisplayDJError {
    try await reader.read(from: .all)
  }

  #expect(error?.code == .transportFailure)
  #expect(error?.operation == .read)
  #expect(error?.backend == .appleSiliconDDC)
  #expect(error?.message == upstream.message)
  #expect(error?.details["reason"] == "topology-changed")
  #expect(error?.details["phase"] == "initial-discovery")
  #expect(await recorder.snapshot().preparedTopologies.isEmpty)
  #expect(await transport.snapshot().calls.isEmpty)
}

@Test("Unexpected discovery failures become stable internal read errors")
func unexpectedBrightnessDiscoveryErrorIsStructured() async throws {
  let recorder = ReadSessionMatcherRecorder()
  let transport = ScriptedDDCTransport(actions: [])
  let reader = makeBrightnessReader(
    discovery: UnexpectedFailingBrightnessDiscovery(),
    matcher: RootReadSessionMatcher(
      outcome: .association(.matched(makeReadSessionService())),
      recorder: recorder
    ),
    transport: transport
  )

  let error = await capturedDisplayDJError {
    try await reader.read(from: .all)
  }

  #expect(error?.code == .internalFailure)
  #expect(error?.operation == .read)
  #expect(error?.backend == .appleSiliconDDC)
  #expect(error?.details["reason"] == "unexpected-display-discovery-error")
  #expect(error?.details["phase"] == "initial-discovery")
  #expect(error?.details["underlyingError"]?.contains("failed") == true)
  #expect(await recorder.snapshot().preparedTopologies.isEmpty)
  #expect(await transport.snapshot().calls.isEmpty)
}

@Test("Cancellation takes priority over a simultaneous discovery error")
func brightnessDiscoveryCancellationTakesPriority() async throws {
  let startedGate = TestGate()
  let releaseGate = TestGate()
  let discovery = GatedBrightnessDiscovery(
    startedGate: startedGate,
    releaseGate: releaseGate,
    outcome: .failure(
      DisplayDJError(
        code: .transportFailure,
        message: "A test discovery error.",
        operation: .discover
      )
    )
  )
  let recorder = ReadSessionMatcherRecorder()
  let transport = ScriptedDDCTransport(actions: [])
  let reader = makeBrightnessReader(
    discovery: discovery,
    matcher: RootReadSessionMatcher(
      outcome: .association(.matched(makeReadSessionService())),
      recorder: recorder
    ),
    transport: transport
  )
  let task = Task {
    try await reader.read(from: .all)
  }

  await startedGate.wait()
  task.cancel()
  await releaseGate.open()

  do {
    _ = try await task.value
    Issue.record("Expected cancellation to take priority over discovery failure.")
  } catch is CancellationError {
    // Expected.
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
  #expect(await recorder.snapshot().preparedTopologies.isEmpty)
  #expect(await transport.snapshot().calls.isEmpty)
}

@Test("Changes to a non-target display invalidate the complete topology scope")
func brightnessReadRejectsNonTargetTopologyChange() async throws {
  let target = makeReadSessionDisplay(runtimeID: 1, serialNumber: 1)
  let other = makeReadSessionDisplay(runtimeID: 2, serialNumber: 2)
  let changedOther = makeReadSessionDisplay(runtimeID: 3, serialNumber: 2)
  let discovery = SequencedBrightnessDiscovery(
    snapshots: [[target, other], [target, changedOther]]
  )
  let transport = ScriptedDDCTransport(actions: [])
  let reader = makeBrightnessReader(
    discovery: discovery,
    matcher: RootReadSessionMatcher(
      outcome: .association(.matched(makeReadSessionService())),
      recorder: ReadSessionMatcherRecorder()
    ),
    transport: transport
  )

  let error = await capturedDisplayDJError {
    try await reader.read(from: .runtimeID(target.runtimeID))
  }

  #expect(error?.code == .conflict)
  #expect(error?.details["phase"] == "pre-read-verification")
  #expect(error?.details["before"]?.contains("runtime=2") == true)
  #expect(error?.details["after"]?.contains("runtime=3") == true)
  #expect(await transport.snapshot().calls.isEmpty)
}

@Test("DDC brightness mapping accepts exact zero and full-scale boundaries")
func brightnessReadAcceptsBoundaries() async throws {
  for currentValue in [UInt16(0), UInt16(100)] {
    let display = makeReadSessionDisplay()
    let discovery = SequencedBrightnessDiscovery(snapshots: [[display]])
    let transport = ScriptedDDCTransport(
      actions: [.complete(.success(maximumValue: 100, currentValue: currentValue))]
    )
    let reader = makeBrightnessReader(
      discovery: discovery,
      matcher: RootReadSessionMatcher(
        outcome: .association(.matched(makeReadSessionService())),
        recorder: ReadSessionMatcherRecorder()
      ),
      transport: transport
    )

    let result = try await reader.read(from: .runtimeID(display.runtimeID))

    #expect(result.value.percent == Double(currentValue))
    #expect(await transport.snapshot().calls.count == 1)
    #expect(await discovery.snapshotCallCount() == 3)
  }
}
