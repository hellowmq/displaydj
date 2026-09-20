import Foundation

public enum DoctorReportStatus: String, Codable, Sendable {
  case healthy = "ok"
  case warning
}

public enum DoctorCheckStatus: String, Codable, Sendable {
  case passed = "pass"
  case warning
}

public struct DoctorCheck: Codable, Equatable, Sendable {
  public let id: String
  public let status: DoctorCheckStatus
  public let message: String
  public let details: [String: String]

  public init(
    id: String,
    status: DoctorCheckStatus,
    message: String,
    details: [String: String] = [:]
  ) {
    self.id = id
    self.status = status
    self.message = message
    self.details = details
  }
}

public struct DoctorReport: Codable, Equatable, Sendable {
  public let status: DoctorReportStatus
  public let displayCount: Int
  public let checks: [DoctorCheck]

  public init(displayCount: Int, checks: [DoctorCheck]) {
    status = checks.contains { $0.status == .warning } ? .warning : .healthy
    self.displayCount = displayCount
    self.checks = checks
  }
}

/// Performs read-only consistency checks against one discovery snapshot, then
/// confirms that each externally controllable display actually answers DDC.
public struct DisplayDoctor: Sendable {
  private static let brightnessCapability = DisplayCapability.brightness

  private let discovery: any DisplayDiscovering
  private let capabilityProbe: any DisplayCapabilityProbing

  public init(discovery: any DisplayDiscovering) {
    self.init(
      discovery: discovery,
      capabilityProbe: DDCBackendAvailabilityProbe()
    )
  }

  init(
    discovery: any DisplayDiscovering,
    capabilityProbe: any DisplayCapabilityProbing
  ) {
    self.discovery = discovery
    self.capabilityProbe = capabilityProbe
  }

  public func run() async throws -> DoctorReport {
    let displays = try await discovery.discoverDisplays()

    guard !displays.isEmpty else {
      throw DisplayDJError(
        code: .displayNotFound,
        message: "CoreGraphics reported no online displays.",
        operation: .discover,
        details: ["check": "display-discovery"]
      )
    }

    return DoctorReport(
      displayCount: displays.count,
      checks: [
        discoveryCheck(for: displays),
        stableSelectorCheck(for: displays),
        virtualClassificationCheck(for: displays),
        await ddcReachabilityCheck(for: displays),
      ]
    )
  }

  /// Reads brightness back from every display a DDC backend could control. This
  /// is what separates "a service was associated" from "the display answers",
  /// which a purely passive check cannot tell apart.
  private func ddcReachabilityCheck(
    for displays: [DisplayDescriptor]
  ) async -> DoctorCheck {
    let controllable = displays.filter {
      !$0.isBuiltIn && $0.isVirtual == false && !$0.isMirrored
    }
    guard !controllable.isEmpty else {
      return DoctorCheck(
        id: "ddc-brightness-reachability",
        status: .passed,
        message: "No externally controllable display was online to probe.",
        details: ["probedCount": "0"]
      )
    }

    let probe = await capabilityProbe.prepared(for: displays)
    var reachable: [String] = []
    var unsupported: [String] = []
    var unreachable: [(selector: String, reason: String)] = []

    for display in controllable {
      let selector = display.stableID ?? "runtime:\(display.runtimeID)"
      switch await brightnessState(of: display, using: probe) {
      case .supported:
        reachable.append(selector)
      case .unsupported:
        unsupported.append(selector)
      case .unknown(let reason):
        unreachable.append((selector, reason))
      }
    }

    var details = [
      "probedCount": String(controllable.count),
      "reachableCount": String(reachable.count),
      "unreachableCount": String(unreachable.count),
      "unsupportedCount": String(unsupported.count),
    ]
    guard unreachable.isEmpty else {
      details["unreachableDisplays"] =
        unreachable
        .map(\.selector)
        .sorted()
        .joined(separator: ",")
      details["firstUnreachableReason"] = unreachable[0].reason
      return DoctorCheck(
        id: "ddc-brightness-reachability",
        status: .warning,
        message: "Some externally controllable displays did not answer a DDC brightness read.",
        details: details
      )
    }

    return DoctorCheck(
      id: "ddc-brightness-reachability",
      status: .passed,
      message: "Every externally controllable display answered a DDC brightness read.",
      details: details
    )
  }

  private func brightnessState(
    of display: DisplayDescriptor,
    using probe: any DisplayCapabilityProbing
  ) async -> DoctorBrightnessState {
    do {
      let results = try await probe.probeCapabilities(for: display)
      guard
        let brightness = results.first(where: {
          $0.capability == Self.brightnessCapability
        })
      else {
        return .unknown(reason: "brightness-not-probed")
      }

      switch brightness.state {
      case .supported:
        return .supported
      case .unsupported:
        return .unsupported
      case .unknown, .unavailable:
        return .unknown(reason: brightness.reason ?? "probe-state-\(brightness.state.rawValue)")
      }
    } catch let error as DisplayDJError {
      return .unknown(reason: error.details["reason"] ?? error.code.rawValue)
    } catch is CancellationError {
      return .unknown(reason: "cancelled")
    } catch {
      return .unknown(reason: String(describing: error))
    }
  }

  private func discoveryCheck(for displays: [DisplayDescriptor]) -> DoctorCheck {
    DoctorCheck(
      id: "display-discovery",
      status: .passed,
      message: "CoreGraphics returned a consistent online display snapshot.",
      details: ["displayCount": String(displays.count)]
    )
  }

  private func stableSelectorCheck(for displays: [DisplayDescriptor]) -> DoctorCheck {
    let missingCount = displays.count { $0.stableID == nil }
    let invalidCount = displays.compactMap(\.stableID).count {
      DisplayStableSelector.normalizeDescriptorID($0) == nil
    }
    let stableIDs = displays.compactMap { display in
      display.stableID.flatMap(DisplayStableSelector.normalizeDescriptorID)
    }
    let duplicateGroups = Dictionary(grouping: stableIDs, by: { $0 }).values.filter {
      $0.count > 1
    }
    let duplicateSelectorCount = duplicateGroups.count
    let duplicateDisplayCount = duplicateGroups.reduce(0) { $0 + $1.count }

    guard missingCount == 0, invalidCount == 0, duplicateSelectorCount == 0 else {
      return DoctorCheck(
        id: "stable-selector-integrity",
        status: .warning,
        message: "Some displays cannot be selected uniquely across reconnects.",
        details: [
          "duplicateDisplayCount": String(duplicateDisplayCount),
          "duplicateStableIDCount": String(duplicateSelectorCount),
          "invalidStableIDCount": String(invalidCount),
          "missingStableIDCount": String(missingCount),
        ]
      )
    }

    return DoctorCheck(
      id: "stable-selector-integrity",
      status: .passed,
      message: "Every online display has a unique stable selector.",
      details: ["stableSelectorCount": String(stableIDs.count)]
    )
  }

  private func virtualClassificationCheck(for displays: [DisplayDescriptor]) -> DoctorCheck {
    let unknownCount = displays.count { $0.isVirtual == nil }

    guard unknownCount == 0 else {
      return DoctorCheck(
        id: "virtual-display-classification",
        status: .warning,
        message: "Virtual-display status is unavailable for some displays.",
        details: ["unknownCount": String(unknownCount)]
      )
    }

    return DoctorCheck(
      id: "virtual-display-classification",
      status: .passed,
      message: "Virtual-display status is known for every online display."
    )
  }
}

private enum DoctorBrightnessState {
  case supported
  case unsupported
  case unknown(reason: String)
}
