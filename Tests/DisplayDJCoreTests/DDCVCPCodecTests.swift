import Testing

@testable import DisplayDJCore

@Test("Get VCP requests match the DDC/CI brightness fixture")
func getVCPRequestMatchesFixture() {
  let request = DDCVCPCodec.getFeatureRequest(featureCode: 0x10)

  #expect(request == [0x51, 0x82, 0x01, 0x10, 0xAC])
  #expect(
    xorChecksum(seed: 0x6E, bytes: request.dropLast())
      == request.last
  )
}

@Test("Set VCP requests encode UInt16 values in big-endian order")
func setVCPRequestMatchesFixtures() {
  #expect(
    DDCVCPCodec.setFeatureRequest(featureCode: 0x10, value: 50)
      == [0x51, 0x84, 0x03, 0x10, 0x00, 0x32, 0x9A]
  )
  #expect(
    DDCVCPCodec.setFeatureRequest(featureCode: 0x10, value: .max)
      == [0x51, 0x84, 0x03, 0x10, 0xFF, 0xFF, 0xA8]
  )
}

@Test("A valid Get VCP reply preserves raw maximum and current values")
func validGetVCPReplyParses() throws {
  let reply = try DDCVCPCodec.parseGetFeatureReply(
    successfulBrightnessReply,
    expectedFeatureCode: 0x10
  )

  #expect(
    reply
      == .value(
        DDCVCPFeatureValue(
          featureCode: 0x10,
          valueType: .setParameter,
          maximumValue: 100,
          currentValue: 50
        )
      )
  )
}

@Test("Reply checksum uses the implicit host destination byte")
func replyChecksumUsesHostDestination() {
  let payload = successfulBrightnessReply.dropLast()

  #expect(xorChecksum(seed: 0x50, bytes: payload) == 0xF2)
  #expect(xorChecksum(seed: 0x6F, bytes: payload) != 0xF2)
}

@Test("Unsupported and unknown result codes never become successful values")
func negativeGetVCPRepliesRemainExplicit() throws {
  let unsupported = responseMessage(
    body: [0x02, 0x01, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00]
  )
  let unknownFailure = responseMessage(
    body: [0x02, 0x7F, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00]
  )

  #expect(
    try DDCVCPCodec.parseGetFeatureReply(
      unsupported,
      expectedFeatureCode: 0x10
    ) == .unsupported(featureCode: 0x10)
  )
  #expect(
    try DDCVCPCodec.parseGetFeatureReply(
      unknownFailure,
      expectedFeatureCode: 0x10
    ) == .failure(featureCode: 0x10, resultCode: 0x7F)
  )
}

@Test("A checksum-valid DDC/CI null reply is distinct from malformed data")
func nullReplyParses() throws {
  let reply = try DDCVCPCodec.parseGetFeatureReply(
    [0x6E, 0x80, 0xBE],
    expectedFeatureCode: 0x10
  )

  #expect(reply == .null)
}

@Test("Unknown VCP value types remain explicit")
func unknownValueTypeRemainsExplicit() throws {
  let message = responseMessage(
    body: [0x02, 0x00, 0x10, 0x7F, 0x00, 0x64, 0x00, 0x32]
  )
  let reply = try DDCVCPCodec.parseGetFeatureReply(
    message,
    expectedFeatureCode: 0x10
  )

  #expect(
    reply
      == .value(
        DDCVCPFeatureValue(
          featureCode: 0x10,
          valueType: .unknown(0x7F),
          maximumValue: 100,
          currentValue: 50
        )
      )
  )
}

@Test("Every truncated reply prefix fails without an out-of-bounds access")
func truncatedReplyPrefixesFailSafely() {
  for byteCount in 0..<successfulBrightnessReply.count {
    let prefix = Array(successfulBrightnessReply.prefix(byteCount))
    let error = capturedCodecError(for: prefix)

    if byteCount < 3 {
      #expect(
        error
          == .messageTooShort(
            minimumByteCount: 3,
            actualByteCount: byteCount
          )
      )
    } else {
      #expect(
        error
          == .messageLengthMismatch(
            declaredBodyByteCount: 8,
            expectedByteCount: 11,
            actualByteCount: byteCount
          )
      )
    }
  }
}

@Test("Reply framing rejects source, length, and trailing-byte mismatches")
func replyFramingMismatchesFail() {
  var wrongSource = successfulBrightnessReply
  wrongSource[0] = 0x6F

  var invalidLengthFlag = successfulBrightnessReply
  invalidLengthFlag[1] = 0x08

  var trailingByte = successfulBrightnessReply
  trailingByte.append(0x00)

  #expect(
    capturedCodecError(for: wrongSource)
      == .unexpectedSourceAddress(expected: 0x6E, actual: 0x6F)
  )
  #expect(
    capturedCodecError(for: invalidLengthFlag)
      == .invalidLengthByte(0x08)
  )
  #expect(
    capturedCodecError(for: trailingByte)
      == .messageLengthMismatch(
        declaredBodyByteCount: 8,
        expectedByteCount: 11,
        actualByteCount: 12
      )
  )
}

@Test("Reply parser verifies checksum, opcode, body length, and feature echo")
func replySemanticMismatchesFail() {
  var badChecksum = successfulBrightnessReply
  badChecksum[badChecksum.count - 1] ^= 0x01

  let wrongOpcode = responseMessage(
    body: [0x03, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32]
  )
  let wrongFeature = responseMessage(
    body: [0x02, 0x00, 0x12, 0x00, 0x00, 0x64, 0x00, 0x32]
  )
  let shortBody = responseMessage(
    body: [0x02, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00]
  )

  #expect(
    capturedCodecError(for: badChecksum)
      == .checksumMismatch(expected: 0xF2, actual: 0xF3)
  )
  #expect(
    capturedCodecError(for: wrongOpcode)
      == .unexpectedOpcode(expected: 0x02, actual: 0x03)
  )
  #expect(
    capturedCodecError(for: wrongFeature)
      == .featureCodeMismatch(expected: 0x10, actual: 0x12)
  )
  #expect(
    capturedCodecError(for: shortBody)
      == .unexpectedBodyLength(expected: 8, actual: 7)
  )
}

private let successfulBrightnessReply: [UInt8] = [
  0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2,
]

private func responseMessage(body: [UInt8]) -> [UInt8] {
  precondition(body.count <= 0x7F)
  var message = [UInt8(0x6E), 0x80 | UInt8(body.count)]
  message.append(contentsOf: body)
  message.append(xorChecksum(seed: 0x50, bytes: message))
  return message
}

private func xorChecksum<Bytes: Sequence>(
  seed: UInt8,
  bytes: Bytes
) -> UInt8 where Bytes.Element == UInt8 {
  bytes.reduce(seed) { partialChecksum, byte in
    partialChecksum ^ byte
  }
}

private func capturedCodecError(
  for message: [UInt8],
  expectedFeatureCode: UInt8 = 0x10
) -> DDCVCPCodecError? {
  do {
    _ = try DDCVCPCodec.parseGetFeatureReply(
      message,
      expectedFeatureCode: expectedFeatureCode
    )
    Issue.record("Expected DDCVCPCodecError, but parsing succeeded.")
  } catch let error as DDCVCPCodecError {
    return error
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
  return nil
}
