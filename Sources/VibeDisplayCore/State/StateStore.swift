import Foundation
import Darwin

/// On-disk state shared between the daemon and one-shot CLI invocations.
public struct PersistedState: Codable, Equatable {
    public var version: Int
    public var sessions: [AgentSession]
    /// Brightness values captured before any agent touched the machine, keyed
    /// by display uuid. Persisted so that even `kill -9` on the daemon leaves
    /// enough information for `display-cli restore` to fix the screen.
    public var brightnessSnapshots: [String: Double]
    /// Optional for state files written before transport tracking was added.
    public var brightnessSnapshotTransports: [String: BrightnessTransport]?
    /// Optional for v1 state files. Revisions are keyed by canonical UUID.
    public var brightnessRevisions: [String: String]?
    public var brightnessSnapshotOwnership: [String: BrightnessSnapshotOwnership]?
    public var updatedAt: Date

    public init(version: Int = 1,
                sessions: [AgentSession] = [],
                brightnessSnapshots: [String: Double] = [:],
                brightnessSnapshotTransports: [String: BrightnessTransport]? = nil,
                updatedAt: Date = Date()) {
        self.version = version
        self.sessions = sessions
        self.brightnessSnapshots = brightnessSnapshots
        self.brightnessSnapshotTransports = brightnessSnapshotTransports
        self.updatedAt = updatedAt
    }
}

/// Serialised, crash-tolerant access to `~/.displaydj/state.json`.
///
/// Mutations use a process lock around disk read, edit and atomic replacement.
/// A cached read is useful for callers, but must never be the base of a write.
public final class StateStore {
    public static let shared = StateStore()

    private let url: URL
    var brightnessLockURL: URL { url.appendingPathExtension("brightness-lock") }
    var daemonURL: URL { url.deletingLastPathComponent().appendingPathComponent("daemon.json") }
    private let lock = NSLock()
    private var cache: PersistedState?

    public init(url: URL = Paths.stateFile) {
        self.url = url
    }

    public func load() -> PersistedState {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            let fresh = PersistedState()
            cache = fresh
            return fresh
        }
        guard let decoded = try? JSONCoding.decoder.decode(PersistedState.self, from: data) else {
            Log.warn("state file is corrupt; starting from a clean state", ["path": url.path])
            let fresh = PersistedState()
            cache = fresh
            return fresh
        }
        cache = decoded
        return decoded
    }

    @discardableResult
    public func mutate(_ body: (inout PersistedState) -> Void) -> PersistedState {
        do { return try mutateChecked(body) }
        catch {
            Log.error("failed to persist state: \(error)")
            return load()
        }
    }

    /// Use for changes that must be durable before touching hardware.
    @discardableResult
    public func mutateChecked(_ body: (inout PersistedState) -> Void) throws -> PersistedState {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(fd, LOCK_UN) }

        let stateOnDisk: PersistedState
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONCoding.decoder.decode(PersistedState.self, from: data) else {
                throw VibeError(.configInvalid, "refusing to overwrite unreadable state file")
            }
            stateOnDisk = decoded
        } else {
            stateOnDisk = PersistedState()
        }
        var state = stateOnDisk
        body(&state)
        state.updatedAt = Date()

        let data = try JSONCoding.encoder.encode(state)
        try Paths.writeSecure(data, to: url)
        cache = state
        return state
    }

    public func reload() {
        lock.lock()
        cache = nil
        lock.unlock()
        _ = load()
    }

    /// Authoritative reads for ownership decisions; corrupt files cannot grant control.
    func readChecked() throws -> PersistedState {
        lock.lock(); defer { lock.unlock() }
        let state: PersistedState
        if FileManager.default.fileExists(atPath: url.path) {
            do { state = try JSONCoding.decoder.decode(PersistedState.self, from: Data(contentsOf: url)) }
            catch { throw VibeError(.configInvalid, "cannot read brightness ownership; state file preserved") }
        } else { state = PersistedState() }
        cache = state
        return state
    }

    public func reset() {
        lock.lock()
        cache = PersistedState()
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }
}
