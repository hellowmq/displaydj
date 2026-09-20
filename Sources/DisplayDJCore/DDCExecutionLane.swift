actor DDCExecutionLaneRegistry {
  static let processShared = DDCExecutionLaneRegistry()

  private var lanes: [DDCSerializationKey: DDCExecutionLane] = [:]

  func lane(for key: DDCSerializationKey) -> DDCExecutionLane {
    if let lane = lanes[key] {
      return lane
    }

    let lane = DDCExecutionLane()
    lanes[key] = lane
    return lane
  }
}

/// Actor isolation alone is reentrant at suspension points, so this lane uses
/// an explicit permit that remains held across the operation's awaits.
actor DDCExecutionLane {
  private typealias WaiterContinuation = CheckedContinuation<Void, any Error>

  private struct Waiter {
    let id: UInt64
    let continuation: WaiterContinuation
  }

  private var isOccupied = false
  private var nextWaiterID: UInt64 = 0
  private var waiters: [Waiter] = []

  func perform<Result: Sendable>(
    _ operation: @Sendable () async throws -> Result
  ) async throws -> Result {
    try await acquire()
    defer { release() }
    try Task.checkCancellation()
    return try await operation()
  }

  private func acquire() async throws {
    try Task.checkCancellation()
    guard isOccupied else {
      isOccupied = true
      return
    }

    let waiterID = nextWaiterID
    nextWaiterID &+= 1
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: WaiterContinuation) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        waiters.append(Waiter(id: waiterID, continuation: continuation))
      }
    } onCancel: {
      Task {
        await self.cancel(waiterID: waiterID)
      }
    }
  }

  private func cancel(waiterID: UInt64) {
    guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
      return
    }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }

  private func release() {
    guard !waiters.isEmpty else {
      isOccupied = false
      return
    }

    waiters.removeFirst().continuation.resume()
  }
}
