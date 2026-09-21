import Testing
@testable import DisplayDJCore

@Test("Contrast and volume use their own VCP code and live maximum", arguments: [DDCContinuousControl.contrast, .volume])
func continuousControlUsesCorrectFeature(control: DDCContinuousControl) async throws {
    let display = makeReadSessionDisplay(stableID: "uuid:control-test")
    let transport = ScriptedDDCTransport(actions: [
        .complete(.success(maximumValue: 200, currentValue: 80)),
        .complete(.response([])),
        .complete(.success(maximumValue: 200, currentValue: 100)),
    ])
    let writer = DDCBrightnessWriter(discovery: SequencedBrightnessDiscovery(snapshots: [[display]]),
        backend: .appleSiliconDDC,
        serviceMatcher: RootReadSessionMatcher(outcome: .association(.matched(makeReadSessionService())), recorder: ReadSessionMatcherRecorder()),
        executor: DDCVCPExecutor(transport: transport), featureCode: control.featureCode, control: control.control)
    let result = try await writer.write(DisplayControlValue(percent: 0), to: .stableID(display.stableID!), relativeDelta: 0.1)
    #expect(result.wasVerified)
    #expect(result.control == control.control)
    #expect(result.appliedValue.percent == 50)
    let snapshot = await transport.snapshot()
    #expect(snapshot.calls.compactMap(\.featureCode) == [control.featureCode, control.featureCode, control.featureCode])
    #expect(snapshot.calls.compactMap(\.setRawValue) == [100])
}

@Test("A failed volume write restores the exact raw audio baseline")
func failedVolumeRestoresBaseline() async throws {
    let display = makeReadSessionDisplay(stableID: "uuid:control-test")
    let transport = ScriptedDDCTransport(actions: [
        .complete(.success(maximumValue: 200, currentValue: 80)),
        .complete(.failure(.busy)),
        .complete(.response([])),
        .complete(.success(maximumValue: 200, currentValue: 80)),
    ])
    let writer = DDCBrightnessWriter(discovery: SequencedBrightnessDiscovery(snapshots: [[display]]), backend: .appleSiliconDDC,
        serviceMatcher: RootReadSessionMatcher(outcome: .association(.matched(makeReadSessionService())), recorder: ReadSessionMatcherRecorder()),
        executor: DDCVCPExecutor(transport: transport), featureCode: 0x62, control: .volume)
    let error = await capturedDisplayDJError { try await writer.write(DisplayControlValue(percent: 50), to: .stableID(display.stableID!)) }
    #expect(error != nil)
    #expect(error?.details["restorationState"] == "verified")
    let snapshot = await transport.snapshot()
    #expect(snapshot.calls.compactMap(\.setRawValue) == [100, 80])
}
