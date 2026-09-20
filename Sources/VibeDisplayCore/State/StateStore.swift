import Foundation

/// On-disk state shared between the daemon and one-shot CLI invocations.
public struct PersistedState: Codable, Equatable {
    public var version: Int
    public var sessions: [AgentSession]
    /// Brightness values captured before any agent touched the machine, keyed
    /// by display uuid. Persisted so that even `kill -9` on the daemon leaves
    /// enough information for `display-cli restore` to fix the screen.
    public var brightnessSnapshots: [String: Double]
    public var updatedAt: Date

    public init(version: Int = 1,
                sessions: [AgentSession] = [],
                brightnessSnapshots: [String: Double] = [:],
                updatedAt: Date = Date()) {
        self.version = version
        self.sessions = sessions
        self.brightnessSnapshots = brightnessSnapshots
        self.updatedAt = updatedAt
    }
}

/// Serialised, crash-tolerant access to `~/.displaydj/state.json`.
///
/// Concurrency model: one in-process lock plus atomic file replacement. Two
/// concurrent `display-cli` processes can both write safely; last writer wins
/// on a whole-file basis, which is acceptable because the daemon is the only
/// long-lived writer and CLI writes are single-field mutations.
public final class StateStore {
    public static let shared = StateStore()

    private let url: URL
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
        lock.lock()
        var state = cache ?? {
            lock.unlock()
            let loaded = load()
            lock.lock()
            return loaded
        }()
        body(&state)
        state.updatedAt = Date()
        cache = state
        lock.unlock()

        do {
            let data = try JSONCoding.encoder.encode(state)
            try Paths.writeSecure(data, to: url)
        } catch {
            Log.error("failed to persist state: \(error)")
        }
        return state
    }

    public func reload() {
        lock.lock()
        cache = nil
        lock.unlock()
        _ = load()
    }

    public func reset() {
        lock.lock()
        cache = PersistedState()
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }
}
