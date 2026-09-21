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
      operation: .write,
      featureCode: featureCode
    )
    self.backend = backend
    self.serviceMatcher = serviceMatcher
    self.executor = executor
  }

  func write(
    _ value: DisplayControlValue,
    to selector: DisplaySelector,
    relativeDelta: Double? = nil
  ) async throws -> ControlWriteResult {
    let preparation = try await prepareWrite(to: selector)
    let target = try await preparation.session.transportTarget(
      featureCode,
      for: preparation.display,
      operation: .write
    )
    let rawResult = try await performWrite(
      value,
      target: target,
      preparation: preparation,
      relativeDelta: relativeDelta
    )

    return ControlWriteResult(
      display: preparation.display,
      backend: backend,
      control: control,
      requestedValue: relativeDelta == nil ? value : try DisplayControlValue(normalized: Double(rawResult.requestedRawValue) / Double(rawResult.baselineValue.maximumValue)),
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
    preparation: DDCBrightnessWritePreparation,
    relativeDelta: Double?
  ) async throws -> DDCVCPFeatureWriteResult {
    let support = support
    return try await executor.setFeatureUsingBaseline(
      featureCode,
      on: target,
      rawValue: { baseline in
        let requested: DisplayControlValue
        if let relativeDelta {
          let current = try support.brightnessValue(from: baseline, display: preparation.display)
          requested = try DisplayControlValue(normalized: min(1, max(0, current.normalized + relativeDelta)))
        } else {
          requested = value
        }
        return try support.rawBrightnessValue(
          for: requested,
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
