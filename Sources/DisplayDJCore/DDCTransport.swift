import Foundation

/// A transport-neutral DDC request. The frame excludes the I2C write address.
/// A zero reply capacity means that the operation expects no reply bytes.
struct DDCTransportRequest: Equatable, Sendable {
  let logicalFrame: [UInt8]
  let replyCapacity: Int
  let replyDelay: TimeInterval
  /// How many consecutive copies of this frame reach the bus before any reply is
  /// read. Some displays drop an isolated Set frame and only apply a value once
  /// an identical frame follows it with no intervening Get, so a Set that failed
  /// verification may escalate past one. A Get never needs this: its own reply
  /// handshake already primes the bus.
  let writeFrameCount: Int

  init(
    logicalFrame: [UInt8],
    replyCapacity: Int,
    replyDelay: TimeInterval = 0.05,
    writeFrameCount: Int = 1
  ) {
    precondition(writeFrameCount > 0, "writeFrameCount must be positive")

    self.logicalFrame = logicalFrame
    self.replyCapacity = replyCapacity
    self.replyDelay = replyDelay
    self.writeFrameCount = writeFrameCount
  }
}

/// One exact DDC reply frame with any transport-owned padding removed. A
/// successfully completed request with zero reply capacity must return an empty
/// frame.
struct DDCTransportResponse: Equatable, Sendable {
  let exactFrame: [UInt8]
}

/// Identifies a runtime transport resource that must not be used concurrently.
///
/// This is deliberately separate from a display's stable identity. A future
/// transport may assign the same key to multiple displays that share one I2C
/// adapter or framebuffer.
struct DDCSerializationKey: Equatable, Hashable, Sendable {
  let backend: BackendKind
  let resourceID: UInt64
}

/// A run-scoped DDC target. Registry IDs are runtime transport handles, not
/// persistent display selectors.
struct DDCTransportTarget: Equatable, Sendable {
  let display: DisplayDescriptor
  let backend: BackendKind
  let service: DDCServiceIdentity
  let serializationKey: DDCSerializationKey

  init(
    display: DisplayDescriptor,
    backend: BackendKind,
    service: DDCServiceIdentity,
    serializationKey: DDCSerializationKey? = nil
  ) {
    self.display = display
    self.backend = backend
    self.service = service
    self.serializationKey =
      serializationKey
      ?? DDCSerializationKey(
        backend: backend,
        resourceID: service.registryEntryID
      )
  }
}

/// Injectable boundary for an Intel or Apple Silicon DDC transport.
///
/// The Apple Silicon conformer accepts exact Get and Set VCP frames, and the
/// production composition exposes both brightness operations through guarded
/// CLI entry points. Implementations must return only after the exchange has
/// completed or failed;
/// fire-and-forget I/O is not permitted. A blocking native transport
/// must enforce its own bounded timeout because Swift task cancellation cannot
/// stop a driver call.
protocol DDCTransport: Sendable {
  func exchange(
    _ request: DDCTransportRequest,
    on target: DDCTransportTarget
  ) async throws -> DDCTransportResponse
}

enum DDCTransportError: Error, Equatable, Sendable {
  case unavailable(reason: String)
  case busy
  case timedOut
  case noReply
  case transientFailure(operation: String, status: Int32?)
  case permanentFailure(operation: String, status: Int32?)
}

/// Injectable deadline boundary so retry and timeout behavior can be tested
/// without depending on wall-clock sleeps. Implementations must cooperate with
/// task cancellation so a completed transport response can drain its race.
protocol DDCDeadlineWaiting: Sendable {
  func wait(for duration: Duration) async throws
}

struct ContinuousDDCDeadlineWaiter: DDCDeadlineWaiting {
  func wait(for duration: Duration) async throws {
    try await Task<Never, Never>.sleep(for: duration)
  }
}

struct DDCExecutionPolicy: Equatable, Sendable {
  /// Includes the initial attempt.
  let maximumAttempts: Int
  let attemptTimeout: Duration?
  /// Includes the initial single-frame attempt. A later attempt only happens
  /// after a Set reached the display and its read-back disagreed, never after a
  /// transport failure left the applied value unknown.
  let maximumSetAttempts: Int

  init(
    maximumAttempts: Int = 5,
    attemptTimeout: Duration? = .seconds(2),
    maximumSetAttempts: Int = 2
  ) {
    precondition(maximumAttempts > 0, "maximumAttempts must be positive")
    precondition(maximumSetAttempts > 0, "maximumSetAttempts must be positive")
    if let attemptTimeout {
      precondition(attemptTimeout > .zero, "attemptTimeout must be positive")
    }

    self.maximumAttempts = maximumAttempts
    self.attemptTimeout = attemptTimeout
    self.maximumSetAttempts = maximumSetAttempts
  }
}
