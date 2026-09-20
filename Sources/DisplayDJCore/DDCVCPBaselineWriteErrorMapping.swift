extension DDCVCPExecutor {
  static func requireCompatibleReadBack(
    _ verifiedValue: DDCVCPFeatureValue,
    baselineValue: DDCVCPFeatureValue,
    requestedRawValue: UInt16,
    target: DDCTransportTarget,
    operation: ControlOperation
  ) throws {
    guard
      verifiedValue.featureCode == baselineValue.featureCode,
      verifiedValue.valueType == baselineValue.valueType,
      verifiedValue.maximumValue == baselineValue.maximumValue
    else {
      throw incompatibleReadBackFailure(
        verifiedValue,
        baselineValue: baselineValue,
        requestedRawValue: requestedRawValue,
        target: target,
        operation: operation
      )
    }
  }

  static func failureWithVerifiedRestoration(
    _ error: DisplayDJError,
    baselineValue: UInt16,
    requestedRawValue: UInt16
  ) -> DisplayDJError {
    var details = error.details
    details["baselineValue"] = String(baselineValue)
    details["requestedValue"] = String(requestedRawValue)
    details["restorationState"] = "verified"
    details["restoredValue"] = String(baselineValue)

    return DisplayDJError(
      code: error.code,
      message: error.message,
      operation: error.operation,
      displayID: error.displayID,
      backend: error.backend,
      details: details
    )
  }

  static func restorationFailure(
    _ error: DisplayDJError,
    primaryError: any Error,
    baselineValue: UInt16,
    requestedRawValue: UInt16
  ) -> DisplayDJError {
    var details = error.details
    details["baselineValue"] = String(baselineValue)
    details["requestedValue"] = String(requestedRawValue)
    details["restorationState"] = "unknown"
    addPrimaryFailure(primaryError, to: &details)

    return DisplayDJError(
      code: error.code,
      message: error.message,
      operation: .restore,
      displayID: error.displayID,
      backend: error.backend,
      details: details
    )
  }

  static func unexpectedWriteFailure(
    _ error: any Error,
    target: DDCTransportTarget,
    baselineValue: UInt16,
    requestedRawValue: UInt16,
    restorationState: String
  ) -> DisplayDJError {
    DisplayDJError(
      code: .internalFailure,
      message: "The DDC brightness write failed unexpectedly.",
      operation: .write,
      displayID: selector(for: target.display),
      backend: target.backend,
      details: [
        "baselineValue": String(baselineValue),
        "phase": "write-transaction",
        "reason": "unexpected-write-transaction-error",
        "requestedValue": String(requestedRawValue),
        "restorationState": restorationState,
        "underlyingError": String(describing: error),
      ]
    )
  }

  static func unexpectedRestorationFailure(
    _ error: any Error,
    target: DDCTransportTarget,
    baselineValue: UInt16,
    requestedRawValue: UInt16
  ) -> DisplayDJError {
    DisplayDJError(
      code: .internalFailure,
      message: "Restoring the original DDC/CI VCP value failed unexpectedly.",
      operation: .restore,
      displayID: selector(for: target.display),
      backend: target.backend,
      details: [
        "baselineValue": String(baselineValue),
        "phase": "restore-transaction",
        "reason": "unexpected-restoration-error",
        "requestedValue": String(requestedRawValue),
        "restorationState": "unknown",
        "underlyingError": String(describing: error),
      ]
    )
  }

  private static func incompatibleReadBackFailure(
    _ verifiedValue: DDCVCPFeatureValue,
    baselineValue: DDCVCPFeatureValue,
    requestedRawValue: UInt16,
    target: DDCTransportTarget,
    operation: ControlOperation
  ) -> DisplayDJError {
    let isRestoration = operation == .restore
    var details = [
      "baselineMaximumValue": String(baselineValue.maximumValue),
      "baselineValueType": baselineValueTypeDescription(baselineValue.valueType),
      "featureCode": baselineHex(baselineValue.featureCode),
      "observedMaximumValue": String(verifiedValue.maximumValue),
      "observedValue": String(verifiedValue.currentValue),
      "observedValueType": baselineValueTypeDescription(verifiedValue.valueType),
      "phase": isRestoration ? "restore-verification-read" : "verification-read",
      "reason": isRestoration
        ? "ddc-restoration-metadata-mismatch"
        : "ddc-write-metadata-mismatch",
    ]
    details[isRestoration ? "restoredValue" : "requestedValue"] = String(
      requestedRawValue
    )
    details[isRestoration ? "restorationState" : "writeState"] =
      "verification-mismatch"

    return DisplayDJError(
      code: .verificationFailed,
      message: isRestoration
        ? "The DDC/CI metadata changed while restoring the original value."
        : "The DDC/CI metadata changed after the write completed.",
      operation: isRestoration ? .restore : .write,
      displayID: selector(for: target.display),
      backend: target.backend,
      details: details
    )
  }

  private static func addPrimaryFailure(
    _ error: any Error,
    to details: inout [String: String]
  ) {
    if let error = error as? DisplayDJError {
      details["primaryCode"] = error.code.rawValue
      details["primaryOperation"] = error.operation?.rawValue ?? "unknown"
      details["primaryPhase"] = error.details["phase"] ?? "unknown"
      details["primaryReason"] = error.details["reason"] ?? "unknown"
    } else if error is CancellationError {
      details["primaryCode"] = "cancelled"
      details["primaryOperation"] = ControlOperation.write.rawValue
    } else {
      details["primaryCode"] = "unexpected-error"
      details["primaryOperation"] = ControlOperation.write.rawValue
      details["primaryUnderlyingError"] = String(describing: error)
    }
  }

  private static func baselineValueTypeDescription(
    _ valueType: DDCVCPValueType
  ) -> String {
    switch valueType {
    case .setParameter:
      "set-parameter"
    case .momentary:
      "momentary"
    case .unknown(let code):
      "unknown-\(baselineHex(code))"
    }
  }

  private static func baselineHex(_ byte: UInt8) -> String {
    let digits = String(byte, radix: 16, uppercase: true)
    return "0x" + String(repeating: "0", count: 2 - digits.count) + digits
  }
}
