/// Pure DDC/CI VCP framing shared by future architecture-specific transports.
///
/// Encoded requests include the host source byte (`0x51`) and checksum, but not
/// the I2C write address (`0x6E`). Parsed replies begin with the display source
/// byte (`0x6E`) and do not include the I2C read address (`0x6F`).
enum DDCVCPCodec {
  private static let i2cWriteAddress: UInt8 = 0x6E
  private static let hostSourceAddress: UInt8 = 0x51
  private static let replyChecksumSeed: UInt8 = 0x50
  private static let lengthFlag: UInt8 = 0x80
  private static let bodyLengthMask: UInt8 = 0x7F
  private static let displaySourceAddress: UInt8 = 0x6E
  private static let getFeatureOpcode: UInt8 = 0x01
  private static let getFeatureReplyOpcode: UInt8 = 0x02
  private static let setFeatureOpcode: UInt8 = 0x03
  private static let getFeatureReplyBodyByteCount = 8
  private static let minimumMessageByteCount = 3

  static func getFeatureRequest(featureCode: UInt8) -> [UInt8] {
    request(opcode: getFeatureOpcode, parameters: [featureCode])
  }

  static func setFeatureRequest(
    featureCode: UInt8,
    value: UInt16
  ) -> [UInt8] {
    request(
      opcode: setFeatureOpcode,
      parameters: [
        featureCode,
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value),
      ]
    )
  }

  /// Parses one exact reply frame. Transport-owned buffer padding must be
  /// removed before calling this function.
  static func parseGetFeatureReply(
    _ message: [UInt8],
    expectedFeatureCode: UInt8
  ) throws -> DDCVCPGetFeatureReply {
    let bodyByteCount = try validateReplyFrame(message)
    guard bodyByteCount != 0 else {
      return .null
    }
    return try parseFeatureReply(
      message,
      bodyByteCount: bodyByteCount,
      expectedFeatureCode: expectedFeatureCode
    )
  }

  private static func validateReplyFrame(
    _ message: [UInt8]
  ) throws -> Int {
    guard message.count >= minimumMessageByteCount else {
      throw DDCVCPCodecError.messageTooShort(
        minimumByteCount: minimumMessageByteCount,
        actualByteCount: message.count
      )
    }
    guard message[0] == displaySourceAddress else {
      throw DDCVCPCodecError.unexpectedSourceAddress(
        expected: displaySourceAddress,
        actual: message[0]
      )
    }

    let bodyByteCount = try replyBodyByteCount(from: message[1])
    try validateReplyLength(message, bodyByteCount: bodyByteCount)
    try validateReplyChecksum(message)
    return bodyByteCount
  }

  private static func replyBodyByteCount(
    from lengthByte: UInt8
  ) throws -> Int {
    guard (lengthByte & lengthFlag) == lengthFlag else {
      throw DDCVCPCodecError.invalidLengthByte(lengthByte)
    }
    return Int(lengthByte & bodyLengthMask)
  }

  private static func validateReplyLength(
    _ message: [UInt8],
    bodyByteCount: Int
  ) throws {
    let expectedMessageByteCount = bodyByteCount + minimumMessageByteCount
    guard message.count == expectedMessageByteCount else {
      throw DDCVCPCodecError.messageLengthMismatch(
        declaredBodyByteCount: bodyByteCount,
        expectedByteCount: expectedMessageByteCount,
        actualByteCount: message.count
      )
    }
  }

  private static func validateReplyChecksum(
    _ message: [UInt8]
  ) throws {
    let receivedChecksum = message[message.count - 1]
    let calculatedChecksum = checksum(
      seed: replyChecksumSeed,
      bytes: message.dropLast()
    )
    guard receivedChecksum == calculatedChecksum else {
      throw DDCVCPCodecError.checksumMismatch(
        expected: calculatedChecksum,
        actual: receivedChecksum
      )
    }
  }

  private static func parseFeatureReply(
    _ message: [UInt8],
    bodyByteCount: Int,
    expectedFeatureCode: UInt8
  ) throws -> DDCVCPGetFeatureReply {
    try validateFeatureReplyHeader(
      message,
      bodyByteCount: bodyByteCount,
      expectedFeatureCode: expectedFeatureCode
    )

    let featureCode = message[4]
    let resultCode = message[3]
    if resultCode == 0x01 {
      return .unsupported(featureCode: featureCode)
    }
    guard resultCode == 0x00 else {
      return .failure(featureCode: featureCode, resultCode: resultCode)
    }

    return .value(featureValue(from: message))
  }

  private static func validateFeatureReplyHeader(
    _ message: [UInt8],
    bodyByteCount: Int,
    expectedFeatureCode: UInt8
  ) throws {
    guard bodyByteCount == getFeatureReplyBodyByteCount else {
      throw DDCVCPCodecError.unexpectedBodyLength(
        expected: getFeatureReplyBodyByteCount,
        actual: bodyByteCount
      )
    }
    guard message[2] == getFeatureReplyOpcode else {
      throw DDCVCPCodecError.unexpectedOpcode(
        expected: getFeatureReplyOpcode,
        actual: message[2]
      )
    }
    guard message[4] == expectedFeatureCode else {
      throw DDCVCPCodecError.featureCodeMismatch(
        expected: expectedFeatureCode,
        actual: message[4]
      )
    }
  }

  private static func featureValue(
    from message: [UInt8]
  ) -> DDCVCPFeatureValue {
    DDCVCPFeatureValue(
      featureCode: message[4],
      valueType: DDCVCPValueType(code: message[5]),
      maximumValue: uint16(highByte: message[6], lowByte: message[7]),
      currentValue: uint16(highByte: message[8], lowByte: message[9])
    )
  }

  private static func request(
    opcode: UInt8,
    parameters: [UInt8]
  ) -> [UInt8] {
    let bodyByteCount = 1 + parameters.count
    precondition(bodyByteCount <= Int(bodyLengthMask))

    var message = [
      hostSourceAddress,
      lengthFlag | UInt8(bodyByteCount),
      opcode,
    ]
    message.append(contentsOf: parameters)
    message.append(checksum(seed: i2cWriteAddress, bytes: message))
    return message
  }

  private static func checksum<Bytes: Sequence>(
    seed: UInt8,
    bytes: Bytes
  ) -> UInt8 where Bytes.Element == UInt8 {
    bytes.reduce(seed) { partialChecksum, byte in
      partialChecksum ^ byte
    }
  }

  private static func uint16(
    highByte: UInt8,
    lowByte: UInt8
  ) -> UInt16 {
    (UInt16(highByte) << 8) | UInt16(lowByte)
  }
}

enum DDCVCPGetFeatureReply: Equatable, Sendable {
  case value(DDCVCPFeatureValue)
  case unsupported(featureCode: UInt8)
  case failure(featureCode: UInt8, resultCode: UInt8)
  case null
}

struct DDCVCPFeatureValue: Equatable, Sendable {
  let featureCode: UInt8
  let valueType: DDCVCPValueType
  let maximumValue: UInt16
  let currentValue: UInt16
}

enum DDCVCPValueType: Equatable, Sendable {
  case setParameter
  case momentary
  case unknown(UInt8)

  init(code: UInt8) {
    switch code {
    case 0x00:
      self = .setParameter
    case 0x01:
      self = .momentary
    default:
      self = .unknown(code)
    }
  }
}

enum DDCVCPCodecError: Error, Equatable, Sendable {
  case messageTooShort(minimumByteCount: Int, actualByteCount: Int)
  case unexpectedSourceAddress(expected: UInt8, actual: UInt8)
  case invalidLengthByte(UInt8)
  case messageLengthMismatch(
    declaredBodyByteCount: Int,
    expectedByteCount: Int,
    actualByteCount: Int
  )
  case checksumMismatch(expected: UInt8, actual: UInt8)
  case unexpectedBodyLength(expected: Int, actual: Int)
  case unexpectedOpcode(expected: UInt8, actual: UInt8)
  case featureCodeMismatch(expected: UInt8, actual: UInt8)
}
