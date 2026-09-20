import Foundation

/// Turns agent lifecycle events into display state.
///
/// Everything an AI coding tool does goes through exactly four verbs:
///
/// ```text
///   begin  → snapshot brightness, apply `starting`, take a keep-awake lease
///   phase  → apply another phase profile (running / waiting / ...)
///   beat   → refresh session TTL and every lease it owns
///   end    → apply the terminal profile (usually `restore`), drop leases
/// ```
///
/// Two invariants are non-negotiable, because violating either leaves a human
/// staring at a broken screen:
///
/// 1. **Snapshot before mutate.** The first session to touch a display records
///    its brightness; nested sessions never re-snapshot, so the value restored
///    at the end is always the human's original.
/// 2. **Every session is reaped.** A session with no heartbeat past its TTL is
///    force-ended by `reap()`, exactly as if the agent had called `end`.
public final class AgentSessionManager {
    public static let shared = AgentSessionManager()

    private let lock = NSLock()
    private let brightness: BrightnessService
    private let keepAwake: KeepAwakeRegistry
    private let store: StateStore
    private var config: VibeConfig

    public init(brightness: BrightnessService = .shared,
                keepAwake: KeepAwakeRegistry = .shared,
                store: StateStore = .shared,
                config: VibeConfig = (try? ConfigLoader.load()) ?? VibeConfig()) {
        self.brightness = brightness
        self.keepAwake = keepAwake
        self.store = store
        self.config = config
        // Re-seed snapshots recorded by a previous process so `restore` still
        // works after a daemon restart.
        brightness.seedSnapshots(store.load().brightnessSnapshots)
    }

    public func updateConfig(_ config: VibeConfig) {
        lock.lock(); defer { lock.unlock() }
        self.config = config
    }

    public func currentConfig() -> VibeConfig {
        lock.lock(); defer { lock.unlock() }
        return config
    }

    // MARK: - Queries

    public func sessions(includeEnded: Bool = false) -> [AgentSession] {
        store.load().sessions
            .filter { includeEnded || $0.isActive }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func session(_ id: String) throws -> AgentSession {
        guard let s = store.load().sessions.first(where: { $0.id == id }) else {
            throw VibeError(.sessionNotFound, "no session '\(id)'",
                            hint: "run `display-cli agent list`")
        }
        return s
    }

    // MARK: - begin

    public func begin(label: String,
                      client: String,
                      selector: String? = nil,
                      ttlSeconds: Int? = nil,
                      metadata: [String: String] = [:],
                      initialPhase: AgentPhase = .starting) throws -> PhaseApplyReport {
        let cfg = currentConfig()
        let resolvedSelector = selector ?? cfg.defaultSelector
        let ttl = ttlSeconds ?? cfg.daemon.sessionReaperTTLSeconds
        let now = Date()

        // Snapshot BEFORE anything is mutated (invariant 1).
        let taken = try brightness.snapshot(DisplaySelector(resolvedSelector))

        var session = AgentSession(
            id: "as_" + UUID().uuidString.prefix(10).lowercased(),
            label: label,
            client: client,
            phase: .idle,
            selector: resolvedSelector,
            createdAt: now,
            updatedAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(ttl)),
            snapshot: taken,
            metadata: metadata
        )

        store.mutate { state in
            state.sessions.append(session)
            for (k, v) in taken where state.brightnessSnapshots[k] == nil {
                state.brightnessSnapshots[k] = v
            }
        }

        Log.info("agent session begin", ["id": session.id, "client": client, "label": label])
        let report = try applyPhase(initialPhase, to: &session, note: "begin", ttlSeconds: ttl)
        return report
    }

    // MARK: - phase transition

    @discardableResult
    public func transition(_ id: String,
                           to phase: AgentPhase,
                           note: String? = nil,
                           ttlSeconds: Int? = nil) throws -> PhaseApplyReport {
        var session = try self.session(id)
        guard session.isActive || !phase.isTerminal else {
            // Ending an already-ended session is a no-op, not an error: agents
            // retry, and a retry must not blow up their pipeline.
            return PhaseApplyReport(session: session, brightness: [], keepAwake: [],
                                    warnings: ["session already terminal (\(session.phase.rawValue)); ignored"])
        }
        return try applyPhase(phase, to: &session, note: note, ttlSeconds: ttlSeconds)
    }

    // MARK: - heartbeat

    @discardableResult
    public func heartbeat(_ id: String, ttlSeconds: Int? = nil) throws -> AgentSession {
        var session = try self.session(id)
        guard session.isActive else {
            // The docs contract (docs/API.md): `session_not_found` covers both
            // "no such id" and "it has already ended" — a heartbeat for a
            // finished session is a 404 / exit 3, not a conflict.
            throw VibeError(.sessionNotFound, "session '\(id)' has already ended (\(session.phase.rawValue))")
        }
        let ttl = ttlSeconds ?? currentConfig().daemon.sessionReaperTTLSeconds
        let now = Date()
        session.updatedAt = now
        session.expiresAt = now.addingTimeInterval(TimeInterval(ttl))
        session.heartbeatCount += 1

        for leaseID in session.keepAwakeLeaseIDs {
            _ = try? keepAwake.renew(leaseID)
        }
        persist(session)
        return session
    }

    // MARK: - end

    @discardableResult
    public func end(_ id: String,
                    outcome: AgentPhase = .succeeded,
                    note: String? = nil,
                    endedBy: String? = nil) throws -> PhaseApplyReport {
        guard outcome.isTerminal else {
            throw VibeError(.invalidArgument, "'\(outcome.rawValue)' is not a terminal phase",
                            hint: "use succeeded, failed, or idle")
        }
        var session = try self.session(id)
        if !session.isActive {
            return PhaseApplyReport(session: session, brightness: [], keepAwake: [],
                                    warnings: ["session already ended"])
        }
        session.endedBy = endedBy
        let report = try applyPhase(outcome, to: &session, note: note, ttlSeconds: nil)
        Log.info("agent session end", ["id": id, "outcome": outcome.rawValue,
                                       "by": endedBy ?? session.client])
        return report
    }

    /// End every active session. Used by `display-cli agent end --all` and on
    /// daemon shutdown.
    @discardableResult
    public func endAll(outcome: AgentPhase = .idle, endedBy: String = "shutdown") -> [PhaseApplyReport] {
        sessions().compactMap { try? end($0.id, outcome: outcome, endedBy: endedBy) }
    }

    // MARK: - reaper

    /// Force-end sessions whose heartbeat lapsed. Safe to call from a timer.
    @discardableResult
    public func reap(now: Date = Date()) -> [AgentSession] {
        let stale = sessions().filter { $0.expiresAt <= now }
        var reaped: [AgentSession] = []
        for session in stale {
            Log.warn("reaping stale agent session",
                     ["id": session.id, "client": session.client,
                      "stale": "\(session.staleSeconds)s"])
            if let report = try? end(session.id, outcome: .failed,
                                     note: "heartbeat timeout", endedBy: "reaper") {
                reaped.append(report.session)
            }
        }
        return reaped
    }

    /// Absolute last resort: restore every display and release everything,
    /// regardless of session bookkeeping.
    @discardableResult
    public func panicRestore() -> [BrightnessApplyResult] {
        keepAwake.releaseEverything()
        let results = brightness.restoreAll()
        store.mutate { state in
            state.sessions = state.sessions.map { s in
                var copy = s
                if copy.isActive {
                    copy.phase = .idle
                    copy.endedBy = "panic-restore"
                    copy.updatedAt = Date()
                }
                return copy
            }
        }
        return results
    }

    // MARK: - Core

    private func applyPhase(_ phase: AgentPhase,
                            to session: inout AgentSession,
                            note: String?,
                            ttlSeconds: Int?) throws -> PhaseApplyReport {
        let cfg = currentConfig()
        let profile = cfg.profile(for: phase)
        var warnings: [String] = []
        let previous = session.phase

        // ---- brightness ----
        var brightnessResults: [BrightnessApplyResult] = []
        if let expression = profile.brightness {
            let selectorString = profile.selector ?? session.selector
            let selector = DisplaySelector(selectorString)
            do {
                let target = try BrightnessTarget.parse(expression)
                let ramp = BrightnessRamp(durationMs: profile.rampMs ?? cfg.defaultRampMs)
                brightnessResults = try applyRespectingOverrides(target, selector: selector, ramp: ramp, config: cfg)
                for failure in brightnessResults where !failure.ok {
                    warnings.append("display \(failure.slug): \(failure.error ?? "write failed")")
                }
            } catch let err as VibeError {
                warnings.append("brightness skipped: \(err.message)")
            }
        }

        // ---- keep-awake ----
        // Reconcile rather than tear down and rebuild: an unchanged scope keeps
        // the same assertion, so the screen never flickers between phases.
        var leases: [KeepAwakeLease] = []
        let wanted = Set(profile.keepAwake)
        var existing: [KeepAwakeScope: KeepAwakeLease] = [:]
        for leaseID in session.keepAwakeLeaseIDs {
            if let lease = keepAwake.currentLease(leaseID) { existing[lease.scope] = lease }
        }

        for (scope, lease) in existing where !wanted.contains(scope) {
            try? keepAwake.release(lease.id)
        }

        let policy = KeepAwakePolicy(
            ttlSeconds: profile.keepAwakeTTLSeconds ?? ttlSeconds ?? cfg.daemon.sessionReaperTTLSeconds,
            maxDurationSeconds: nil,
            requireACPower: profile.requireACPower ?? false,
            activeWindow: profile.activeWindow
        )
        for scope in wanted.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let lease = existing[scope] {
                leases.append((try? keepAwake.renew(lease.id, ttlSeconds: policy.ttlSeconds)) ?? lease)
            } else {
                leases.append(keepAwake.acquire(scope: scope,
                                                reason: "\(session.client): \(session.label) [\(phase.rawValue)]",
                                                owner: session.id,
                                                policy: policy))
            }
        }

        // ---- session bookkeeping ----
        let now = Date()
        session.phase = phase
        session.updatedAt = now
        if let note { session.note = note }
        session.keepAwakeLeaseIDs = leases.map(\.id)
        session.transitions.append(.init(from: previous, to: phase, at: now, note: note))
        if let ttlSeconds {
            session.expiresAt = now.addingTimeInterval(TimeInterval(ttlSeconds))
        } else if !phase.isTerminal {
            session.expiresAt = now.addingTimeInterval(TimeInterval(cfg.daemon.sessionReaperTTLSeconds))
        }

        if phase.isTerminal {
            _ = keepAwake.releaseAll(owner: session.id)
            session.keepAwakeLeaseIDs = []
            leases = []
        }

        persist(session)

        // Successful restores retire their own snapshots. Never discard failed
        // or disconnected recovery points merely because a session ended.

        return PhaseApplyReport(session: session, brightness: brightnessResults,
                                keepAwake: leases, warnings: warnings)
    }

    /// Apply per-display config overrides (exclude / min / max) on top of the
    /// requested target.
    private func applyRespectingOverrides(_ target: BrightnessTarget,
                                          selector: DisplaySelector,
                                          ramp: BrightnessRamp,
                                          config: VibeConfig) throws -> [BrightnessApplyResult] {
        let displays = try selector.resolve(in: brightness.inventory())
        var results: [BrightnessApplyResult] = []
        for display in displays {
            let override = config.displays[display.slug] ?? config.displays[display.uuid]
            if override?.exclude == true { continue }

            var effective = target
            if case .absolute(let value) = target {
                var v = value
                if let lo = override?.minBrightness { v = max(lo, v) }
                if let hi = override?.maxBrightness { v = min(hi, v) }
                effective = .absolute(v)
            }
            results.append(brightness.apply(effective, to: display, ramp: ramp))
        }
        return results
    }

    private func persist(_ session: AgentSession) {
        store.mutate { state in
            if let idx = state.sessions.firstIndex(where: { $0.id == session.id }) {
                state.sessions[idx] = session
            } else {
                state.sessions.append(session)
            }
            // Keep the history bounded; the last 50 ended sessions is plenty
            // for debugging and keeps state.json small enough to read by hand.
            let ended = state.sessions.filter { !$0.isActive }.sorted { $0.updatedAt > $1.updatedAt }
            if ended.count > 50 {
                let drop = Set(ended.dropFirst(50).map(\.id))
                state.sessions.removeAll { drop.contains($0.id) }
            }
        }
    }
}
