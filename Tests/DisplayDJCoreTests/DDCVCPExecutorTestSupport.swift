import Testing

@testable import DisplayDJCore

enum TransportAction: Sendable {
  case complete(TransportOutcome)
  case gated(TestGate, TransportOutcome)
  case barrier(TestBarrier, TransportOutcome)
  case cancellationGated(TestGate, TransportOutcome)
}

enum TransportOutcome: Sendable {
  case success(maximumValue: UInt16, currentValue: UInt16)
  case response([UInt8])
  case failure(DDCTransportError)
}

enum TransportEvent: Equatable, Sendable {
  case cancelled(callIndex: Int)
}

struct RecordedTransportCall: Equatable, Sendable {
  let request: DDCTransportRequest
  let target: DDCTransportTarget

  var opcode: UInt8? {
    request.logicalFrame.count > 2 ? request.logicalFrame[2] : nil
  }

  var featureCode: UInt8? {
    request.logicalFrame.count > 3 ? request.logicalFrame[3] : nil
  }

  var setRawValue: UInt16? {
    guard opcode == 0x03, request.logicalFrame.count == 7 else {
      return nil
    }
    return (UInt16(request.logicalFrame[4]) << 8)
      | UInt16(request.logicalFrame[5])
  }
}

struct TransportSnapshot: Sendable {
  let calls: [RecordedTransportCall]
  let maximumActiveOverall: Int
  let maximumActiveByKey: [DDCSerializationKey: Int]
}

actor ScriptedDDCTransport: DDCTransport {
  private struct CallCountWaiter {
    let expectedCount: Int
    let continuation: CheckedContinuation<Void, Never>
  }

  private let actions: [TransportAction]
  private let eventContinuation: AsyncStream<TransportEvent>.Continuation?
  private var calls: [RecordedTransportCall] = []
  private var activeOverall = 0
  private var activeByKey: [DDCSerializationKey: Int] = [:]
  private var maximumActiveOverall = 0
  private var maximumActiveByKey: [DDCSerializationKey: Int] = [:]
  private var callCountWaiters: [CallCountWaiter] = []

  init(
    actions: [TransportAction],
    eventContinuation: AsyncStream<TransportEvent>.Continuation? = nil
  ) {
    self.actions = actions
    self.eventContinuation = eventContinuation
  }

  func exchange(
    _ request: DDCTransportRequest,
    on target: DDCTransportTarget
  ) async throws -> DDCTransportResponse {
    let callIndex = calls.count
    guard actions.indices.contains(callIndex) else {
      throw DDCTransportError.permanentFailure(
        operation: "unexpected-test-call",
        status: nil
      )
    }
    let action = actions[callIndex]
    calls.append(RecordedTransportCall(request: request, target: target))
    beginActivity(for: target.serializationKey)
    resumeSatisfiedCallCountWaiters()
    defer { endActivity(for: target.serializationKey) }

    switch action {
    case .complete(let outcome):
      return try resolve(outcome, request: request)
    case .gated(let gate, let outcome):
      await gate.wait()
      return try resolve(outcome, request: request)
    case .barrier(let barrier, let outcome):
      await barrier.arriveAndWait()
      return try resolve(outcome, request: request)
    case .cancellationGated(let gate, let outcome):
      let eventContinuation = eventContinuation
      return try await withTaskCancellationHandler {
        await gate.wait()
        try Task.checkCancellation()
        return try resolve(outcome, request: request)
      } onCancel: {
        eventContinuation?.yield(.cancelled(callIndex: callIndex))
      }
    }
  }

  func waitUntilCallCount(_ expectedCount: Int) async {
    guard calls.count < expectedCount else {
      return
    }

    await withCheckedContinuation { continuation in
      callCountWaiters.append(
        CallCountWaiter(
          expectedCount: expectedCount,
          continuation: continuation
        )
      )
    }
  }

  func snapshot() -> TransportSnapshot {
    TransportSnapshot(
      calls: calls,
      maximumActiveOverall: maximumActiveOverall,
      maximumActiveByKey: maximumActiveByKey
    )
  }

  private func resolve(
    _ outcome: TransportOutcome,
    request: DDCTransportRequest
  ) throws -> DDCTransportResponse {
    switch outcome {
    case .success(let maximumValue, let currentValue):
      guard request.logicalFrame.count > 3 else {
        throw DDCTransportError.permanentFailure(
          operation: "malformed-test-request",
          status: nil
        )
      }
      return DDCTransportResponse(
        exactFrame: getFeatureReply(
          featureCode: request.logicalFrame[3],
          maximumValue: maximumValue,
          currentValue: currentValue
        )
      )
    case .response(let frame):
      return DDCTransportResponse(exactFrame: frame)
    case .failure(let error):
      throw error
    }
  }

  private func beginActivity(for key: DDCSerializationKey) {
    activeOverall += 1
    activeByKey[key, default: 0] += 1
    maximumActiveOverall = max(maximumActiveOverall, activeOverall)
    maximumActiveByKey[key] = max(
      maximumActiveByKey[key, default: 0],
      activeByKey[key, default: 0]
    )
  }

  private func endActivity(for key: DDCSerializationKey) {
    activeOverall -= 1
    activeByKey[key, default: 0] -= 1
  }

  private func resumeSatisfiedCallCountWaiters() {
    var waiting: [CallCountWaiter] = []
    for waiter in callCountWaiters {
      if calls.count >= waiter.expectedCount {
        waiter.continuation.resume()
      } else {
        waiting.append(waiter)
      }
    }
    callCountWaiters = waiting
  }
}

actor TestGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else {
      return
    }

    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    guard !isOpen else {
      return
    }

    isOpen = true
    let currentWaiters = waiters
    waiters.removeAll()
    for waiter in currentWaiters {
      waiter.resume()
    }
  }
}

actor TestCompletionProbe {
  private var isMarked = false

  func mark() {
    isMarked = true
  }

  func snapshot() -> Bool {
    isMarked
  }
}

func waitForCompletion(
  _ probe: TestCompletionProbe,
  maximumYields: Int = 1_000
) async -> Bool {
  for _ in 0..<maximumYields {
    if await probe.snapshot() {
      return true
    }
    await Task.yield()
  }
  return await probe.snapshot()
}

actor TestBarrier {
  private var remainingParticipants: Int
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(participantCount: Int) {
    precondition(participantCount > 0)
    remainingParticipants = participantCount
  }

  func arriveAndWait() async {
    remainingParticipants -= 1
    guard remainingParticipants > 0 else {
      let currentWaiters = waiters
      waiters.removeAll()
      for waiter in currentWaiters {
        waiter.resume()
      }
      return
    }

    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

actor ManualDeadlineWaiter: DDCDeadlineWaiting {
  private let firstDeadlineGate: TestGate
  private var waitCount = 0

  init(gate: TestGate) {
    firstDeadlineGate = gate
  }

  func wait(for duration: Duration) async throws {
    waitCount += 1
    if waitCount == 1 {
      await firstDeadlineGate.wait()
      try Task.checkCancellation()
    } else {
      try await Task<Never, Never>.sleep(for: duration)
    }
  }
}

func makeTransportTarget(
  resourceID: UInt64,
  runtimeID: UInt32 = 42,
  backend: BackendKind = .appleSiliconDDC
) -> DDCTransportTarget {
  DDCTransportTarget(
    display: DisplayDescriptor(
      runtimeID: runtimeID,
      stableID: "uuid:executor-test-\(runtimeID)",
      name: "Executor Test Display",
      vendorID: 0x22F0,
      productID: 0x77F3,
      serialNumber: runtimeID,
      isBuiltIn: false,
      isVirtual: false,
      isMirrored: false
    ),
    backend: backend,
    service: DDCServiceIdentity(
      registryEntryID: resourceID,
      serviceClass: "FakeDDCService",
      matchBasis: .hardwareTuple
    )
  )
}

func capturedDisplayDJError<Value: Sendable>(
  _ operation: @Sendable () async throws -> Value
) async -> DisplayDJError? {
  do {
    _ = try await operation()
    Issue.record("Expected DisplayDJError, but the operation succeeded.")
  } catch let error as DisplayDJError {
    return error
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
  return nil
}

func getFeatureReply(
  featureCode: UInt8,
  resultCode: UInt8 = 0x00,
  valueType: UInt8 = 0x00,
  maximumValue: UInt16 = 100,
  currentValue: UInt16 = 50
) -> [UInt8] {
  responseMessage(
    body: [
      0x02,
      resultCode,
      featureCode,
      valueType,
      UInt8(truncatingIfNeeded: maximumValue >> 8),
      UInt8(truncatingIfNeeded: maximumValue),
      UInt8(truncatingIfNeeded: currentValue >> 8),
      UInt8(truncatingIfNeeded: currentValue),
    ]
  )
}

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
