// Portions of this Apple Silicon DDC packet adapter are adapted from
// MonitorControl. Copyright © MonitorControl contributors. Licensed under the
// MIT License; see License.txt in the repository root.

import CoreFoundation
import Dispatch
import Foundation
import IOKit

private struct AppleSiliconIOAVRequest {
  let packet: [UInt8]
  let replyCapacity: Int
}

/// An Apple Silicon DDC transport for exact Get and Set VCP frames. Get uses a
/// two-write compatibility handshake before its reply read; Set writes its frame
/// `writeFrameCount` times and returns an empty response. Retry, escalation, and
/// read-back policy remain the executor's responsibility. Production hardware
/// calls must be hosted by a killable child process until native-call timeout
/// bounds are independently enforced.
struct AppleSiliconDDCTransport: DDCTransport {
  private static let ddcChipAddress: UInt32 = 0x37
  private static let ddcDataAddress: UInt32 = 0x51
  private static let ddcReadOffset: UInt32 = 0
  private static let ddcWriteAddress: UInt8 = 0x6E
  private static let hostSourceAddress: UInt8 = 0x51
  private static let lengthFlag: UInt8 = 0x80
  private static let bodyLengthMask: UInt8 = 0x7F
  private static let getFeatureLengthByte: UInt8 = 0x82
  private static let getFeatureOpcode: UInt8 = 0x01
  private static let setFeatureLengthByte: UInt8 = 0x84
  private static let setFeatureOpcode: UInt8 = 0x03
  private static let minimumReplyByteCount = 3
  /// DDC's seven-bit body length plus source, length, and checksum bytes.
  private static let maximumReplyByteCount = 130
  /// Separates consecutive copies of one request frame. Verified against a
  /// display that ignores an isolated Set frame at this spacing.
  private static let repeatedFrameSpacing: TimeInterval = 0.05

  private let functions: AppleSiliconIOAVFunctionTable
  private let serviceResolver: any AppleSiliconDDCServiceResolving
  private let replyScheduler: @Sendable (TimeInterval) async -> Void

  /// Retains the dlopen handle behind `functions` for the transport lifetime.
  private let symbolOwner: AppleSiliconIOAVLibrary?

  static func current() throws -> AppleSiliconDDCTransport {
    #if arch(arm64)
      do {
        let library = try AppleSiliconIOAVLibrary.open()
        return AppleSiliconDDCTransport(
          functions: library.functions,
          serviceResolver: IOKitAppleSiliconDDCServiceResolver(),
          symbolOwner: library
        )
      } catch let error as AppleSiliconIOAVLibraryError {
        throw DDCTransportError.unavailable(reason: error.transportReason)
      }
    #else
      throw DDCTransportError.unavailable(
        reason: AppleSiliconIOAVLibraryError.unsupportedArchitecture.transportReason
      )
    #endif
  }

  init(
    functions: AppleSiliconIOAVFunctionTable,
    serviceResolver: any AppleSiliconDDCServiceResolving,
    symbolOwner: AppleSiliconIOAVLibrary? = nil,
    replyScheduler: @escaping @Sendable (TimeInterval) async -> Void = { delay in
      await AppleSiliconDDCTransport.wait(for: delay)
    }
  ) {
    self.functions = functions
    self.serviceResolver = serviceResolver
    self.symbolOwner = symbolOwner
    self.replyScheduler = replyScheduler
  }

  private static func wait(for delay: TimeInterval) async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).asyncAfter(
        deadline: .now() + delay
      ) {
        continuation.resume()
      }
    }
  }

  func exchange(
    _ request: DDCTransportRequest,
    on target: DDCTransportTarget
  ) async throws -> DDCTransportResponse {
    try Self.validate(target: target)
    let ioavRequest = try Self.ioavRequest(for: request)
    try Task.checkCancellation()

    let registryService = try serviceResolver.resolve(target.service)
    try Task.checkCancellation()
    let unmanagedIOAVService = try createIOAVService(
      for: registryService.rawValue
    )
    let ioavService = unmanagedIOAVService.takeUnretainedValue()
    defer { unmanagedIOAVService.release() }
    try Task.checkCancellation()

    // A repeated frame is never split by a cancellation check: the copies are one
    // indivisible bus transaction, and stopping between them would leave exactly
    // the half-applied Set that the repeat exists to avoid.
    for frame in 1...request.writeFrameCount {
      if frame > 1 {
        await replyScheduler(Self.repeatedFrameSpacing)
      }
      try write(ioavRequest.packet, to: ioavService)
    }
    guard ioavRequest.replyCapacity > 0 else {
      try Task.checkCancellation()
      return DDCTransportResponse(exactFrame: [])
    }

    // Some displays require a Get compatibility handshake: the first I2C
    // write primes the bus and the second triggers the request after 10 ms.
    // A Set reaches its own repeat through `writeFrameCount` instead, so that an
    // unverified Set escalates only when the executor asks it to.
    await replyScheduler(0.01)
    try write(ioavRequest.packet, to: ioavService)

    // Once a Get request is sent, finish the bounded reply delay and drain one
    // read before observing cancellation. Otherwise a stale reply could be
    // consumed by the next exchange on the same serialized transport resource.
    await replyScheduler(request.replyDelay)
    let reply = try read(
      capacity: ioavRequest.replyCapacity,
      from: ioavService
    )
    try Task.checkCancellation()

    return DDCTransportResponse(
      exactFrame: try Self.exactReplyFrame(from: reply)
    )
  }

  private func createIOAVService(
    for registryService: io_service_t
  ) throws -> Unmanaged<CFTypeRef> {
    guard
      let ioavService = functions.createWithService(
        kCFAllocatorDefault,
        registryService
      )
    else {
      throw DDCTransportError.unavailable(
        reason: "IOAVServiceCreateWithService returned no service for the associated DCP proxy."
      )
    }
    return ioavService
  }

  private func write(
    _ bytes: [UInt8],
    to service: CFTypeRef
  ) throws {
    var bytes = bytes
    let status = bytes.withUnsafeMutableBytes { buffer in
      functions.writeI2C(
        service,
        Self.ddcChipAddress,
        Self.ddcDataAddress,
        buffer.baseAddress,
        UInt32(buffer.count)
      )
    }
    try Self.checkStatus(
      status,
      operation: AppleSiliconIOAVABI.writeI2CSymbol
    )
  }

  private func read(
    capacity: Int,
    from service: CFTypeRef
  ) throws -> [UInt8] {
    var reply = [UInt8](repeating: 0, count: capacity)
    let status = reply.withUnsafeMutableBytes { buffer in
      functions.readI2C(
        service,
        Self.ddcChipAddress,
        Self.ddcReadOffset,
        buffer.baseAddress,
        UInt32(buffer.count)
      )
    }
    try Self.checkStatus(
      status,
      operation: AppleSiliconIOAVABI.readI2CSymbol
    )
    return reply
  }

}

extension AppleSiliconDDCTransport {
  fileprivate static func validate(
    target: DDCTransportTarget
  ) throws {
    guard target.backend == .appleSiliconDDC else {
      throw DDCTransportError.unavailable(
        reason: "The Apple Silicon DDC transport received a non-Apple-Silicon target."
      )
    }
    guard target.serializationKey.backend == .appleSiliconDDC else {
      throw DDCTransportError.permanentFailure(
        operation: "validate-serialization-key",
        status: nil
      )
    }
    guard target.service.serviceClass == "DCPAVServiceProxy" else {
      throw DDCTransportError.unavailable(
        reason: "The Apple Silicon DDC target is not a DCPAVServiceProxy service."
      )
    }
    guard target.service.registryEntryID != 0 else {
      throw DDCTransportError.unavailable(
        reason: "The Apple Silicon DDC target has a zero registry entry ID."
      )
    }
  }

  /// Converts a transport-neutral Get or Set VCP frame into the IOAV packet
  /// shape used by MonitorControl. IOAV receives 0x51 separately as the data
  /// address. Get omits that byte from its checksum seed; Set retains it.
  private static func ioavRequest(
    for request: DDCTransportRequest
  ) throws -> AppleSiliconIOAVRequest {
    if isGetRequest(request.logicalFrame) {
      return try ioavGetRequest(for: request)
    }

    if isSetRequest(request.logicalFrame) {
      return try ioavSetRequest(for: request)
    }

    throw DDCTransportError.permanentFailure(
      operation: "validate-supported-vcp-request",
      status: nil
    )
  }

  private static func isGetRequest(_ frame: [UInt8]) -> Bool {
    frame.count == 5
      && frame[0] == hostSourceAddress
      && frame[1] == getFeatureLengthByte
      && frame[2] == getFeatureOpcode
  }

  private static func isSetRequest(_ frame: [UInt8]) -> Bool {
    frame.count == 7
      && frame[0] == hostSourceAddress
      && frame[1] == setFeatureLengthByte
      && frame[2] == setFeatureOpcode
  }

  private static func ioavGetRequest(
    for request: DDCTransportRequest
  ) throws -> AppleSiliconIOAVRequest {
    guard
      request.replyCapacity >= minimumReplyByteCount,
      request.replyCapacity <= maximumReplyByteCount
    else {
      throw DDCTransportError.permanentFailure(
        operation: "validate-get-request",
        status: nil
      )
    }
    try validateLogicalChecksum(
      request.logicalFrame,
      operation: "validate-get-request-checksum"
    )

    var packet = Array(request.logicalFrame.dropFirst())
    packet[packet.count - 1] = checksum(
      seed: ddcWriteAddress,
      bytes: packet.dropLast()
    )
    return AppleSiliconIOAVRequest(
      packet: packet,
      replyCapacity: request.replyCapacity
    )
  }

  private static func ioavSetRequest(
    for request: DDCTransportRequest
  ) throws -> AppleSiliconIOAVRequest {
    guard request.replyCapacity == 0 else {
      throw DDCTransportError.permanentFailure(
        operation: "validate-set-request",
        status: nil
      )
    }
    try validateLogicalChecksum(
      request.logicalFrame,
      operation: "validate-set-request-checksum"
    )

    var packet = Array(request.logicalFrame.dropFirst())
    packet[packet.count - 1] = checksum(
      seed: ddcWriteAddress ^ hostSourceAddress,
      bytes: packet.dropLast()
    )
    return AppleSiliconIOAVRequest(packet: packet, replyCapacity: 0)
  }

  private static func validateLogicalChecksum(
    _ frame: [UInt8],
    operation: String
  ) throws {
    let expectedChecksum = checksum(
      seed: ddcWriteAddress,
      bytes: frame.dropLast()
    )
    guard frame.last == expectedChecksum else {
      throw DDCTransportError.permanentFailure(
        operation: operation,
        status: nil
      )
    }
  }

  private static func exactReplyFrame(
    from reply: [UInt8]
  ) throws -> [UInt8] {
    guard !reply.allSatisfy({ $0 == 0 }) else {
      throw DDCTransportError.noReply
    }

    let lengthByte = reply[1]
    guard (lengthByte & lengthFlag) == lengthFlag else {
      throw DDCTransportError.transientFailure(
        operation: "IOAVServiceReadI2C-invalid-length-byte",
        status: nil
      )
    }

    let exactByteCount = Int(lengthByte & bodyLengthMask) + minimumReplyByteCount
    guard exactByteCount <= reply.count else {
      throw DDCTransportError.transientFailure(
        operation: "IOAVServiceReadI2C-truncated-frame",
        status: nil
      )
    }
    return Array(reply.prefix(exactByteCount))
  }

  private static func checkStatus(
    _ status: IOReturn,
    operation: String
  ) throws {
    guard status != KERN_SUCCESS else {
      return
    }

    switch status {
    case kIOReturnBusy, kIOReturnExclusiveAccess:
      throw DDCTransportError.busy
    case kIOReturnTimeout:
      throw DDCTransportError.timedOut
    case kIOReturnNotResponding:
      throw DDCTransportError.noReply
    case kIOReturnNoDevice, kIOReturnNotFound, kIOReturnUnsupported:
      throw DDCTransportError.unavailable(
        reason: "\(operation) is unavailable with IOReturn status \(status)."
      )
    case kIOReturnNoResources:
      throw DDCTransportError.transientFailure(
        operation: operation,
        status: status
      )
    default:
      throw DDCTransportError.permanentFailure(
        operation: operation,
        status: status
      )
    }
  }

  private static func checksum<Bytes: Sequence>(
    seed: UInt8,
    bytes: Bytes
  ) -> UInt8 where Bytes.Element == UInt8 {
    bytes.reduce(seed) { partialChecksum, byte in
      partialChecksum ^ byte
    }
  }
}
