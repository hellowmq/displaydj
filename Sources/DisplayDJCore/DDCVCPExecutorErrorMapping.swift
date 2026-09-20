extension DDCVCPExecutor {
  static func featureValue(
    from reply: DDCVCPGetFeatureReply,
    featureCode: UInt8,
    target: DDCTransportTarget,
    errorContext: DDCExecutionErrorContext = .read
  ) throws -> DDCVCPFeatureValue {
    switch reply {
    case .value(let value):
      return value
    case .unsupported:
      throw DDCMappedFailure(
        error: makeError(
          code: .unsupported,
          message: "The display reports that this DDC/CI VCP feature is unsupported.",
          reason: "ddc-feature-unsupported",
          featureCode: featureCode,
          target: target,
          errorContext: errorContext
        ),
        isRetryable: false
      )
    case .failure(_, let resultCode):
      throw DDCMappedFailure(
        error: makeError(
          code: .transportFailure,
          message: "The display returned a negative DDC/CI VCP result.",
          reason: "ddc-negative-result",
          featureCode: featureCode,
          target: target,
          errorContext: errorContext,
          details: ["resultCode": hex(resultCode)]
        ),
        isRetryable: false
      )
    case .null:
      throw DDCMappedFailure(
        error: makeError(
          code: .transportFailure,
          message: "The display returned a checksum-valid null DDC/CI reply.",
          reason: "ddc-null-reply",
          featureCode: featureCode,
          target: target,
          errorContext: errorContext
        ),
        isRetryable: true
      )
    }
  }

  static func mappedFailure(
    for error: any Error,
    featureCode: UInt8,
    target: DDCTransportTarget,
    errorContext: DDCExecutionErrorContext = .read
  ) -> DDCMappedFailure {
    if let failure = error as? DDCMappedFailure {
      return failure
    }
    if error is DDCAttemptDeadlineExceeded {
      return deadlineFailure(
        featureCode: featureCode,
        target: target,
        errorContext: errorContext
      )
    }
    if let unexpectedReply = error as? DDCUnexpectedSetReply {
      return unexpectedSetReplyFailure(
        unexpectedReply,
        featureCode: featureCode,
        target: target,
        errorContext: errorContext
      )
    }
    if let transportError = error as? DDCTransportError {
      return mappedTransportFailure(
        transportError,
        featureCode: featureCode,
        target: target,
        errorContext: errorContext
      )
    }
    if let codecError = error as? DDCVCPCodecError {
      return invalidReplyFailure(
        codecError,
        featureCode: featureCode,
        target: target,
        errorContext: errorContext
      )
    }
    return unexpectedFailure(
      error,
      featureCode: featureCode,
      target: target,
      errorContext: errorContext
    )
  }

  private static func deadlineFailure(
    featureCode: UInt8,
    target: DDCTransportTarget,
    errorContext: DDCExecutionErrorContext
  ) -> DDCMappedFailure {
    DDCMappedFailure(
      error: makeError(
        code: .timeout,
        message: "The DDC transport attempt exceeded its deadline.",
        reason: "attempt-timeout",
        featureCode: featureCode,
        target: target,
        errorContext: errorContext
      ),
      isRetryable: true
    )
  }

  private static func unexpectedSetReplyFailure(
    _ error: DDCUnexpectedSetReply,
    featureCode: UInt8,
    target: DDCTransportTarget,
    errorContext: DDCExecutionErrorContext
  ) -> DDCMappedFailure {
    DDCMappedFailure(
      error: makeError(
        code: .transportFailure,
        message: "The DDC transport returned unexpected bytes for a Set VCP request.",
        reason: "unexpected-set-reply",
        featureCode: featureCode,
        target: target,
        errorContext: errorContext,
        details: ["replyByteCount": String(error.byteCount)]
      ),
      isRetryable: false
    )
  }

  private static func invalidReplyFailure(
    _ error: DDCVCPCodecError,
    featureCode: UInt8,
    target: DDCTransportTarget,
    errorContext: DDCExecutionErrorContext
  ) -> DDCMappedFailure {
    let diagnostic = codecDiagnostic(for: error)
    return DDCMappedFailure(
      error: makeError(
        code: .transportFailure,
        message: "The display returned an invalid DDC/CI reply frame.",
        reason: "invalid-ddc-reply",
        featureCode: featureCode,
        target: target,
        errorContext: errorContext,
        details: ["codecError": diagnostic.name]
      ),
      isRetryable: diagnostic.isRetryable
    )
  }

  private static func unexpectedFailure(
    _ error: any Error,
    featureCode: UInt8,
    target: DDCTransportTarget,
    errorContext: DDCExecutionErrorContext
  ) -> DDCMappedFailure {
    DDCMappedFailure(
      error: makeError(
        code: .internalFailure,
        message: "The DDC transport failed with an unexpected error.",
        reason: "unexpected-ddc-error",
        featureCode: featureCode,
        target: target,
        errorContext: errorContext,
        details: ["underlyingError": String(describing: error)]
      ),
      isRetryable: false
    )
  }

  private static func mappedTransportFailure(
    _ error: DDCTransportError,
    featureCode: UInt8,
    target: DDCTransportTarget,
    errorContext: DDCExecutionErrorContext
  ) -> DDCMappedFailure {
    let mapping = transportMapping(for: error)
    return DDCMappedFailure(
      error: makeError(
        code: mapping.code,
        message: mapping.message,
        reason: mapping.reason,
        featureCode: featureCode,
        target: target,
        errorContext: errorContext,
        details: mapping.details
      ),
      isRetryable: mapping.isRetryable
    )
  }

  private static func transportMapping(
    for error: DDCTransportError
  ) -> DDCTransportFailureMapping {
    switch error {
    case .unavailable(let transportReason):
      DDCTransportFailureMapping(
        code: .backendUnavailable,
        message: "The DDC transport is unavailable for this display.",
        reason: "transport-unavailable",
        details: ["transportReason": transportReason],
        isRetryable: false
      )
    case .busy:
      DDCTransportFailureMapping(
        code: .busy,
        message: "The DDC transport resource is busy.",
        reason: "transport-busy",
        isRetryable: true
      )
    case .timedOut:
      DDCTransportFailureMapping(
        code: .timeout,
        message: "The DDC transport reported a timeout.",
        reason: "transport-timeout",
        isRetryable: true
      )
    case .noReply:
      DDCTransportFailureMapping(
        code: .transportFailure,
        message: "The display did not return a DDC/CI reply.",
        reason: "transport-no-reply",
        isRetryable: true
      )
    case .transientFailure(let operation, let status):
      DDCTransportFailureMapping(
        code: .transportFailure,
        message: "The DDC transport reported a transient failure.",
        reason: "transient-transport-failure",
        details: transportDetails(operation: operation, status: status),
        isRetryable: true
      )
    case .permanentFailure(let operation, let status):
      DDCTransportFailureMapping(
        code: .transportFailure,
        message: "The DDC transport reported a permanent failure.",
        reason: "permanent-transport-failure",
        details: transportDetails(operation: operation, status: status),
        isRetryable: false
      )
    }
  }

  private static func codecDiagnostic(
    for error: DDCVCPCodecError
  ) -> (name: String, isRetryable: Bool) {
    switch error {
    case .messageTooShort:
      ("message-too-short", true)
    case .unexpectedSourceAddress:
      ("unexpected-source-address", false)
    case .invalidLengthByte:
      ("invalid-length-byte", true)
    case .messageLengthMismatch:
      ("message-length-mismatch", true)
    case .checksumMismatch:
      ("checksum-mismatch", true)
    case .unexpectedBodyLength:
      ("unexpected-body-length", true)
    case .unexpectedOpcode:
      ("unexpected-opcode", false)
    case .featureCodeMismatch:
      ("feature-code-mismatch", false)
    }
  }

  private static func transportDetails(
    operation: String,
    status: Int32?
  ) -> [String: String] {
    var details = ["transportOperation": operation]
    if let status {
      details["transportStatus"] = String(status)
    }
    return details
  }

  private static func makeError(
    code: DisplayDJErrorCode,
    message: String,
    reason: String,
    featureCode: UInt8,
    target: DDCTransportTarget,
    errorContext: DDCExecutionErrorContext = .read,
    details: [String: String] = [:]
  ) -> DisplayDJError {
    var mergedDetails = errorContext.details
    for (key, value) in details {
      mergedDetails[key] = value
    }
    mergedDetails["featureCode"] = hex(featureCode)
    mergedDetails["reason"] = reason

    return DisplayDJError(
      code: code,
      message: message,
      operation: errorContext.operation,
      displayID: selector(for: target.display),
      backend: target.backend,
      details: mergedDetails
    )
  }

  static func verificationFailure(
    featureCode: UInt8,
    requestedValue: UInt16,
    verifiedValue: DDCVCPFeatureValue,
    target: DDCTransportTarget,
    operation: ControlOperation = .write
  ) -> DisplayDJError {
    let isRestoration = operation == .restore
    let errorContext = DDCExecutionErrorContext(
      operation: isRestoration ? .restore : .write,
      details: [
        "maximumValue": String(verifiedValue.maximumValue),
        "observedValue": String(verifiedValue.currentValue),
        "phase": isRestoration ? "restore-verification-read" : "verification-read",
        (isRestoration ? "restoredValue" : "requestedValue"): String(requestedValue),
        (isRestoration ? "restorationState" : "writeState"): "verification-mismatch",
      ]
    )
    return makeError(
      code: .verificationFailed,
      message: isRestoration
        ? "The DDC/CI VCP value did not match while restoring the original value."
        : "The DDC/CI VCP value did not match after the write completed.",
      reason: isRestoration
        ? "ddc-restoration-verification-mismatch"
        : "ddc-write-verification-mismatch",
      featureCode: featureCode,
      target: target,
      errorContext: errorContext
    )
  }

  static func finalized(
    _ error: DisplayDJError,
    attempts: Int,
    maximumAttempts: Int
  ) -> DisplayDJError {
    var details = error.details
    details["attempts"] = String(attempts)
    details["maximumAttempts"] = String(maximumAttempts)

    return DisplayDJError(
      code: error.code,
      message: error.message,
      operation: error.operation,
      displayID: error.displayID,
      backend: error.backend,
      details: details
    )
  }

  static func selector(for display: DisplayDescriptor) -> String {
    display.stableID ?? "runtime:\(display.runtimeID)"
  }

  private static func hex(_ byte: UInt8) -> String {
    let digits = String(byte, radix: 16, uppercase: true)
    return "0x" + String(repeating: "0", count: 2 - digits.count) + digits
  }
}

private struct DDCTransportFailureMapping {
  let code: DisplayDJErrorCode
  let message: String
  let reason: String
  let details: [String: String]
  let isRetryable: Bool

  init(
    code: DisplayDJErrorCode,
    message: String,
    reason: String,
    details: [String: String] = [:],
    isRetryable: Bool
  ) {
    self.code = code
    self.message = message
    self.reason = reason
    self.details = details
    self.isRetryable = isRetryable
  }
}
