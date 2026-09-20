import Testing

@testable import DisplayDJCore

@Test("No registered probes report every capability as unavailable")
func capabilitiesWithoutProbes() async throws {
  let display = makeCapabilitiesDisplay(runtimeID: 7)
  let reports = try await DisplayCapabilityAggregator(
    discovery: CapabilitiesFakeDiscovery(displays: [display]),
    probes: []
  ).run()
  let report = try #require(reports.first)

  #expect(reports.count == 1)
  #expect(report.display == display)
  #expect(report.capabilities.map(\.capability) == DisplayCapability.allCases)
  #expect(report.capabilities.allSatisfy { $0.state == .unavailable })
  #expect(report.capabilities.allSatisfy { $0.sources.isEmpty })
}

@Test("Capability aggregation preserves supported, unsupported, unknown, and unavailable")
func capabilityStateAggregation() async throws {
  let display = makeCapabilitiesDisplay(runtimeID: 1)
  let probes = makeCapabilityStateProbes()

  let reports = try await DisplayCapabilityAggregator(
    discovery: CapabilitiesFakeDiscovery(displays: [display]),
    probes: probes
  ).run()
  let assessments = try #require(reports.first).capabilities

  let brightness = try #require(assessments.first { $0.capability == .brightness })
  let contrast = try #require(assessments.first { $0.capability == .contrast })
  let volume = try #require(assessments.first { $0.capability == .volume })
  let mute = try #require(assessments.first { $0.capability == .mute })
  let gamma = try #require(assessments.first { $0.capability == .gamma })
  let shade = try #require(assessments.first { $0.capability == .shade })

  #expect(brightness.state == .supported)
  #expect(brightness.sources.map(\.backend) == [.intelDDC, .nativeBrightness])
  #expect(contrast.state == .unsupported)
  #expect(volume.state == .unknown)
  #expect(volume.sources.first?.errorCode == .timeout)
  #expect(mute.state == .unknown)
  #expect(gamma.state == .unknown)
  #expect(gamma.sources.first?.reason == "Gamma ownership could not be determined.")
  #expect(shade.state == .unavailable)
  #expect(shade.sources.first?.errorCode == .backendUnavailable)
}

@Test("Capability probes execute serially in deterministic display order")
func capabilityProbesAreSerial() async throws {
  let recorder = CapabilityProbeRecorder()
  let probe = RecordingCapabilityProbe(recorder: recorder)

  let reports = try await DisplayCapabilityAggregator(
    discovery: CapabilitiesFakeDiscovery(
      displays: [
        makeCapabilitiesDisplay(runtimeID: 10),
        makeCapabilitiesDisplay(runtimeID: 2),
      ]
    ),
    probes: [probe]
  ).run()

  #expect(reports.map(\.display.runtimeID) == [2, 10])
  #expect(
    await recorder.events == [
      "start-2",
      "end-2",
      "start-10",
      "end-10",
    ]
  )
}

@Test("Capability preparation rejects a changed display topology")
func capabilityPreparationRejectsTopologyChanges() async {
  let discovery = CapabilitiesSequencedDiscovery(
    snapshots: [
      [makeCapabilitiesDisplay(runtimeID: 1)],
      [makeCapabilitiesDisplay(runtimeID: 2)],
    ]
  )

  do {
    _ = try await DisplayCapabilityAggregator(
      discovery: discovery,
      probes: []
    ).run()
    Issue.record("Expected a display-topology conflict.")
  } catch let error as DisplayDJError {
    #expect(error.code == .conflict)
    #expect(error.operation == .probe)
    #expect(error.details["reason"] == "display-topology-changed")
    #expect(error.details["before"] == "uuid:display-1")
    #expect(error.details["after"] == "uuid:display-2")
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
}

@Test("Probe result omissions fail instead of becoming false unsupported results")
func malformedCapabilityProbeFails() async {
  let probe = CapabilitiesFakeProbe(
    kind: .mock,
    probedCapabilities: [.brightness, .contrast],
    result: .success([
      DisplayCapabilityProbeResult(capability: .brightness, state: .supported)
    ])
  )

  do {
    _ = try await DisplayCapabilityAggregator(
      discovery: CapabilitiesFakeDiscovery(
        displays: [makeCapabilitiesDisplay(runtimeID: 3)]
      ),
      probes: [probe]
    ).run()
    Issue.record("Expected an internal capability-probe contract failure.")
  } catch let error as DisplayDJError {
    #expect(error.code == .internalFailure)
    #expect(error.operation == .probe)
    #expect(error.backend == .mock)
    #expect(error.details["expectedCapabilities"] == "brightness,contrast")
    #expect(error.details["actualCapabilities"] == "brightness")
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
}

@Test("No online displays use the stable display-not-found error")
func capabilitiesNoDisplays() async {
  do {
    _ = try await DisplayCapabilityAggregator(
      discovery: CapabilitiesFakeDiscovery(displays: []),
      probes: []
    ).run()
    Issue.record("Expected a display-not-found error.")
  } catch let error as DisplayDJError {
    #expect(error.code == .displayNotFound)
    #expect(error.operation == .probe)
    #expect(error.code.cliExitCode == .displayNotFound)
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
}

private actor CapabilitiesSequencedDiscovery: DisplayDiscovering {
  private var snapshots: [[DisplayDescriptor]]

  init(snapshots: [[DisplayDescriptor]]) {
    self.snapshots = snapshots
  }

  func discoverDisplays() async throws -> [DisplayDescriptor] {
    guard snapshots.count > 1 else {
      return snapshots.first ?? []
    }
    return snapshots.removeFirst()
  }
}

private struct CapabilitiesFakeDiscovery: DisplayDiscovering {
  let displays: [DisplayDescriptor]

  func discoverDisplays() async throws -> [DisplayDescriptor] {
    displays
  }
}

private struct CapabilitiesFakeProbe: DisplayCapabilityProbing {
  let kind: BackendKind
  let probedCapabilities: Set<DisplayCapability>
  let result: Result<[DisplayCapabilityProbeResult], DisplayDJError>

  func probeCapabilities(
    for display: DisplayDescriptor
  ) async throws -> [DisplayCapabilityProbeResult] {
    try result.get()
  }
}

private struct RecordingCapabilityProbe: DisplayCapabilityProbing {
  let kind: BackendKind = .mock
  let probedCapabilities: Set<DisplayCapability> = [.brightness]
  let recorder: CapabilityProbeRecorder

  func probeCapabilities(
    for display: DisplayDescriptor
  ) async throws -> [DisplayCapabilityProbeResult] {
    await recorder.record("start-\(display.runtimeID)")
    try await Task.sleep(for: .milliseconds(5))
    await recorder.record("end-\(display.runtimeID)")
    return [
      DisplayCapabilityProbeResult(capability: .brightness, state: .supported)
    ]
  }
}

private actor CapabilityProbeRecorder {
  private(set) var events: [String] = []

  func record(_ event: String) {
    events.append(event)
  }
}

private func makeCapabilityStateProbes() -> [any DisplayCapabilityProbing] {
  [
    CapabilitiesFakeProbe(
      kind: .nativeBrightness,
      probedCapabilities: [.brightness, .gamma],
      result: .success([
        DisplayCapabilityProbeResult(capability: .brightness, state: .unsupported),
        DisplayCapabilityProbeResult(
          capability: .gamma,
          state: .unknown,
          reason: "Gamma ownership could not be determined."
        ),
      ])
    ),
    CapabilitiesFakeProbe(
      kind: .intelDDC,
      probedCapabilities: [.brightness, .contrast],
      result: .success([
        DisplayCapabilityProbeResult(capability: .brightness, state: .supported),
        DisplayCapabilityProbeResult(capability: .contrast, state: .unsupported),
      ])
    ),
    CapabilitiesFakeProbe(
      kind: .appleSiliconDDC,
      probedCapabilities: [.volume, .mute],
      result: .failure(
        DisplayDJError(
          code: .timeout,
          message: "DDC capability probe timed out.",
          operation: .probe
        )
      )
    ),
    CapabilitiesFakeProbe(
      kind: .shadeHelper,
      probedCapabilities: [.shade],
      result: .failure(
        DisplayDJError(
          code: .backendUnavailable,
          message: "Shade helper is not installed.",
          operation: .probe
        )
      )
    ),
  ]
}

private func makeCapabilitiesDisplay(runtimeID: UInt32) -> DisplayDescriptor {
  DisplayDescriptor(
    runtimeID: runtimeID,
    stableID: "uuid:display-\(runtimeID)",
    name: "Display \(runtimeID)",
    isBuiltIn: runtimeID == 1,
    isVirtual: false,
    isMirrored: false
  )
}
