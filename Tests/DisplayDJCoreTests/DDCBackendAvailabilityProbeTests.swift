import Testing

@testable import DisplayDJCore

@Test("DDC entrypoint configuration matches the build architecture")
func ddcEntrypointConfigurationMatchesArchitecture() {
  let configuration = DDCTransportEntrypointConfiguration.current

  #expect(
    configuration.frameworkPath
      == "/System/Library/Frameworks/IOKit.framework/IOKit"
  )
  #if arch(arm64)
    #expect(configuration.kind == .appleSiliconDDC)
    #expect(
      configuration.requiredSymbols == [
        "IOAVServiceCreateWithService",
        "IOAVServiceReadI2C",
        "IOAVServiceWriteI2C",
      ]
    )
  #elseif arch(x86_64)
    #expect(configuration.kind == .intelDDC)
    #expect(
      configuration.requiredSymbols == [
        "IOFBCopyI2CInterfaceForBus",
        "IOFBGetI2CInterfaceCount",
        "IOI2CInterfaceClose",
        "IOI2CInterfaceOpen",
        "IOI2CSendRequest",
      ]
    )
  #endif
}

@Test("A backend without a probe transport stays unknown after association")
func loadableDDCEntrypointsRemainUnknown() async throws {
  let probe = DDCBackendAvailabilityProbe(
    kind: .appleSiliconDDC,
    availability: .available,
    serviceMatcher: matchedProbeService()
  )

  let results = try await probe.probeCapabilities(for: makeDDCDisplay())

  #expect(
    results.map(\.capability) == [
      .brightness,
      .contrast,
      .volume,
      .mute,
    ]
  )
  #expect(results.allSatisfy { $0.state == .unknown })
  #expect(results.allSatisfy { $0.reason?.contains("DCPAVServiceProxy") == true })
  #expect(results.allSatisfy { $0.reason?.contains("no VCP request") == true })
}

@Test("A readable brightness feature becomes supported without any Set frame")
func readableBrightnessBecomesSupported() async throws {
  let reader = FakeDDCFeatureProbeReader(
    result: .success(
      DDCVCPFeatureValue(
        featureCode: 0x10,
        valueType: .setParameter,
        maximumValue: 100,
        currentValue: 64
      )
    )
  )
  let probe = DDCBackendAvailabilityProbe(
    kind: .appleSiliconDDC,
    availability: .available,
    serviceMatcher: matchedProbeService(),
    featureReader: reader
  )

  let results = try await probe.probeCapabilities(for: makeDDCDisplay())
  let brightness = try #require(results.first { $0.capability == .brightness })

  #expect(brightness.state == .supported)
  #expect(brightness.reason?.contains("returned 64 of 100") == true)
  #expect(await reader.requestedFeatureCodes() == [0x10])
  #expect(
    results.filter { $0.capability != .brightness }.allSatisfy {
      $0.state == .unknown
    }
  )
}

@Test("A display reporting brightness unsupported is not left unknown")
func unsupportedBrightnessIsReportedAsUnsupported() async throws {
  let probe = DDCBackendAvailabilityProbe(
    kind: .appleSiliconDDC,
    availability: .available,
    serviceMatcher: matchedProbeService(),
    featureReader: FakeDDCFeatureProbeReader(
      result: .failure(
        DisplayDJError(
          code: .unsupported,
          message: "The display reports that this DDC/CI VCP feature is unsupported.",
          operation: .probe,
          details: ["reason": "ddc-feature-unsupported"]
        )
      )
    )
  )

  let results = try await probe.probeCapabilities(for: makeDDCDisplay())
  let brightness = try #require(results.first { $0.capability == .brightness })

  #expect(brightness.state == .unsupported)
  #expect(brightness.reason?.contains("feature unsupported") == true)
}

@Test("A failed brightness probe stays unknown and names the transport reason")
func failedBrightnessProbeStaysUnknown() async throws {
  let probe = DDCBackendAvailabilityProbe(
    kind: .appleSiliconDDC,
    availability: .available,
    serviceMatcher: matchedProbeService(),
    featureReader: FakeDDCFeatureProbeReader(
      result: .failure(
        DisplayDJError(
          code: .timeout,
          message: "The DDC transport reported a timeout.",
          operation: .probe,
          details: ["reason": "transport-timeout"]
        )
      )
    )
  )

  let results = try await probe.probeCapabilities(for: makeDDCDisplay())
  let brightness = try #require(results.first { $0.capability == .brightness })

  #expect(brightness.state == .unknown)
  #expect(brightness.reason?.contains("transport-timeout") == true)
}

private func matchedProbeService() -> DDCFakeServiceMatcher {
  DDCFakeServiceMatcher(
    association: .matched(
      DDCServiceIdentity(
        registryEntryID: 0x1234,
        serviceClass: "DCPAVServiceProxy",
        matchBasis: .hardwareTuple
      )
    )
  )
}

private actor FakeDDCFeatureProbeReader: DDCFeatureProbeReading {
  private let result: Result<DDCVCPFeatureValue, DisplayDJError>
  private var featureCodes: [UInt8] = []

  init(result: Result<DDCVCPFeatureValue, DisplayDJError>) {
    self.result = result
  }

  func readFeature(
    _ featureCode: UInt8,
    on target: DDCTransportTarget
  ) async throws -> DDCVCPFeatureValue {
    featureCodes.append(featureCode)
    return try result.get()
  }

  func requestedFeatureCodes() -> [UInt8] {
    featureCodes
  }
}

@Test("Per-display DDC service associations preserve unknown and unavailable states")
func perDisplayDDCServiceAssociationsRemainHonest() async throws {
  let displays = [
    makeDDCDisplay(runtimeID: 10),
    makeDDCDisplay(runtimeID: 2),
    makeDDCDisplay(runtimeID: 20),
  ]
  let probe = DDCBackendAvailabilityProbe(
    kind: .appleSiliconDDC,
    availability: .available,
    serviceMatcher: DDCPerDisplayServiceMatcher(
      associations: [
        2: .matched(
          DDCServiceIdentity(
            registryEntryID: 0x200,
            serviceClass: "DCPAVServiceProxy",
            matchBasis: .hardwareTuple
          )
        ),
        10: .notFound(reason: "No exact hardware identity matched."),
        20: .ambiguous(
          candidateCount: 2,
          reason: "Two exact hardware identities matched."
        ),
      ]
    )
  )

  let reports = try await DisplayCapabilityAggregator(
    discovery: DDCManyFakeDiscovery(displays: displays),
    probes: [probe]
  ).run()

  #expect(reports.map(\.display.runtimeID) == [2, 10, 20])
  let matched = try #require(reports.first { $0.display.runtimeID == 2 })
  let missing = try #require(reports.first { $0.display.runtimeID == 10 })
  let ambiguous = try #require(reports.first { $0.display.runtimeID == 20 })

  try assertPerDisplayDDCStates(
    matched: matched,
    missing: missing,
    ambiguous: ambiguous
  )
}

@Test("Unavailable entrypoints do not enumerate per-display DDC services")
func unavailableEntrypointsSkipServiceMatching() async {
  let recorder = DDCServiceMatchRecorder()
  let probe = DDCBackendAvailabilityProbe(
    kind: .intelDDC,
    availability: .missingSymbols(
      path: "/System/Library/Frameworks/IOKit.framework/IOKit",
      symbols: ["IOI2CSendRequest"]
    ),
    serviceMatcher: recorder
  )

  let display = makeDDCDisplay()
  let preparedProbe = await probe.prepared(for: [display])

  do {
    _ = try await preparedProbe.probeCapabilities(for: display)
    Issue.record("Expected a backend-unavailable error.")
  } catch let error as DisplayDJError {
    #expect(error.code == .backendUnavailable)
    #expect(await recorder.prepareCount == 0)
    #expect(await recorder.runtimeIDs.isEmpty)
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
}

@Test("I/O Registry failures remain unknown transport failures")
func registryFailuresRemainUnknownTransportFailures() async {
  let probe = DDCBackendAvailabilityProbe(
    kind: .appleSiliconDDC,
    availability: .available,
    serviceMatcher: DDCThrowingServiceMatcher(
      error: .registryEnumerationFailed(
        operation: "IORegistryEntryCreateIterator",
        status: -1
      )
    )
  )

  do {
    _ = try await probe.probeCapabilities(for: makeDDCDisplay())
    Issue.record("Expected a transport-failure error.")
  } catch let error as DisplayDJError {
    #expect(error.code == .transportFailure)
    #expect(error.operation == .probe)
    #expect(error.backend == .appleSiliconDDC)
    #expect(error.details["reason"] == "registry-enumeration-failed")
    #expect(error.details["operation"] == "IORegistryEntryCreateIterator")
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
}

@Test("An unavailable DDC framework returns structured backend evidence")
func unavailableDDCFrameworkReturnsStructuredEvidence() async {
  let path = "/missing/IOKit"
  let probe = DDCBackendAvailabilityProbe(
    kind: .intelDDC,
    availability: .frameworkUnavailable(path: path)
  )

  do {
    _ = try await probe.probeCapabilities(for: makeDDCDisplay())
    Issue.record("Expected a backend-unavailable error.")
  } catch let error as DisplayDJError {
    #expect(error.code == .backendUnavailable)
    #expect(error.operation == .probe)
    #expect(error.displayID == "uuid:test-display")
    #expect(error.backend == .intelDDC)
    #expect(error.details["reason"] == "framework-unavailable")
    #expect(error.details["frameworkPath"] == path)
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
}

@Test("Missing DDC symbols are reported deterministically")
func missingDDCSymbolsAreReportedDeterministically() async {
  let probe = DDCBackendAvailabilityProbe(
    kind: .appleSiliconDDC,
    availability: .missingSymbols(
      path: "/System/Library/Frameworks/IOKit.framework/IOKit",
      symbols: ["WriteSymbol", "ReadSymbol"]
    )
  )

  do {
    _ = try await probe.probeCapabilities(for: makeDDCDisplay())
    Issue.record("Expected a backend-unavailable error.")
  } catch let error as DisplayDJError {
    #expect(error.code == .backendUnavailable)
    #expect(error.backend == .appleSiliconDDC)
    #expect(error.details["reason"] == "required-symbols-missing")
    #expect(error.details["missingSymbols"] == "ReadSymbol,WriteSymbol")
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
}

@Test("The entrypoint loader handles a missing framework without calling symbols")
func entrypointLoaderHandlesMissingFramework() {
  let path = "/displaydj/tests/does-not-exist"
  let availability = DDCTransportEntrypointLoader.inspect(
    DDCTransportEntrypointConfiguration(
      kind: .intelDDC,
      frameworkPath: path,
      requiredSymbols: ["NeverCalled"]
    )
  )

  #expect(availability == .frameworkUnavailable(path: path))
}

@Test("The entrypoint loader distinguishes present and missing symbols")
func entrypointLoaderDistinguishesSymbols() {
  let path = "/usr/lib/libSystem.B.dylib"
  let available = DDCTransportEntrypointLoader.inspect(
    DDCTransportEntrypointConfiguration(
      kind: .intelDDC,
      frameworkPath: path,
      requiredSymbols: ["malloc"]
    )
  )
  let unavailable = DDCTransportEntrypointLoader.inspect(
    DDCTransportEntrypointConfiguration(
      kind: .intelDDC,
      frameworkPath: path,
      requiredSymbols: ["malloc", "DisplayDJDefinitelyMissingSymbol"]
    )
  )

  #expect(available == .available)
  #expect(
    unavailable
      == .missingSymbols(
        path: path,
        symbols: ["DisplayDJDefinitelyMissingSymbol"]
      )
  )
}

@Test("The aggregator maps missing DDC entrypoints to unavailable, not unsupported")
func aggregatorMapsMissingDDCEntrypointsToUnavailable() async throws {
  let display = makeDDCDisplay()
  let probe = DDCBackendAvailabilityProbe(
    kind: .intelDDC,
    availability: .missingSymbols(
      path: "/System/Library/Frameworks/IOKit.framework/IOKit",
      symbols: ["IOI2CSendRequest"]
    )
  )
  let reports = try await DisplayCapabilityAggregator(
    discovery: DDCFakeDiscovery(display: display),
    probes: [probe]
  ).run()
  let assessments = try #require(reports.first).capabilities

  for capability in [
    DisplayCapability.brightness,
    .contrast,
    .volume,
    .mute,
  ] {
    let assessment = try #require(assessments.first { $0.capability == capability })
    let source = try #require(assessment.sources.first)
    #expect(assessment.state == .unavailable)
    #expect(source.state == .unavailable)
    #expect(source.errorCode == .backendUnavailable)
    #expect(source.backend == .intelDDC)
  }

  for capability in [DisplayCapability.gamma, .shade] {
    let assessment = try #require(assessments.first { $0.capability == capability })
    #expect(assessment.state == .unavailable)
    #expect(assessment.sources.isEmpty)
  }
}

private func assertPerDisplayDDCStates(
  matched: DisplayCapabilitiesReport,
  missing: DisplayCapabilitiesReport,
  ambiguous: DisplayCapabilitiesReport
) throws {
  for capability in [
    DisplayCapability.brightness,
    .contrast,
    .volume,
    .mute,
  ] {
    let matchedCapability = try #require(
      matched.capabilities.first { $0.capability == capability }
    )
    let missingCapability = try #require(
      missing.capabilities.first { $0.capability == capability }
    )
    let ambiguousCapability = try #require(
      ambiguous.capabilities.first { $0.capability == capability }
    )

    #expect(matchedCapability.state == .unknown)
    #expect(matchedCapability.sources.first?.errorCode == nil)
    #expect(missingCapability.state == .unavailable)
    #expect(missingCapability.sources.first?.errorCode == .backendUnavailable)
    #expect(ambiguousCapability.state == .unknown)
    #expect(ambiguousCapability.sources.first?.errorCode == .conflict)
  }
}

private struct DDCFakeServiceMatcher: DDCServiceMatching {
  let association: DDCServiceAssociation

  func association(
    for display: DisplayDescriptor
  ) async throws -> DDCServiceAssociation {
    association
  }
}

private struct DDCThrowingServiceMatcher: DDCServiceMatching {
  let error: DDCServiceMatchingError

  func association(
    for display: DisplayDescriptor
  ) async throws -> DDCServiceAssociation {
    throw error
  }
}

private struct DDCPerDisplayServiceMatcher: DDCServiceMatching {
  let associations: [UInt32: DDCServiceAssociation]

  func association(
    for display: DisplayDescriptor
  ) async throws -> DDCServiceAssociation {
    associations[display.runtimeID]
      ?? .notFound(reason: "No test association was configured.")
  }
}

private actor DDCServiceMatchRecorder: DDCServiceMatching {
  private(set) var prepareCount = 0
  private(set) var runtimeIDs: [UInt32] = []

  func prepared(
    for displays: [DisplayDescriptor]
  ) async -> any DDCServiceMatching {
    prepareCount += 1
    return self
  }

  func association(
    for display: DisplayDescriptor
  ) async throws -> DDCServiceAssociation {
    runtimeIDs.append(display.runtimeID)
    return .notFound(reason: "Recorded test call.")
  }
}

private struct DDCFakeDiscovery: DisplayDiscovering {
  let display: DisplayDescriptor

  func discoverDisplays() async throws -> [DisplayDescriptor] {
    [display]
  }
}

private struct DDCManyFakeDiscovery: DisplayDiscovering {
  let displays: [DisplayDescriptor]

  func discoverDisplays() async throws -> [DisplayDescriptor] {
    displays
  }
}

private func makeDDCDisplay(runtimeID: UInt32 = 42) -> DisplayDescriptor {
  DisplayDescriptor(
    runtimeID: runtimeID,
    stableID: runtimeID == 42 ? "uuid:test-display" : "uuid:test-display-\(runtimeID)",
    name: "Test Display \(runtimeID)",
    isBuiltIn: false,
    isVirtual: false,
    isMirrored: false
  )
}
