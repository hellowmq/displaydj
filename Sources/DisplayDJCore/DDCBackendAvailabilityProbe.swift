import Darwin

/// A DDC probe that checks architecture-specific entry points, associates a
/// read-only I/O Registry service with each display, and then reads brightness
/// back to turn a possible backend into observed feature support.
///
/// Only brightness is settled by an actual request, and only ever by a Get: no
/// Set VCP frame is sent, so probing cannot change display state. The remaining
/// capabilities stay unknown, because a service association alone establishes
/// that a backend can be attempted later, not that a feature is supported.
public struct DDCBackendAvailabilityProbe: DisplayCapabilityProbing {
  private static let brightnessFeatureCode: UInt8 = 0x10

  public let kind: BackendKind
  public let probedCapabilities: Set<DisplayCapability> = [
    .brightness,
    .contrast,
    .volume,
    .mute,
  ]

  private let availability: DDCTransportEntrypointAvailability
  private let serviceMatcher: any DDCServiceMatching
  /// Absent when no read-only transport exists for `kind`, which keeps every
  /// capability unknown instead of guessing from the association alone.
  private let featureReader: (any DDCFeatureProbeReading)?

  public init() {
    let configuration = DDCTransportEntrypointConfiguration.current
    let resolvedAvailability = DDCTransportEntrypointLoader.inspect(configuration)
    kind = configuration.kind
    availability = resolvedAvailability
    serviceMatcher = DDCServiceMatcher.current(for: configuration.kind)
    featureReader = Self.liveFeatureReader(
      for: configuration.kind,
      availability: resolvedAvailability
    )
  }

  init(
    kind: BackendKind,
    availability: DDCTransportEntrypointAvailability
  ) {
    self.init(
      kind: kind,
      availability: availability,
      serviceMatcher: DDCServiceMatcher.current(for: kind)
    )
  }

  init(
    kind: BackendKind,
    availability: DDCTransportEntrypointAvailability,
    serviceMatcher: any DDCServiceMatching,
    featureReader: (any DDCFeatureProbeReading)? = nil
  ) {
    self.kind = kind
    self.availability = availability
    self.serviceMatcher = serviceMatcher
    self.featureReader = featureReader
  }

  private static func liveFeatureReader(
    for kind: BackendKind,
    availability: DDCTransportEntrypointAvailability
  ) -> (any DDCFeatureProbeReading)? {
    guard kind == .appleSiliconDDC, case .available = availability else {
      return nil
    }
    return AppleSiliconDDCFeatureProbeReader()
  }

  public func prepared(
    for displays: [DisplayDescriptor]
  ) async -> any DisplayCapabilityProbing {
    guard case .available = availability else {
      return self
    }
    return DDCBackendAvailabilityProbe(
      kind: kind,
      availability: availability,
      serviceMatcher: await serviceMatcher.prepared(for: displays),
      featureReader: featureReader
    )
  }

  public func probeCapabilities(
    for display: DisplayDescriptor
  ) async throws -> [DisplayCapabilityProbeResult] {
    switch availability {
    case .available:
      return try await probeAvailableBackend(for: display)
    case .frameworkUnavailable(let path):
      throw unavailableError(
        for: display,
        message: "The DDC transport framework could not be loaded.",
        details: [
          "frameworkPath": path,
          "reason": "framework-unavailable",
        ]
      )
    case .missingSymbols(let path, let symbols):
      throw unavailableError(
        for: display,
        message: "Required DDC transport entry points are unavailable.",
        details: [
          "frameworkPath": path,
          "missingSymbols": symbols.sorted().joined(separator: ","),
          "reason": "required-symbols-missing",
        ]
      )
    }
  }

  private func probeAvailableBackend(
    for display: DisplayDescriptor
  ) async throws -> [DisplayCapabilityProbeResult] {
    switch try await serviceAssociation(for: display) {
    case .matched(let identity):
      let association = [
        "Required DDC transport entry points are loadable.",
        "A unique runtime-only \(identity.serviceClass) service was associated",
        "using \(identity.matchBasis.rawValue).",
      ].joined(separator: " ")

      guard let featureReader else {
        return unknownResults(
          reason: [
            association,
            "This backend has no read-only probe transport, so no VCP request",
            "was sent and display support remains unknown.",
          ].joined(separator: " ")
        )
      }
      return await results(
        for: display,
        service: identity,
        association: association,
        featureReader: featureReader
      )
    case .notFound(let reason):
      throw probeError(
        code: .backendUnavailable,
        for: display,
        message: "No per-display DDC service is available. \(reason)",
        details: ["reason": "ddc-service-not-found"]
      )
    case .unresolved(let reason):
      throw probeError(
        code: .conflict,
        for: display,
        message: "The DDC service association is indeterminate. \(reason)",
        details: ["reason": "ddc-service-association-unresolved"]
      )
    case .ambiguous(let candidateCount, let reason):
      throw probeError(
        code: .conflict,
        for: display,
        message: "Multiple DDC services match this display. \(reason)",
        details: [
          "candidateCount": String(candidateCount),
          "reason": "ddc-service-association-ambiguous",
        ]
      )
    }
  }

  private func serviceAssociation(
    for display: DisplayDescriptor
  ) async throws -> DDCServiceAssociation {
    do {
      return try await serviceMatcher.association(for: display)
    } catch let error as DDCServiceMatchingError {
      throw probeError(
        code: .transportFailure,
        for: display,
        message: error.message,
        details: error.details
      )
    } catch {
      throw probeError(
        code: .transportFailure,
        for: display,
        message: "Passive DDC service matching failed unexpectedly.",
        details: [
          "reason": "unexpected-service-matching-error",
          "underlyingError": String(describing: error),
        ]
      )
    }
  }

  /// Settles brightness with one read-only Get VCP and leaves every other probed
  /// capability unknown, naming the reason each one was not requested.
  private func results(
    for display: DisplayDescriptor,
    service: DDCServiceIdentity,
    association: String,
    featureReader: any DDCFeatureProbeReading
  ) async -> [DisplayCapabilityProbeResult] {
    let brightness = await brightnessResult(
      for: display,
      service: service,
      association: association,
      featureReader: featureReader
    )
    let notRequested = [
      association,
      "Only brightness is settled by a read-only Get VCP request,",
      "so this capability was never requested.",
    ].joined(separator: " ")

    return DisplayCapability.allCases.compactMap { capability in
      guard probedCapabilities.contains(capability) else {
        return nil
      }
      guard capability != .brightness else {
        return brightness
      }
      return DisplayCapabilityProbeResult(
        capability: capability,
        state: .unknown,
        reason: notRequested
      )
    }
  }

  private func brightnessResult(
    for display: DisplayDescriptor,
    service: DDCServiceIdentity,
    association: String,
    featureReader: any DDCFeatureProbeReading
  ) async -> DisplayCapabilityProbeResult {
    let target = DDCTransportTarget(
      display: display,
      backend: kind,
      service: service
    )

    do {
      let value = try await featureReader.readFeature(
        Self.brightnessFeatureCode,
        on: target
      )
      return DisplayCapabilityProbeResult(
        capability: .brightness,
        state: .supported,
        reason: [
          association,
          "A read-only Get VCP 0x10 returned \(value.currentValue)",
          "of \(value.maximumValue).",
        ].joined(separator: " ")
      )
    } catch let error as DisplayDJError where error.code == .unsupported {
      return DisplayCapabilityProbeResult(
        capability: .brightness,
        state: .unsupported,
        reason: [
          association,
          "The display answered a read-only Get VCP 0x10 by reporting the",
          "feature unsupported.",
        ].joined(separator: " ")
      )
    } catch {
      return DisplayCapabilityProbeResult(
        capability: .brightness,
        state: .unknown,
        reason: [
          association,
          "A read-only Get VCP 0x10 did not complete, so support is unknown:",
          probeFailureDescription(error),
        ].joined(separator: " ")
      )
    }
  }

  private func probeFailureDescription(_ error: any Error) -> String {
    if let displayError = error as? DisplayDJError {
      return displayError.details["reason"] ?? displayError.code.rawValue
    }
    if error is CancellationError {
      return "cancelled"
    }
    return String(describing: error)
  }

  private func unknownResults(
    reason: String
  ) -> [DisplayCapabilityProbeResult] {
    DisplayCapability.allCases.compactMap { capability in
      guard probedCapabilities.contains(capability) else {
        return nil
      }
      return DisplayCapabilityProbeResult(
        capability: capability,
        state: .unknown,
        reason: reason
      )
    }
  }

  private func unavailableError(
    for display: DisplayDescriptor,
    message: String,
    details: [String: String]
  ) -> DisplayDJError {
    probeError(
      code: .backendUnavailable,
      for: display,
      message: message,
      details: details
    )
  }

  private func probeError(
    code: DisplayDJErrorCode,
    for display: DisplayDescriptor,
    message: String,
    details: [String: String]
  ) -> DisplayDJError {
    DisplayDJError(
      code: code,
      message: message,
      operation: .probe,
      displayID: display.stableID ?? "runtime:\(display.runtimeID)",
      backend: kind,
      details: details
    )
  }
}

/// One read-only VCP request used to settle capability state. Implementations
/// must never send a Set frame: a probe may not change display state.
protocol DDCFeatureProbeReading: Sendable {
  func readFeature(
    _ featureCode: UInt8,
    on target: DDCTransportTarget
  ) async throws -> DDCVCPFeatureValue
}

/// Shares the process-wide serialization registry so that a capability probe
/// cannot interleave an I2C exchange with a concurrent read or write.
struct AppleSiliconDDCFeatureProbeReader: DDCFeatureProbeReading {
  func readFeature(
    _ featureCode: UInt8,
    on target: DDCTransportTarget
  ) async throws -> DDCVCPFeatureValue {
    let executor = DDCVCPExecutor(
      transport: try AppleSiliconDDCTransport.current(),
      laneRegistry: .processShared
    )
    return try await executor.getFeature(featureCode, from: target)
  }
}

enum DDCTransportEntrypointAvailability: Equatable, Sendable {
  case available
  case frameworkUnavailable(path: String)
  case missingSymbols(path: String, symbols: [String])
}

struct DDCTransportEntrypointConfiguration: Equatable, Sendable {
  let kind: BackendKind
  let frameworkPath: String
  let requiredSymbols: [String]

  static var current: DDCTransportEntrypointConfiguration {
    #if arch(arm64)
      DDCTransportEntrypointConfiguration(
        kind: .appleSiliconDDC,
        frameworkPath: AppleSiliconIOAVABI.frameworkPath,
        requiredSymbols: AppleSiliconIOAVABI.requiredSymbols
      )
    #elseif arch(x86_64)
      DDCTransportEntrypointConfiguration(
        kind: .intelDDC,
        frameworkPath: "/System/Library/Frameworks/IOKit.framework/IOKit",
        requiredSymbols: [
          "IOFBCopyI2CInterfaceForBus",
          "IOFBGetI2CInterfaceCount",
          "IOI2CInterfaceClose",
          "IOI2CInterfaceOpen",
          "IOI2CSendRequest",
        ]
      )
    #else
      #error("displaydj supports DDC probing only on arm64 and x86_64 macOS")
    #endif
  }
}

enum DDCTransportEntrypointLoader {
  static func inspect(
    _ configuration: DDCTransportEntrypointConfiguration
  ) -> DDCTransportEntrypointAvailability {
    guard
      let handle = dlopen(
        configuration.frameworkPath,
        RTLD_LAZY | RTLD_LOCAL
      )
    else {
      return .frameworkUnavailable(path: configuration.frameworkPath)
    }
    defer { dlclose(handle) }

    let missingSymbols = configuration.requiredSymbols.filter { symbol in
      symbol.withCString { dlsym(handle, $0) == nil }
    }
    guard missingSymbols.isEmpty else {
      return .missingSymbols(
        path: configuration.frameworkPath,
        symbols: missingSymbols
      )
    }

    return .available
  }
}
