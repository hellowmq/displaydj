import Darwin
import Foundation

/// One topology lock per user session, independent of product or config home.
/// Do not share the DDC lock: a connection transaction can wait for discovery.
public struct DisplayConnectionCoordinator: Sendable {
  public static let shared = DisplayConnectionCoordinator(directory: FileManager.default.temporaryDirectory)
  public let directory: URL
  private var lockPath: String { directory.appendingPathComponent("displaydj-connection-v1.lock").path }
  private var journalURL: URL { directory.appendingPathComponent("displaydj-connection-v1.json") }
  @TaskLocal private static var ownedPaths: Set<String> = []

  public init(directory: URL) { self.directory = directory }

  public func withLock<T: Sendable>(timeout: Duration = .seconds(5),
    _ operation: @Sendable () async throws -> T) async throws -> T {
    if Self.ownedPaths.contains(lockPath) { return try await operation() }
    let fd = try openLock()
    defer { close(fd) }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EAGAIN else { throw Self.busy() }
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else { throw Self.busy() }
      try await Task.sleep(for: .milliseconds(25))
    }
    defer { flock(fd, LOCK_UN) }
    try Task.checkCancellation()
    return try await Self.$ownedPaths.withValue(Self.ownedPaths.union([lockPath]), operation: operation)
  }

  /// Fast record reconciliation never waits on the main thread. Callers retain
  /// their old rows on busy and retry on the next topology refresh.
  public func withImmediateLock<T>(_ operation: () throws -> T) throws -> T {
    if Self.ownedPaths.contains(lockPath) { return try operation() }
    let fd = try openLock()
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Self.busy() }
    defer { flock(fd, LOCK_UN) }
    return try Self.$ownedPaths.withValue(Self.ownedPaths.union([lockPath]), operation: operation)
  }

  struct Intent: Codable, Sendable {
    let operationID: UUID
    let runtimeID: UInt32
    let updatedAt: Date
  }
  private struct Journal: Codable { let schemaVersion: Int; var intents: [String: Intent] }

  public func isSuperseded(_ record: DisplayConnectionRecord) throws -> Bool {
    guard let id = record.stableID, let latest = try load()[id] else { return false }
    return latest.operationID != record.operationID
  }

  func intent(for stableID: String) throws -> Intent? { try load()[stableID] }

  func finishIntent(for stableID: String?) throws {
    guard let stableID, let latest = try intent(for: stableID) else { return }
    try note(stableID: stableID, intent: .init(operationID: latest.operationID,
      runtimeID: latest.runtimeID, updatedAt: Date()))
  }

  func note(stableID: String, intent: Intent) throws {
    precondition(Self.ownedPaths.contains(lockPath))
    var intents = try load(); intents[stableID] = intent
    let data = try JSONEncoder().encode(Journal(schemaVersion: 1, intents: intents))
    do { try data.write(to: journalURL, options: .atomic) }
    catch { throw DisplayDJError(code: .internalFailure, message: "Connection coordination could not be saved.", details: ["phase": "connection-journal-save"]) }
  }

  func hasNewerIntent(runtimeID: UInt32, than date: Date) throws -> Bool {
    try load().values.contains { $0.runtimeID == runtimeID && $0.updatedAt > date }
  }

  private func load() throws -> [String: Intent] {
    guard FileManager.default.fileExists(atPath: journalURL.path) else { return [:] }
    do {
      let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
      guard journal.schemaVersion == 1 else { throw Self.busy() }
      return journal.intents
    } catch { throw DisplayDJError(code: .internalFailure, message: "Connection coordination could not be read.", details: ["phase": "connection-journal-load"]) }
  }

  private func openLock() throws -> Int32 {
    let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw Self.busy() }
    return fd
  }
  private static func busy() -> DisplayDJError {
    DisplayDJError(code: .busy, message: "另一个显示器连接操作仍在进行，请稍后重试。")
  }
}
