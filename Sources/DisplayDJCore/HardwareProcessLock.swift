import Darwin
import Foundation

/// Serializes complete DDC operations across the menu bar, CLI and daemon.
/// Unlike an actor, flock also covers other processes and releases on process death.
/// One user-local lock intentionally serializes all panels: DDC traffic is small,
/// and runtime selectors must not bypass a UUID-keyed lock for the same device.
enum HardwareProcessLock {
  static func withLock<Value: Sendable>(
    path: String = FileManager.default.temporaryDirectory
      .appendingPathComponent("displaydj-hardware.lock").path,
    operation: @Sendable () async throws -> Value
  ) async throws -> Value {
    let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard fd >= 0 else {
      throw DisplayDJError(code: .busy, message: "Cannot open the shared display hardware lock.")
    }
    defer { close(fd) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EAGAIN else {
        throw DisplayDJError(code: .busy, message: "Cannot acquire the shared display hardware lock.")
      }
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else {
        throw DisplayDJError(code: .busy, message: "Another display operation is still running; retry shortly.")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    defer { flock(fd, LOCK_UN) }
    try Task.checkCancellation()
    return try await operation()
  }
}
