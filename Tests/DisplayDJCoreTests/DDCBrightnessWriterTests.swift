import Testing

@testable import DisplayDJCore

@Test("Brightness writer maps percent from the live maximum and verifies one Set")
func brightnessWriterMapsAndVerifiesOneSet() async throws {
  let display = makeReadSessionDisplay(
    stableID: "uuid:brightness-writer-success"
  )
  let discovery = SequencedBrightnessDiscovery(
    snapshots: [[display], [display], [display]]
  )
  let recorder = ReadSessionMatcherRecorder()
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.success(maximumValue: 255, currentValue: 17)),
      .complete(.response([])),
      .complete(.success(maximumValue: 255, currentValue: 128)),
    ]
  )
  let writer = makeBrightnessWriter(
    discovery: discovery,
    matcher: matchedWriterService(recorder: recorder),
    transport: transport
  )

  let result = try await writer.write(
    DisplayControlValue(percent: 50),
    to: .stableID(display.stableID!)
  )
  let snapshot = await transport.snapshot()

  #expect(result.display == display)
  #expect(result.backend == .appleSiliconDDC)
  #expect(result.control == .brightness)
  #expect(result.requestedValue.percent == 50)
  #expect(abs(result.appliedValue.percent - (128.0 / 255.0 * 100.0)) < 0.000_001)
  #expect(result.wasVerified)
  #expect(snapshot.calls.map(\.opcode) == [0x01, 0x03, 0x01])
  #expect(snapshot.calls.compactMap(\.setRawValue) == [128])
  #expect(snapshot.maximumActiveByKey.values.allSatisfy { $0 == 1 })
  #expect(await recorder.snapshot().associatedDisplays == [display])
  #expect(await discovery.snapshotCallCount() == 3)
}

@Test("A write a repeated frame still cannot apply restores the exact baseline")
func brightnessWriterRestoresAfterVerificationMismatch() async throws {
  let display = makeReadSessionDisplay(
    stableID: "uuid:brightness-writer-mismatch"
  )
  let discovery = SequencedBrightnessDiscovery(snapshots: [[display]])
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.success(maximumValue: 100, currentValue: 20)),
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 49)),
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 49)),
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 20)),
    ]
  )
  let writer = makeBrightnessWriter(
    discovery: discovery,
    matcher: matchedWriterService(),
    transport: transport
  )

  let error = await capturedDisplayDJError {
    try await writer.write(
      DisplayControlValue(percent: 50),
      to: .stableID(display.stableID!)
    )
  }
  let snapshot = await transport.snapshot()

  #expect(error?.code == .verificationFailed)
  #expect(error?.operation == .write)
  #expect(error?.details["reason"] == "ddc-write-verification-mismatch")
  #expect(error?.details["baselineValue"] == "20")
  #expect(error?.details["requestedValue"] == "50")
  #expect(error?.details["restorationState"] == "verified")
  #expect(error?.details["restoredValue"] == "20")
  #expect(
    snapshot.calls.map(\.opcode) == [0x01, 0x03, 0x01, 0x03, 0x01, 0x03, 0x01]
  )
  #expect(snapshot.calls.compactMap(\.setRawValue) == [50, 50, 20])
  #expect(
    snapshot.calls.filter { $0.opcode == 0x03 }.map(\.request.writeFrameCount)
      == [1, 2, 1]
  )
  #expect(await discovery.snapshotCallCount() == 2)
}

@Test("A display that ignores an isolated Set frame is written on the repeat")
func brightnessWriterEscalatesToRepeatedSetFrames() async throws {
  let display = makeReadSessionDisplay(
    stableID: "uuid:brightness-writer-repeated-frame"
  )
  let discovery = SequencedBrightnessDiscovery(
    snapshots: [[display], [display], [display]]
  )
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.success(maximumValue: 100, currentValue: 20)),
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 20)),
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 50)),
    ]
  )
  let writer = makeBrightnessWriter(
    discovery: discovery,
    matcher: matchedWriterService(),
    transport: transport
  )

  let result = try await writer.write(
    DisplayControlValue(percent: 50),
    to: .stableID(display.stableID!)
  )
  let snapshot = await transport.snapshot()

  #expect(result.appliedValue.percent == 50)
  #expect(result.wasVerified)
  #expect(snapshot.calls.map(\.opcode) == [0x01, 0x03, 0x01, 0x03, 0x01])
  #expect(snapshot.calls.compactMap(\.setRawValue) == [50, 50])
  #expect(
    snapshot.calls.filter { $0.opcode == 0x03 }.map(\.request.writeFrameCount)
      == [1, 2]
  )
}

@Test("An uncertain target Set is not retried and still triggers restoration")
func brightnessWriterRestoresAfterTargetSetFailure() async throws {
  let display = makeReadSessionDisplay(
    stableID: "uuid:brightness-writer-set-failure"
  )
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.success(maximumValue: 100, currentValue: 20)),
      .complete(.failure(.busy)),
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 20)),
    ]
  )
  let writer = makeBrightnessWriter(
    discovery: SequencedBrightnessDiscovery(snapshots: [[display]]),
    matcher: matchedWriterService(),
    transport: transport
  )

  let error = await capturedDisplayDJError {
    try await writer.write(
      DisplayControlValue(percent: 75),
      to: .stableID(display.stableID!)
    )
  }
  let snapshot = await transport.snapshot()

  #expect(error?.code == .busy)
  #expect(error?.operation == .write)
  #expect(error?.details["phase"] == "write")
  #expect(error?.details["restorationState"] == "verified")
  #expect(snapshot.calls.map(\.opcode) == [0x01, 0x03, 0x03, 0x01])
  #expect(snapshot.calls.compactMap(\.setRawValue) == [75, 20])
  #expect(snapshot.calls.count { $0.setRawValue == 75 } == 1)
}

@Test("Restoration failure takes priority and preserves the primary write evidence")
func brightnessWriterPrioritizesRestorationFailure() async throws {
  let display = makeReadSessionDisplay(
    stableID: "uuid:brightness-writer-restore-failure"
  )
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.success(maximumValue: 100, currentValue: 20)),
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 49)),
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 49)),
      .complete(.failure(.busy)),
    ]
  )
  let writer = makeBrightnessWriter(
    discovery: SequencedBrightnessDiscovery(snapshots: [[display]]),
    matcher: matchedWriterService(),
    transport: transport
  )

  let error = await capturedDisplayDJError {
    try await writer.write(
      DisplayControlValue(percent: 50),
      to: .stableID(display.stableID!)
    )
  }
  let snapshot = await transport.snapshot()

  #expect(error?.code == .busy)
  #expect(error?.operation == .restore)
  #expect(error?.details["phase"] == "restore-write")
  #expect(error?.details["restorationState"] == "unknown")
  #expect(error?.details["primaryCode"] == "verification-failed")
  #expect(error?.details["primaryOperation"] == "write")
  #expect(error?.details["primaryReason"] == "ddc-write-verification-mismatch")
  #expect(snapshot.calls.map(\.opcode) == [0x01, 0x03, 0x01, 0x03, 0x01, 0x03])
  #expect(snapshot.calls.compactMap(\.setRawValue) == [50, 50, 20])
}

@Test("Changed DDC maximum metadata fails verification and restores the baseline")
func brightnessWriterRejectsChangedMaximum() async throws {
  let display = makeReadSessionDisplay(
    stableID: "uuid:brightness-writer-maximum-change"
  )
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.success(maximumValue: 100, currentValue: 20)),
      .complete(.response([])),
      .complete(.success(maximumValue: 200, currentValue: 50)),
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 20)),
    ]
  )
  let writer = makeBrightnessWriter(
    discovery: SequencedBrightnessDiscovery(snapshots: [[display]]),
    matcher: matchedWriterService(),
    transport: transport
  )

  let error = await capturedDisplayDJError {
    try await writer.write(
      DisplayControlValue(percent: 50),
      to: .stableID(display.stableID!)
    )
  }

  #expect(error?.code == .verificationFailed)
  #expect(error?.operation == .write)
  #expect(error?.details["reason"] == "ddc-write-metadata-mismatch")
  #expect(error?.details["baselineMaximumValue"] == "100")
  #expect(error?.details["observedMaximumValue"] == "200")
  #expect(error?.details["restorationState"] == "verified")
  #expect(await transport.snapshot().calls.compactMap(\.setRawValue) == [50, 20])
}

@Test("A post-write topology change fails only after restoring the baseline")
func brightnessWriterRestoresAfterPostWriteTopologyChange() async throws {
  let stableID = "uuid:brightness-writer-topology-change"
  let display = makeReadSessionDisplay(runtimeID: 42, stableID: stableID)
  let changed = makeReadSessionDisplay(runtimeID: 99, stableID: stableID)
  let discovery = SequencedBrightnessDiscovery(
    snapshots: [[display], [display], [changed]]
  )
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.success(maximumValue: 100, currentValue: 20)),
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 30)),
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 20)),
    ]
  )
  let writer = makeBrightnessWriter(
    discovery: discovery,
    matcher: matchedWriterService(),
    transport: transport
  )

  let error = await capturedDisplayDJError {
    try await writer.write(
      DisplayControlValue(percent: 30),
      to: .stableID(stableID)
    )
  }
  let snapshot = await transport.snapshot()

  #expect(error?.code == .conflict)
  #expect(error?.operation == .write)
  #expect(error?.details["phase"] == "post-write-verification")
  #expect(error?.details["reason"] == "display-topology-changed")
  #expect(error?.details["restorationState"] == "verified")
  #expect(snapshot.calls.map(\.opcode) == [0x01, 0x03, 0x01, 0x03, 0x01])
  #expect(snapshot.calls.compactMap(\.setRawValue) == [30, 20])
  #expect(await discovery.snapshotCallCount() == 3)
}

@Test("Invalid brightness baselines fail before any Set or restoration")
func brightnessWriterRejectsInvalidBaselineBeforeSet() async throws {
  let display = makeReadSessionDisplay(
    stableID: "uuid:brightness-writer-invalid-baseline"
  )
  let transport = ScriptedDDCTransport(
    actions: [.complete(.success(maximumValue: 0, currentValue: 0))]
  )
  let writer = makeBrightnessWriter(
    discovery: SequencedBrightnessDiscovery(snapshots: [[display]]),
    matcher: matchedWriterService(),
    transport: transport
  )

  let error = await capturedDisplayDJError {
    try await writer.write(
      DisplayControlValue(percent: 50),
      to: .stableID(display.stableID!)
    )
  }
  let snapshot = await transport.snapshot()

  #expect(error?.code == .transportFailure)
  #expect(error?.operation == .write)
  #expect(error?.details["reason"] == "invalid-brightness-vcp-value")
  #expect(snapshot.calls.map(\.opcode) == [0x01])
  #expect(snapshot.calls.compactMap(\.setRawValue).isEmpty)
}

@Test("A raw no-op uses the live baseline without sending Set")
func brightnessWriterSkipsRawNoOp() async throws {
  let display = makeReadSessionDisplay(
    stableID: "uuid:brightness-writer-no-op"
  )
  let discovery = SequencedBrightnessDiscovery(
    snapshots: [[display], [display], [display]]
  )
  let transport = ScriptedDDCTransport(
    actions: [.complete(.success(maximumValue: 100, currentValue: 42))]
  )
  let writer = makeBrightnessWriter(
    discovery: discovery,
    matcher: matchedWriterService(),
    transport: transport
  )

  let result = try await writer.write(
    DisplayControlValue(percent: 42),
    to: .stableID(display.stableID!)
  )
  let snapshot = await transport.snapshot()

  #expect(result.appliedValue.percent == 42)
  #expect(result.wasVerified)
  #expect(snapshot.calls.map(\.opcode) == [0x01])
  #expect(snapshot.calls.compactMap(\.setRawValue).isEmpty)
  #expect(await discovery.snapshotCallCount() == 3)
}

@Test("Caller cancellation after Set waits for verified restoration")
func brightnessWriterRestoresBeforePropagatingCancellation() async throws {
  let display = makeReadSessionDisplay(
    stableID: "uuid:brightness-writer-cancelled"
  )
  let verificationGate = TestGate()
  let transport = ScriptedDDCTransport(
    actions: [
      .complete(.success(maximumValue: 100, currentValue: 20)),
      .complete(.response([])),
      .gated(
        verificationGate,
        .success(maximumValue: 100, currentValue: 75)
      ),
      .complete(.response([])),
      .complete(.success(maximumValue: 100, currentValue: 20)),
    ]
  )
  let writer = makeBrightnessWriter(
    discovery: SequencedBrightnessDiscovery(snapshots: [[display]]),
    matcher: matchedWriterService(),
    transport: transport
  )
  let task = Task {
    try await writer.write(
      DisplayControlValue(percent: 75),
      to: .stableID(display.stableID!)
    )
  }

  await transport.waitUntilCallCount(3)
  task.cancel()
  await verificationGate.open()

  do {
    _ = try await task.value
    Issue.record("Expected caller cancellation.")
  } catch is CancellationError {
    // Expected after restoration is verified.
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }

  let snapshot = await transport.snapshot()
  #expect(snapshot.calls.map(\.opcode) == [0x01, 0x03, 0x01, 0x03, 0x01])
  #expect(snapshot.calls.compactMap(\.setRawValue) == [75, 20])
}

@Test("The production writer validates values and selectors before transport initialization")
func productionBrightnessWriterValidatesInputsFirst() async {
  let valueError = await capturedDisplayDJError {
    try await AppleSiliconDDCBrightnessWriter().write(
      percent: 101,
      toStableID: "uuid:writer-invalid-value"
    )
  }
  let selectorError = await capturedDisplayDJError {
    try await AppleSiliconDDCBrightnessWriter().write(
      percent: 50,
      toStableID: "\n"
    )
  }

  #expect(valueError?.code == .invalidValue)
  #expect(valueError?.operation == .write)
  #expect(valueError?.details["phase"] == "value-validation")
  #expect(selectorError?.code == .invalidSelector)
  #expect(selectorError?.operation == .write)
  #expect(selectorError?.details["phase"] == "selection")
}

#if arch(x86_64)
  @Test("The production Apple Silicon writer fails safely on x86_64")
  func productionBrightnessWriterRejectsX86() async {
    let error = await capturedDisplayDJError {
      try await AppleSiliconDDCBrightnessWriter().write(
        percent: 50,
        toStableID: "uuid:brightness-writer-x86"
      )
    }

    #expect(error?.code == .backendUnavailable)
    #expect(error?.operation == .write)
    #expect(error?.backend == .appleSiliconDDC)
    #expect(error?.details["phase"] == "transport-initialization")
    #expect(error?.details["reason"] == "transport-unavailable")
  }
#endif

private func matchedWriterService(
  recorder: ReadSessionMatcherRecorder = ReadSessionMatcherRecorder()
) -> RootReadSessionMatcher {
  RootReadSessionMatcher(
    outcome: .association(.matched(makeReadSessionService())),
    recorder: recorder
  )
}
