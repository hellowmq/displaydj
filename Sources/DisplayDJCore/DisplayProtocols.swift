/// Discovers the current display topology.
public protocol DisplayDiscovering: Sendable {
  func discoverDisplays() async throws -> [DisplayDescriptor]
}

/// A replaceable, injectable capability probe.
///
/// `probedCapabilities` declares the complete result set expected from a
/// successful call. Implementations must return one explicit result for every
/// declared capability, including `unknown` or `unavailable` when support cannot
/// be determined. Omitting a result is treated as an internal contract failure.
public protocol DisplayCapabilityProbing: Sendable {
  var kind: BackendKind { get }
  var probedCapabilities: Set<DisplayCapability> { get }

  /// Returns a run-scoped probe prepared from the complete discovery snapshot.
  /// Implementations with mutable topology state must return an independent
  /// instance so concurrent aggregation runs cannot overwrite each other.
  func prepared(for displays: [DisplayDescriptor]) async -> any DisplayCapabilityProbing

  func probeCapabilities(
    for display: DisplayDescriptor
  ) async throws -> [DisplayCapabilityProbeResult]
}

extension DisplayCapabilityProbing {
  public func prepared(
    for displays: [DisplayDescriptor]
  ) async -> any DisplayCapabilityProbing {
    self
  }
}

/// A replaceable hardware or software control backend.
///
/// Implementations must not use fire-and-forget writes. `write(_:to:)` returns
/// only after the transport operation has completed or failed, and its result
/// must report the value actually applied or observed rather than assuming the
/// requested value succeeded.
public protocol DisplayControlBackend: DisplayCapabilityProbing {
  func read(
    _ control: DisplayControl,
    from display: DisplayDescriptor
  ) async throws -> ControlReadResult

  func write(
    _ request: ControlWriteRequest,
    to display: DisplayDescriptor
  ) async throws -> ControlWriteResult
}
