import Foundation

/// Continuous MCCS controls only. Discrete input/mute commands need different
/// validation and are deliberately not passed through percentage conversion.
public enum DDCContinuousControl: String, Codable, CaseIterable, Sendable {
  case contrast, volume

  var featureCode: UInt8 { self == .contrast ? 0x12 : 0x62 }
  var control: DisplayControl { self == .contrast ? .contrast : .volume }
}

public struct AppleSiliconDDCControl: Sendable {
  public init() {}

  public func read(_ control: DDCContinuousControl, fromStableID stableID: String) async throws -> ControlReadResult {
    let selector = try DisplayCLISelector.parse(stableID)
    return try await HardwareProcessLock.withLock {
      let executor = try Self.executor()
      return try await DDCBrightnessReader(
        discovery: CoreGraphicsDisplayDiscovery(), backend: .appleSiliconDDC,
        serviceMatcher: DDCServiceMatcher.current(for: .appleSiliconDDC), executor: executor,
        featureCode: control.featureCode, control: control.control
      ).read(from: selector)
    }
  }

  /// Relative changes are calculated inside the locked baseline transaction.
  public func write(_ control: DDCContinuousControl, normalized value: Double,
                    relative: Bool = false, toStableID stableID: String) async throws -> ControlWriteResult {
    guard value.isFinite, relative ? (-1...1).contains(value) : (0...1).contains(value) else {
      throw DisplayDJError.invalidControlValue(value, expectedRange: relative ? "-1...1" : "0...1")
    }
    let selector = try DisplayCLISelector.parse(stableID)
    let absolute = try DisplayControlValue(normalized: relative ? 0 : value)
    return try await HardwareProcessLock.withLock {
      let executor = try Self.executor()
      return try await DDCBrightnessWriter(
        discovery: CoreGraphicsDisplayDiscovery(), backend: .appleSiliconDDC,
        serviceMatcher: DDCServiceMatcher.current(for: .appleSiliconDDC), executor: executor,
        featureCode: control.featureCode, control: control.control
      ).write(absolute, to: selector, relativeDelta: relative ? value : nil)
    }
  }

  private static func executor() throws -> DDCVCPExecutor {
    do {
      return DDCVCPExecutor(transport: try AppleSiliconDDCTransport.current(), laneRegistry: .processShared)
    } catch {
      throw DisplayDJError(code: .backendUnavailable, message: "Apple Silicon DDC transport unavailable: \(error)", backend: .appleSiliconDDC)
    }
  }
}
