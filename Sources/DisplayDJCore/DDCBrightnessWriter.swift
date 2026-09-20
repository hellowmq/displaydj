/// Internal single-display brightness write orchestration used by the production
/// Apple Silicon writer.
///
/// The target Set starts as a single frame and repeats only while its read-back
/// disagrees, never after a transport failure. The executor retains one runtime
/// resource lane across baseline reading, raw-value mapping, Set, read-back, and
/// the final topology check. Any failure after the Set attempt triggers one
/// best-effort Set back to the exact baseline raw value plus read-back before the
/// original failure is returned.
struct DDCBrightnessWriter: Sendable {
  private static let brightnessFeatureCode: UInt8 = 0x10

  private let support: DDCBrightnessOperationSupport
  private let backend: BackendKind
  private let serviceMatcher: any DDCServiceMatching
  private let executor: DDCVCPExecutor

  init(
    discovery: any DisplayDiscovering,
    selectorResolver: DisplaySelectorResolver = DisplaySelectorResolver(),
    backend: BackendKind,
    serviceMatcher: any DDCServiceMatching,
    executor: DDCVCPExecutor
  ) {
    support = DDCBrightnessOperationSupport(
      discovery: discovery,
      selectorResolver: selectorResolver,
      backend: backend,
      operation: .write
    )
    self.backend = backend
    self.serviceMatcher = serviceMatcher
    self.executor = executor
  }

  func write(
    _ value: DisplayControlValue,
    to selector: DisplaySelector
  ) async throws -> ControlWriteResult {
    let preparation = try await prepareWrite(to: selector)
    let target = try await preparation.session.transportTarget(
      Self.brightnessFeatureCode,
      for: preparation.display,
      operation: .write
    )
    let rawResult = try await performWrite(
      value,
      target: target,
      preparation: preparation
    )

    return ControlWriteResult(
      display: preparation.display,
      backend: backend,
      control: .brightness,
      requestedValue: value,
      appliedValue: try support.brightnessValue(
        from: rawResult.verifiedValue,
        display: preparation.display
      ),
      wasVerified: true
    )
  }

  private func prepareWrite(
    to selector: DisplaySelector
  ) async throws -> DDCBrightnessWritePreparation {
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

    let preWriteTopology = try await support.discoverTopology(
      phase: "pre-write-verification"
    )
    try support.requireUnchangedTopology(
      initialTopology,
      actual: preWriteTopology,
      phase: "pre-write-verification",
      display: display
    )
    return DDCBrightnessWritePreparation(
      initialTopology: initialTopology,
      display: display,
      session: session
    )
  }

  private func performWrite(
    _ value: DisplayControlValue,
    target: DDCTransportTarget,
    preparation: DDCBrightnessWritePreparation
  ) async throws -> DDCVCPFeatureWriteResult {
    let support = support
    return try await executor.setFeatureUsingBaseline(
      Self.brightnessFeatureCode,
      on: target,
      rawValue: { baseline in
        try support.rawBrightnessValue(
          for: value,
          baseline: baseline,
          display: preparation.display
        )
      },
      finalValidation: {
        let topology = try await support.discoverTopology(
          phase: "post-write-verification"
        )
        try support.requireUnchangedTopology(
          preparation.initialTopology,
          actual: topology,
          phase: "post-write-verification",
          display: preparation.display
        )
      }
    )
  }
}

private struct DDCBrightnessWritePreparation: Sendable {
  let initialTopology: [DisplayDescriptor]
  let display: DisplayDescriptor
  let session: DDCVCPReadSession
}
