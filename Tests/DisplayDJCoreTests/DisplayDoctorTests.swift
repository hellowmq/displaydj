import Testing

@testable import DisplayDJCore

@Test("Doctor passes a healthy read-only discovery snapshot")
func doctorHealthySnapshot() async throws {
  let displays = [
    makeDoctorDisplay(runtimeID: 1, stableID: "uuid:first", isVirtual: false),
    makeDoctorDisplay(runtimeID: 2, stableID: "uuid:second", isVirtual: true),
  ]

  let report = try await makeDoctor(displays: displays).run()
  let reachabilityCheck = try #require(
    report.checks.first { $0.id == "ddc-brightness-reachability" }
  )

  #expect(report.status == .healthy)
  #expect(report.displayCount == 2)
  #expect(report.checks.count == 4)
  #expect(report.checks.allSatisfy { $0.status == .passed })
  #expect(reachabilityCheck.details["probedCount"] == "1")
  #expect(reachabilityCheck.details["reachableCount"] == "1")
}

@Test("Doctor warns when a controllable display does not answer a brightness read")
func doctorWarnsAboutUnreachableDDC() async throws {
  let displays = [
    makeDoctorDisplay(runtimeID: 1, stableID: "uuid:answers", isVirtual: false),
    makeDoctorDisplay(runtimeID: 2, stableID: "uuid:silent", isVirtual: false),
  ]

  let report = try await makeDoctor(
    displays: displays,
    probe: DoctorFakeCapabilityProbe(
      statesByRuntimeID: [
        1: .supported,
        2: .unknown,
      ],
      reason: "transport-no-reply"
    )
  ).run()
  let reachabilityCheck = try #require(
    report.checks.first { $0.id == "ddc-brightness-reachability" }
  )

  #expect(report.status == .warning)
  #expect(reachabilityCheck.status == .warning)
  #expect(reachabilityCheck.details["probedCount"] == "2")
  #expect(reachabilityCheck.details["reachableCount"] == "1")
  #expect(reachabilityCheck.details["unreachableCount"] == "1")
  #expect(reachabilityCheck.details["unreachableDisplays"] == "uuid:silent")
  #expect(reachabilityCheck.details["firstUnreachableReason"] == "transport-no-reply")
}

@Test("Doctor treats an explicitly unsupported brightness feature as an answer")
func doctorAcceptsUnsupportedBrightnessAsReachable() async throws {
  let displays = [
    makeDoctorDisplay(runtimeID: 1, stableID: "uuid:no-brightness", isVirtual: false)
  ]

  let report = try await makeDoctor(
    displays: displays,
    probe: DoctorFakeCapabilityProbe(statesByRuntimeID: [1: .unsupported])
  ).run()
  let reachabilityCheck = try #require(
    report.checks.first { $0.id == "ddc-brightness-reachability" }
  )

  #expect(report.status == .healthy)
  #expect(reachabilityCheck.status == .passed)
  #expect(reachabilityCheck.details["unsupportedCount"] == "1")
  #expect(reachabilityCheck.details["unreachableCount"] == "0")
}

@Test("Doctor skips the DDC check when no controllable display is online")
func doctorSkipsDDCCheckWithoutControllableDisplays() async throws {
  let displays = [
    makeDoctorDisplay(runtimeID: 1, stableID: "uuid:virtual-only", isVirtual: true)
  ]

  let probe = DoctorFakeCapabilityProbe(statesByRuntimeID: [:])
  let report = try await makeDoctor(displays: displays, probe: probe).run()
  let reachabilityCheck = try #require(
    report.checks.first { $0.id == "ddc-brightness-reachability" }
  )

  #expect(report.status == .healthy)
  #expect(reachabilityCheck.status == .passed)
  #expect(reachabilityCheck.details["probedCount"] == "0")
  #expect(await probe.probedRuntimeIDs().isEmpty)
}

@Test("Doctor warns about unstable selectors and unknown virtual status")
func doctorWarningSnapshot() async throws {
  let displays = [
    makeDoctorDisplay(runtimeID: 1, stableID: "uuid:duplicate", isVirtual: nil),
    makeDoctorDisplay(runtimeID: 2, stableID: "UUID:DUPLICATE", isVirtual: false),
    makeDoctorDisplay(runtimeID: 3, stableID: nil, isVirtual: false),
    makeDoctorDisplay(runtimeID: 4, stableID: " uuid:invalid ", isVirtual: false),
  ]

  let report = try await makeDoctor(displays: displays).run()
  let selectorCheck = try #require(
    report.checks.first { $0.id == "stable-selector-integrity" }
  )
  let virtualCheck = try #require(
    report.checks.first { $0.id == "virtual-display-classification" }
  )

  #expect(report.status == .warning)
  #expect(selectorCheck.status == .warning)
  #expect(selectorCheck.details["missingStableIDCount"] == "1")
  #expect(selectorCheck.details["invalidStableIDCount"] == "1")
  #expect(selectorCheck.details["duplicateStableIDCount"] == "1")
  #expect(selectorCheck.details["duplicateDisplayCount"] == "2")
  #expect(virtualCheck.status == .warning)
  #expect(virtualCheck.details["unknownCount"] == "1")
}

@Test("Doctor reports no online displays as a stable display-not-found error")
func doctorNoDisplays() async {
  do {
    _ = try await DisplayDoctor(
      discovery: FakeDiscovery(result: .success([]))
    ).run()
    Issue.record("Expected a display-not-found error.")
  } catch let error as DisplayDJError {
    #expect(error.code == .displayNotFound)
    #expect(error.code.cliExitCode == .displayNotFound)
    #expect(error.details["check"] == "display-discovery")
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
}

@Test("Doctor preserves structured discovery failures")
func doctorPreservesDiscoveryFailure() async {
  let expectedError = DisplayDJError(
    code: .transportFailure,
    message: "Topology changed.",
    operation: .discover,
    details: ["reason": "topology-changed"]
  )

  do {
    _ = try await DisplayDoctor(
      discovery: FakeDiscovery(result: .failure(expectedError))
    ).run()
    Issue.record("Expected a transport failure.")
  } catch let error as DisplayDJError {
    #expect(error == expectedError)
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
}

private struct FakeDiscovery: DisplayDiscovering {
  let result: Result<[DisplayDescriptor], DisplayDJError>

  func discoverDisplays() async throws -> [DisplayDescriptor] {
    try result.get()
  }
}

private func makeDoctor(
  displays: [DisplayDescriptor],
  probe: DoctorFakeCapabilityProbe? = nil
) -> DisplayDoctor {
  let resolvedProbe =
    probe
    ?? DoctorFakeCapabilityProbe(
      statesByRuntimeID: Dictionary(
        uniqueKeysWithValues: displays.map { ($0.runtimeID, .supported) }
      )
    )
  return DisplayDoctor(
    discovery: FakeDiscovery(result: .success(displays)),
    capabilityProbe: resolvedProbe
  )
}

private actor DoctorFakeCapabilityProbe: DisplayCapabilityProbing {
  nonisolated let kind: BackendKind = .mock
  nonisolated let probedCapabilities: Set<DisplayCapability> = [.brightness]

  private let statesByRuntimeID: [UInt32: DisplayCapabilityState]
  private let reason: String?
  private var probedIDs: [UInt32] = []

  init(
    statesByRuntimeID: [UInt32: DisplayCapabilityState],
    reason: String? = nil
  ) {
    self.statesByRuntimeID = statesByRuntimeID
    self.reason = reason
  }

  func probeCapabilities(
    for display: DisplayDescriptor
  ) async throws -> [DisplayCapabilityProbeResult] {
    probedIDs.append(display.runtimeID)
    guard let state = statesByRuntimeID[display.runtimeID] else {
      throw DisplayDJError(
        code: .backendUnavailable,
        message: "No fake capability state was registered for this display.",
        operation: .probe,
        details: ["reason": "fake-state-missing"]
      )
    }
    return [
      DisplayCapabilityProbeResult(
        capability: .brightness,
        state: state,
        reason: reason
      )
    ]
  }

  func probedRuntimeIDs() -> [UInt32] {
    probedIDs
  }
}

private func makeDoctorDisplay(
  runtimeID: UInt32,
  stableID: String?,
  isVirtual: Bool?
) -> DisplayDescriptor {
  DisplayDescriptor(
    runtimeID: runtimeID,
    stableID: stableID,
    name: "Display \(runtimeID)",
    isBuiltIn: false,
    isVirtual: isVirtual,
    isMirrored: false
  )
}
