/// Internal single-display orchestration used by the production reader.
///
/// It brackets a run-scoped DDC service association and Get VCP request with
/// fresh display discovery snapshots so changes visible before or after the
/// request cannot produce a successful control result. Discrete snapshots
/// cannot detect an A-to-B-to-A reconfiguration between reads; a monotonic
/// reconfiguration epoch remains a reliability follow-up.
struct DDCBrightnessReader: Sendable {
  private let featureCode: UInt8
  private let control: DisplayControl

  private let support: DDCBrightnessOperationSupport
  private let backend: BackendKind
  private let serviceMatcher: any DDCServiceMatching
  private let executor: DDCVCPExecutor

  init(
    discovery: any DisplayDiscovering,
    selectorResolver: DisplaySelectorResolver = DisplaySelectorResolver(),
    backend: BackendKind,
    serviceMatcher: any DDCServiceMatching,
    executor: DDCVCPExecutor,
    featureCode: UInt8 = 0x10,
    control: DisplayControl = .brightness
  ) {
    self.featureCode = featureCode
    self.control = control
    support = DDCBrightnessOperationSupport(
      discovery: discovery,
      selectorResolver: selectorResolver,
      backend: backend,
      operation: .read,
      featureCode: featureCode
    )
    self.backend = backend
    self.serviceMatcher = serviceMatcher
    self.executor = executor
  }

  func read(
    from selector: DisplaySelector
  ) async throws -> ControlReadResult {
    let initialTopology = try await support.discoverTopology(
      phase: "initial-discovery"
    )
    let display = try support.selectedDisplay(selector, among: initialTopology)
    let session = try await DDCVCPReadSession.prepare(
      backend: backend,
      displays: initialTopology,
      serviceMatcher: serviceMatcher,
      executor: executor
    )

    let preReadTopology = try await support.discoverTopology(
      phase: "pre-read-verification"
    )
    try support.requireUnchangedTopology(
      initialTopology,
      actual: preReadTopology,
      phase: "pre-read-verification",
      display: display
    )

    let rawValue = try await session.getFeature(
      featureCode,
      from: display
    )
    try Task.checkCancellation()

    let postReadTopology = try await support.discoverTopology(
      phase: "post-read-verification"
    )
    try support.requireUnchangedTopology(
      initialTopology,
      actual: postReadTopology,
      phase: "post-read-verification",
      display: display
    )

    return ControlReadResult(
      display: display,
      backend: backend,
      control: control,
      value: try support.brightnessValue(from: rawValue, display: display)
    )
  }
}
