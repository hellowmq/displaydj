import Testing

@testable import DisplayDJCore

@Test("A single-display brightness read uses one full topology scope and returns percent")
func brightnessReadReturnsPercentage() async throws {
  let target = makeReadSessionDisplay(
    runtimeID: 42,
    stableID: "uuid:brightness-target",
    serialNumber: 51_580
  )
  let other = makeReadSessionDisplay(
    runtimeID: 7,
    stableID: "uuid:brightness-other",
    serialNumber: 51_581
  )
  let expectedTopology = [other, target]
  let discovery = SequencedBrightnessDiscovery(
    snapshots: [
      [target, other],
      [other, target],
      [target, other],
    ]
  )
  let recorder = ReadSessionMatcherRecorder()
  let service = makeReadSessionService(registryEntryID: 0xB100)
  let matcher = RootReadSessionMatcher(
    outcome: .association(.matched(service)),
    recorder: recorder
  )
  let transport = ScriptedDDCTransport(
    actions: [.complete(.success(maximumValue: 400, currentValue: 123))]
  )
  let reader = makeBrightnessReader(
    discovery: discovery,
    matcher: matcher,
    transport: transport
  )

  let result = try await reader.read(
    from: .stableID("UUID:BRIGHTNESS-TARGET")
  )
  let matcherSnapshot = await recorder.snapshot()
  let transportSnapshot = await transport.snapshot()
  let call = try #require(transportSnapshot.calls.first)

  #expect(result.display == target)
  #expect(result.backend == .appleSiliconDDC)
  #expect(result.control == .brightness)
  #expect(abs(result.value.percent - 30.75) < 0.000_001)
  #expect(matcherSnapshot.preparedTopologies == [expectedTopology])
  #expect(matcherSnapshot.associatedDisplays == [target])
  #expect(call.request.logicalFrame == [0x51, 0x82, 0x01, 0x10, 0xAC])
  #expect(call.request.replyCapacity == 11)
  #expect(call.target.display == target)
  #expect(call.target.service == service)
  #expect(transportSnapshot.calls.count == 1)
  #expect(await discovery.snapshotCallCount() == 3)
}

@Test("A topology change during DDC session preparation fails before transport")
func brightnessReadRejectsPreReadTopologyChange() async throws {
  let stableID = "uuid:brightness-reconfigured"
  let initial = makeReadSessionDisplay(runtimeID: 42, stableID: stableID)
  let reconfigured = makeReadSessionDisplay(runtimeID: 99, stableID: stableID)
  let discovery = SequencedBrightnessDiscovery(
    snapshots: [[initial], [reconfigured]]
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

  let error = await capturedDisplayDJError {
    try await reader.read(from: .stableID(stableID))
  }
  let matcherSnapshot = await recorder.snapshot()

  #expect(error?.code == .conflict)
  #expect(error?.operation == .read)
  #expect(error?.backend == .appleSiliconDDC)
  #expect(error?.details["reason"] == "display-topology-changed")
  #expect(error?.details["phase"] == "pre-read-verification")
  #expect(error?.details["before"]?.contains("runtime=42") == true)
  #expect(error?.details["after"]?.contains("runtime=99") == true)
  #expect(matcherSnapshot.preparedTopologies == [[initial]])
  #expect(matcherSnapshot.associatedDisplays.isEmpty)
  #expect(await transport.snapshot().calls.isEmpty)
  #expect(await discovery.snapshotCallCount() == 2)
}

@Test("A topology change after Get VCP rejects the observed brightness")
func brightnessReadRejectsPostReadTopologyChange() async throws {
  let stableID = "uuid:brightness-post-read-change"
  let initial = makeReadSessionDisplay(runtimeID: 42, stableID: stableID)
  let reconfigured = makeReadSessionDisplay(runtimeID: 99, stableID: stableID)
  let discovery = SequencedBrightnessDiscovery(
    snapshots: [[initial], [initial], [reconfigured]]
  )
  let recorder = ReadSessionMatcherRecorder()
  let transport = ScriptedDDCTransport(
    actions: [.complete(.success(maximumValue: 100, currentValue: 60))]
  )
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

  #expect(error?.code == .conflict)
  #expect(error?.operation == .read)
  #expect(error?.details["reason"] == "display-topology-changed")
  #expect(error?.details["phase"] == "post-read-verification")
  #expect(await recorder.snapshot().associatedDisplays == [initial])
  #expect(await transport.snapshot().calls.count == 1)
  #expect(await discovery.snapshotCallCount() == 3)
}

@Test("Invalid raw brightness ranges and value types never become percentages")
func invalidRawBrightnessValuesFail() async throws {
  for testCase in invalidBrightnessCases() {
    let display = makeReadSessionDisplay()
    let discovery = SequencedBrightnessDiscovery(snapshots: [[display]])
    let transport = ScriptedDDCTransport(actions: [testCase.action])
    let reader = makeBrightnessReader(
      discovery: discovery,
      matcher: RootReadSessionMatcher(
        outcome: .association(.matched(makeReadSessionService())),
        recorder: ReadSessionMatcherRecorder()
      ),
      transport: transport
    )

    let error = await capturedDisplayDJError {
      try await reader.read(from: .runtimeID(display.runtimeID))
    }

    #expect(error?.code == .transportFailure)
    #expect(error?.operation == .read)
    #expect(error?.details["reason"] == "invalid-brightness-vcp-value")
    #expect(error?.details["featureCode"] == "0x10")
    #expect(error?.details["maximumValue"] == testCase.maximumValue)
    #expect(error?.details["currentValue"] == testCase.currentValue)
    #expect(error?.details["valueType"] == testCase.valueType)
    #expect(await transport.snapshot().calls.count == 1)
    #expect(await discovery.snapshotCallCount() == 3)
  }
}

@Test("A multi-display scope is rejected before DDC session preparation")
func brightnessReadRequiresOneDisplay() async throws {
  let first = makeReadSessionDisplay(runtimeID: 1, serialNumber: 1)
  let second = makeReadSessionDisplay(runtimeID: 2, serialNumber: 2)
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
    try await reader.read(from: .external)
  }
  let matcherSnapshot = await recorder.snapshot()

  #expect(error?.code == .ambiguousDisplay)
  #expect(error?.operation == .read)
  #expect(error?.displayID == "external")
  #expect(error?.details["matchedDisplayCount"] == "2")
  #expect(error?.details["runtimeIDs"] == "1,2")
  #expect(matcherSnapshot.preparedTopologies.isEmpty)
  #expect(await transport.snapshot().calls.isEmpty)
  #expect(await discovery.snapshotCallCount() == 1)
}

@Test("An empty all-display scope returns display-not-found before preparation")
func brightnessReadRejectsEmptyTopology() async throws {
  let discovery = SequencedBrightnessDiscovery(snapshots: [[]])
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
    try await reader.read(from: .all)
  }

  #expect(error?.code == .displayNotFound)
  #expect(error?.operation == .read)
  #expect(error?.displayID == "all")
  #expect(error?.details["matchedDisplayCount"] == "0")
  #expect(await recorder.snapshot().preparedTopologies.isEmpty)
  #expect(await transport.snapshot().calls.isEmpty)
  #expect(await discovery.snapshotCallCount() == 1)
}

@Test("The production reader rejects an invalid stable ID before transport initialization")
func productionBrightnessReaderValidatesStableIDFirst() async {
  let error = await capturedDisplayDJError {
    try await AppleSiliconDDCBrightnessReader().read(fromStableID: "\n")
  }

  #expect(error?.code == .invalidSelector)
  #expect(error?.operation == .read)
  #expect(error?.backend == .appleSiliconDDC)
  #expect(error?.details["phase"] == "selection")
}

#if arch(x86_64)
  @Test("The production Apple Silicon reader fails safely on x86_64")
  func productionBrightnessReaderRejectsX86() async {
    let error = await capturedDisplayDJError {
      try await AppleSiliconDDCBrightnessReader().read(
        fromStableID: "uuid:brightness-x86"
      )
    }

    #expect(error?.code == .backendUnavailable)
    #expect(error?.operation == .read)
    #expect(error?.backend == .appleSiliconDDC)
    #expect(error?.details["phase"] == "transport-initialization")
    #expect(error?.details["reason"] == "transport-unavailable")
  }
#endif
