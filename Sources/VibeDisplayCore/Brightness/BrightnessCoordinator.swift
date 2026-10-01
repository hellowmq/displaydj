import Foundation
import Darwin

public struct BrightnessSnapshotOwnership: Codable, Equatable, Sendable {
    public let revision: String
    /// The session that first captured a shared Agent recovery point; nil for manual undo.
    public let sessionID: String?
}

enum BrightnessWriteOrigin {
    case manual
    case agent(sessionID: String, revisions: [String: String])
    case automaticRestore
}

/// Product-level arbitration, above the DDC transport lock. Both synchronous
/// CLI/server operations and asynchronous GUI writes hold this lock through
/// verification. A manual claim is persisted before hardware can be changed.
/// No daemon is needed: every process sharing DISPLAYDJ_HOME sees the same state.
public final class BrightnessCoordinator: @unchecked Sendable {
    public static let shared = BrightnessCoordinator(store: .shared)
    private let store: StateStore
    private let lockURL: URL

    public convenience init(store: StateStore) { self.init(store: store, lockURL: store.brightnessLockURL) }
    init(store: StateStore, lockURL: URL) { self.store = store; self.lockURL = lockURL }

    static func key(_ identity: String) -> String {
        let raw = identity.lowercased().hasPrefix("uuid:") ? String(identity.dropFirst(5)) : identity
        return raw.lowercased()
    }

    private func openLock() throws -> Int32 {
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VibeError(.ioFailure, "cannot open brightness control lock") }
        return fd
    }

    private func tryLock(_ fd: Int32, deadline: ContinuousClock.Instant) throws -> Bool {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
        guard (errno == EWOULDBLOCK || errno == EAGAIN), ContinuousClock.now < deadline else {
            throw VibeError(.sessionConflict, "another brightness operation is running; retry shortly")
        }
        return false
    }

    public func acquire() async throws -> BrightnessControlLock {
        let fd = try openLock()
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while try !tryLock(fd, deadline: deadline) {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
            return BrightnessControlLock(fd: fd)
        } catch { close(fd); throw error }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        let fd = try openLock()
        defer { close(fd) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try !tryLock(fd, deadline: deadline) { usleep(10_000) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    func freshState() throws -> PersistedState {
        // Checked disk access also rejects corrupt state. Never authorize a write
        // from a daemon's cached view after another process took manual control.
        try checkDaemonVersion()
        return try store.readChecked()
    }

    /// Call only while holding acquire()/transaction(). Existing Agent claims
    /// become stale even when the requested value already matches the panel.
    /// GUI writes retire undo points; direct CLI writes can retain a manual undo.
    public func takeManualControl(stableID: String, retainingManualUndo: Bool = false) throws {
        try checkDaemonVersion()
        let key = Self.key(stableID)
        try store.mutateChecked { state in
            var revisions = state.brightnessRevisions ?? [:]
            let revision = UUID().uuidString
            revisions[key] = revision
            state.brightnessRevisions = revisions
            for uuid in Array(state.brightnessSnapshots.keys) where Self.key(uuid) == key {
                if retainingManualUndo, let saved = state.brightnessSnapshotOwnership?[uuid], saved.sessionID == nil {
                    state.brightnessSnapshotOwnership?[uuid] = .init(revision: revision, sessionID: nil)
                } else {
                    Self.removeSnapshot(uuid, from: &state)
                }
            }
        }
    }

    private func checkDaemonVersion() throws {
        guard FileManager.default.fileExists(atPath: store.daemonURL.path) else { return }
        let descriptor: DaemonDescriptor
        do { descriptor = try JSONCoding.decoder.decode(DaemonDescriptor.self, from: Data(contentsOf: store.daemonURL)) }
        catch { throw VibeError(.configInvalid, "cannot read daemon identity; no brightness write sent") }
        if kill(descriptor.pid, 0) != 0 && errno == ESRCH { return }
        guard descriptor.version == VibeVersion.current else {
            throw VibeError(.daemonUnavailable,
                "running daemon \(descriptor.version) must be restarted with DisplayDJ \(VibeVersion.current) before brightness writes",
                hint: "end automation tasks, then run the installed display-cli daemon restart")
        }
    }

    static func removeSnapshot(_ uuid: String, from state: inout PersistedState) {
        state.brightnessSnapshots.removeValue(forKey: uuid)
        state.brightnessSnapshotTransports?.removeValue(forKey: uuid)
        state.brightnessSnapshotOwnership?.removeValue(forKey: uuid)
    }
}

/// Owns an open file description, not a thread. Safe to hold across GUI awaits.
public final class BrightnessControlLock: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32?
    fileprivate init(fd: Int32) { self.fd = fd }
    public func release() {
        lock.lock(); defer { lock.unlock() }
        if let fd { flock(fd, LOCK_UN); close(fd); self.fd = nil }
    }
    deinit { release() }
}
