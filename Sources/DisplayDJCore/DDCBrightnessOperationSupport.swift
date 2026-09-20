struct DDCBrightnessOperationSupport: Sendable {
  private static let featureCode: UInt8 = 0x10

  private let discovery: any DisplayDiscovering
  private let selectorResolver: DisplaySelectorResolver
  private let backend: BackendKind
  private let operation: ControlOperation

  init(
    discovery: any DisplayDiscovering,
    selectorResolver: DisplaySelectorResolver = DisplaySelectorResolver(),
    backend: BackendKind,
    operation: ControlOperation
  ) {
    precondition(operation == .read || operation == .write)
    self.discovery = discovery
    self.selectorResolver = selectorResolver
    self.backend = backend
    self.operation = operation
  }

  func discoverTopology(
    phase: String
  ) async throws -> [DisplayDescriptor] {
    do {
      let displays = try await discovery.discoverDisplays()
      try Task.checkCancellation()
      return displays.sorted { $0.runtimeID < $1.runtimeID }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as DisplayDJError {
      try Task.checkCancellation()
      throw contextualizedError(error, phase: phase)
    } catch {
      try Task.checkCancellation()
      throw DisplayDJError(
        code: .internalFailure,
        message: [
          "Display discovery failed unexpectedly during",
          "a DDC brightness \(operation.rawValue).",
        ].joined(separator: " "),
        operation: operation,
        backend: backend,
        details: [
          "phase": phase,
          "reason": "unexpected-display-discovery-error",
          "underlyingError": String(describing: error),
        ]
      )
    }
  }

  func selectedDisplay(
    _ selector: DisplaySelector,
    among displays: [DisplayDescriptor]
  ) throws -> DisplayDescriptor {
    let matches: [DisplayDescriptor]
    do {
      matches = try selectorResolver.resolve(selector, among: displays)
    } catch let error as DisplayDJError {
      throw contextualizedError(error, phase: "selection")
    } catch {
      throw DisplayDJError(
        code: .internalFailure,
        message: [
          "Display selection failed unexpectedly during",
          "a DDC brightness \(operation.rawValue).",
        ].joined(separator: " "),
        operation: operation,
        displayID: selectorDescription(selector),
        backend: backend,
        details: [
          "phase": "selection",
          "reason": "unexpected-display-selection-error",
          "underlyingError": String(describing: error),
        ]
      )
    }

    guard let display = matches.first else {
      throw selectionError(
        code: .displayNotFound,
        message: "No online display is available for a DDC brightness \(operation.rawValue).",
        selector: selector,
        matches: matches
      )
    }
    guard matches.count == 1 else {
      throw selectionError(
        code: .ambiguousDisplay,
        message: "A DDC brightness \(operation.rawValue) requires exactly one display.",
        selector: selector,
        matches: matches
      )
    }
    return display
  }

  func requireUnchangedTopology(
    _ expected: [DisplayDescriptor],
    actual: [DisplayDescriptor],
    phase: String,
    display: DisplayDescriptor
  ) throws {
    guard expected == actual else {
      throw DisplayDJError(
        code: .conflict,
        message: "The display topology changed during a DDC brightness \(operation.rawValue).",
        operation: operation,
        displayID: display.stableID ?? "runtime:\(display.runtimeID)",
        backend: backend,
        details: [
          "after": topologyDescription(actual),
          "before": topologyDescription(expected),
          "phase": phase,
          "reason": "display-topology-changed",
        ]
      )
    }
  }

  func brightnessValue(
    from rawValue: DDCVCPFeatureValue,
    display: DisplayDescriptor
  ) throws -> DisplayControlValue {
    try requireValidBrightness(rawValue, display: display)
    return try DisplayControlValue(
      normalized: Double(rawValue.currentValue) / Double(rawValue.maximumValue)
    )
  }

  func rawBrightnessValue(
    for value: DisplayControlValue,
    baseline: DDCVCPFeatureValue,
    display: DisplayDescriptor
  ) throws -> UInt16 {
    try requireValidBrightness(baseline, display: display)
    let scaled = value.normalized * Double(baseline.maximumValue)
    let rounded = Int(scaled.rounded(.toNearestOrAwayFromZero))
    return UInt16(clamping: rounded)
  }

  private func requireValidBrightness(
    _ rawValue: DDCVCPFeatureValue,
    display: DisplayDescriptor
  ) throws {
    guard
      rawValue.featureCode == Self.featureCode,
      rawValue.valueType == .setParameter,
      rawValue.maximumValue > 0,
      rawValue.currentValue <= rawValue.maximumValue
    else {
      throw invalidBrightnessValue(rawValue, display: display)
    }
  }

  private func contextualizedError(
    _ error: DisplayDJError,
    phase: String
  ) -> DisplayDJError {
    var details = error.details
    details["phase"] = phase

    return DisplayDJError(
      code: error.code,
      message: error.message,
      operation: operation,
      displayID: error.displayID,
      backend: backend,
      details: details
    )
  }

  private func selectionError(
    code: DisplayDJErrorCode,
    message: String,
    selector: DisplaySelector,
    matches: [DisplayDescriptor]
  ) -> DisplayDJError {
    DisplayDJError(
      code: code,
      message: message,
      operation: operation,
      displayID: selectorDescription(selector),
      backend: backend,
      details: [
        "matchedDisplayCount": String(matches.count),
        "phase": "selection",
        "runtimeIDs": matches.map(\.runtimeID).sorted().map(String.init).joined(separator: ","),
      ]
    )
  }

  private func invalidBrightnessValue(
    _ rawValue: DDCVCPFeatureValue,
    display: DisplayDescriptor
  ) -> DisplayDJError {
    DisplayDJError(
      code: .transportFailure,
      message: "The display returned an invalid DDC/CI brightness value.",
      operation: operation,
      displayID: display.stableID ?? "runtime:\(display.runtimeID)",
      backend: backend,
      details: [
        "currentValue": String(rawValue.currentValue),
        "featureCode": hex(rawValue.featureCode),
        "maximumValue": String(rawValue.maximumValue),
        "reason": "invalid-brightness-vcp-value",
        "valueType": valueTypeDescription(rawValue.valueType),
      ]
    )
  }

  private func topologyDescription(
    _ displays: [DisplayDescriptor]
  ) -> String {
    displays.map { display in
      [
        "runtime=\(display.runtimeID)",
        "stable=\(display.stableID ?? "nil")",
        "vendor=\(optionalDescription(display.vendorID))",
        "product=\(optionalDescription(display.productID))",
        "serial=\(optionalDescription(display.serialNumber))",
        "builtIn=\(display.isBuiltIn)",
        "virtual=\(optionalDescription(display.isVirtual))",
        "virtualSource=\(display.virtualDetectionSource.rawValue)",
        "mirrored=\(display.isMirrored)",
        "mirrorSource=\(optionalDescription(display.mirrorSourceRuntimeID))",
        "name=\(String(reflecting: display.name))",
      ].joined(separator: ",")
    }.joined(separator: ";")
  }

  private func selectorDescription(_ selector: DisplaySelector) -> String {
    switch selector {
    case .runtimeID(let runtimeID):
      "runtime:\(runtimeID)"
    case .stableID(let stableID):
      stableID
    case .all:
      "all"
    case .builtIn:
      "built-in"
    case .external:
      "external"
    }
  }

  private func valueTypeDescription(_ valueType: DDCVCPValueType) -> String {
    switch valueType {
    case .setParameter:
      "set-parameter"
    case .momentary:
      "momentary"
    case .unknown(let code):
      "unknown-\(hex(code))"
    }
  }

  private func optionalDescription<Value>(_ value: Value?) -> String {
    value.map { String(describing: $0) } ?? "nil"
  }

  private func hex(_ byte: UInt8) -> String {
    let digits = String(byte, radix: 16, uppercase: true)
    return "0x" + String(repeating: "0", count: 2 - digits.count) + digits
  }
}
