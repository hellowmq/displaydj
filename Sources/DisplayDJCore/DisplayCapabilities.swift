public struct DisplayCapabilityAggregator: Sendable {
  private let discovery: any DisplayDiscovering
  private let probes: [any DisplayCapabilityProbing]

  public init(
    discovery: any DisplayDiscovering,
    probes: [any DisplayCapabilityProbing]
  ) {
    self.discovery = discovery
    self.probes = probes
  }

  /// Probes each display and backend serially so one transport is never queried
  /// concurrently by this aggregation layer.
  public func run() async throws -> [DisplayCapabilitiesReport] {
    let displays = sorted(try await discovery.discoverDisplays())

    guard !displays.isEmpty else {
      throw DisplayDJError(
        code: .displayNotFound,
        message: "No online displays are available for capability probing.",
        operation: .probe,
        details: ["query": "capabilities"]
      )
    }

    let activeProbes = await preparedProbes(for: displays)

    let verificationDisplays = sorted(try await discovery.discoverDisplays())
    guard verificationDisplays == displays else {
      throw DisplayDJError(
        code: .conflict,
        message: "The display topology changed during capability preparation.",
        operation: .probe,
        details: [
          "after": selectors(for: verificationDisplays),
          "before": selectors(for: displays),
          "reason": "display-topology-changed",
        ]
      )
    }

    var reports: [DisplayCapabilitiesReport] = []
    for display in displays {
      reports.append(
        DisplayCapabilitiesReport(
          display: display,
          capabilities: try await assessments(
            for: display,
            probes: activeProbes
          )
        )
      )
    }
    return reports
  }

  private func assessments(
    for display: DisplayDescriptor,
    probes: [any DisplayCapabilityProbing]
  ) async throws -> [DisplayCapabilityAssessment] {
    let sourcesByCapability = try await collectSources(
      for: display,
      probes: probes
    )

    return DisplayCapability.allCases.map { capability in
      let sources = (sourcesByCapability[capability] ?? []).sorted {
        $0.backend.rawValue < $1.backend.rawValue
      }
      return DisplayCapabilityAssessment(
        capability: capability,
        state: aggregateState(for: sources),
        sources: sources
      )
    }
  }

  private func collectSources(
    for display: DisplayDescriptor,
    probes: [any DisplayCapabilityProbing]
  ) async throws -> [DisplayCapability: [DisplayCapabilitySource]] {
    var sourcesByCapability: [DisplayCapability: [DisplayCapabilitySource]] = [:]
    var seenSources: Set<ProbeSourceKey> = []

    for probe in probes {
      for probedSource in try await sources(from: probe, for: display) {
        try append(
          probedSource.source,
          for: probedSource.capability,
          to: &sourcesByCapability,
          seenSources: &seenSources,
          display: display
        )
      }
    }
    return sourcesByCapability
  }

  private func sources(
    from probe: any DisplayCapabilityProbing,
    for display: DisplayDescriptor
  ) async throws -> [ProbedCapabilitySource] {
    let expectedCapabilities = probe.probedCapabilities
    guard !expectedCapabilities.isEmpty else {
      return []
    }

    do {
      let results = try await probe.probeCapabilities(for: display)
      try validate(
        results,
        expectedCapabilities: expectedCapabilities,
        backend: probe.kind,
        display: display
      )
      return results.map {
        ProbedCapabilitySource(
          capability: $0.capability,
          source: DisplayCapabilitySource(
            backend: probe.kind,
            state: $0.state,
            reason: $0.reason
          )
        )
      }
    } catch let error as DisplayDJError {
      guard let state = aggregateState(forProbeError: error.code) else {
        throw error
      }
      return expectedCapabilities.map {
        ProbedCapabilitySource(
          capability: $0,
          source: DisplayCapabilitySource(
            backend: probe.kind,
            state: state,
            reason: error.message,
            errorCode: error.code
          )
        )
      }
    } catch {
      throw DisplayDJError(
        code: .internalFailure,
        message: "A capability probe failed with an unexpected error.",
        operation: .probe,
        displayID: selector(for: display),
        backend: probe.kind,
        details: ["underlyingError": String(describing: error)]
      )
    }
  }

  private func validate(
    _ results: [DisplayCapabilityProbeResult],
    expectedCapabilities: Set<DisplayCapability>,
    backend: BackendKind,
    display: DisplayDescriptor
  ) throws {
    let actualCapabilities = Set(results.map(\.capability))
    guard
      actualCapabilities.count == results.count,
      actualCapabilities == expectedCapabilities
    else {
      throw DisplayDJError(
        code: .internalFailure,
        message: "A capability probe violated its declared result contract.",
        operation: .probe,
        displayID: selector(for: display),
        backend: backend,
        details: [
          "actualCapabilities": joined(actualCapabilities),
          "expectedCapabilities": joined(expectedCapabilities),
          "resultCount": String(results.count),
        ]
      )
    }
  }

  private func append(
    _ source: DisplayCapabilitySource,
    for capability: DisplayCapability,
    to sourcesByCapability: inout [DisplayCapability: [DisplayCapabilitySource]],
    seenSources: inout Set<ProbeSourceKey>,
    display: DisplayDescriptor
  ) throws {
    let key = ProbeSourceKey(backend: source.backend, capability: capability)
    guard seenSources.insert(key).inserted else {
      throw DisplayDJError(
        code: .internalFailure,
        message: "Multiple capability probes reported the same backend and capability.",
        operation: .probe,
        displayID: selector(for: display),
        backend: source.backend,
        details: ["capability": capability.rawValue]
      )
    }

    sourcesByCapability[capability, default: []].append(source)
  }

  private func aggregateState(
    for sources: [DisplayCapabilitySource]
  ) -> DisplayCapabilityState {
    guard !sources.isEmpty else {
      return .unavailable
    }
    if sources.contains(where: { $0.state == .supported }) {
      return .supported
    }
    if sources.contains(where: { $0.state == .unknown }) {
      return .unknown
    }
    if sources.contains(where: { $0.state == .unavailable }) {
      return .unavailable
    }
    return .unsupported
  }

  private func aggregateState(
    forProbeError code: DisplayDJErrorCode
  ) -> DisplayCapabilityState? {
    switch code {
    case .unsupported:
      .unsupported
    case .backendUnavailable:
      .unavailable
    case .timeout, .busy, .transportFailure, .conflict:
      .unknown
    case .invalidArguments, .invalidValue, .invalidSelector, .displayNotFound,
      .ambiguousDisplay, .verificationFailed, .internalFailure:
      nil
    }
  }

  private func preparedProbes(
    for displays: [DisplayDescriptor]
  ) async -> [any DisplayCapabilityProbing] {
    var prepared: [any DisplayCapabilityProbing] = []
    for probe in probes {
      prepared.append(await probe.prepared(for: displays))
    }
    return prepared
  }

  private func sorted(
    _ displays: [DisplayDescriptor]
  ) -> [DisplayDescriptor] {
    displays.sorted { $0.runtimeID < $1.runtimeID }
  }

  private func selectors(for displays: [DisplayDescriptor]) -> String {
    displays.map(selector).joined(separator: ",")
  }

  private func joined(_ capabilities: Set<DisplayCapability>) -> String {
    capabilities.map(\.rawValue).sorted().joined(separator: ",")
  }

  private func selector(for display: DisplayDescriptor) -> String {
    display.stableID ?? "runtime:\(display.runtimeID)"
  }
}

private struct ProbedCapabilitySource {
  let capability: DisplayCapability
  let source: DisplayCapabilitySource
}

private struct ProbeSourceKey: Hashable {
  let backend: BackendKind
  let capability: DisplayCapability
}
