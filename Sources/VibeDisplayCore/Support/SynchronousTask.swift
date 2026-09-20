import Foundation

/// Adapts the legacy synchronous CLI/server to the async hardware engine.
/// The main run loop must remain available because display discovery uses AppKit.
/// There is deliberately no timeout that could return while a write still runs.
/// Callers needing a hard deadline must isolate the entire command in a process.
public enum SynchronousTask {
    public static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let state = Completion<Value>()
        Task.detached {
            let result: Result<Value, Error>
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
            state.finish(result)
        }
        if Thread.isMainThread {
            while state.result == nil {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
            }
        } else {
            state.semaphore.wait()
        }
        return try state.result!.get()
    }
}

private final class Completion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Value, Error>?
    let semaphore = DispatchSemaphore(value: 0)

    var result: Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        storage = result
        lock.unlock()
        semaphore.signal()
    }
}
