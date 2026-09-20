import Foundation
import IOKit.pwr_mgt

/// Holds power assertions on behalf of many independent callers.
///
/// Design notes
/// ------------
/// * **Leases, not assertions.** Callers get a `KeepAwakeLease`; the registry
///   coalesces all leases of one scope onto a *single* `IOPMAssertion`. Ten
///   concurrent agent tasks cost one assertion, and releasing one lease never
///   wakes the screen out from under the other nine.
/// * **Everything expires.** Each lease carries a TTL that only a heartbeat
///   refreshes (Caffeine's `expireAfterWrite` + `refreshAfterWrite`). A crashed
///   agent stops sending heartbeats and the display sleeps normally within one
///   TTL — the single most important safety property of this component.
/// * **Suspend vs evict.** A lease that violates a *condition* (on battery,
///   outside its active window) is suspended: the assertion drops, the lease
///   survives, and it resumes automatically. A lease that violates *time* is
///   evicted for good.
public final class KeepAwakeRegistry {
    public static let shared = KeepAwakeRegistry()

    private let lock = NSLock()
    private var leases: [String: KeepAwakeLease] = [:]
    private var assertions: [KeepAwakeScope: IOPMAssertionID] = [:]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.displaydj.keepawake", qos: .utility)

    /// Notified after every maintenance pass that changed something.
    public var onChange: (([KeepAwakeLease]) -> Void)?

    public init() {}

    // MARK: - Public API

    @discardableResult
    public func acquire(scope: KeepAwakeScope,
                        reason: String,
                        owner: String,
                        policy: KeepAwakePolicy = .default,
                        id: String? = nil) -> KeepAwakeLease {
        let now = Date()
        let lease = KeepAwakeLease(
            id: id ?? "ka_" + UUID().uuidString.prefix(8).lowercased(),
            owner: owner,
            scope: scope,
            reason: reason,
            createdAt: now,
            lastRenewedAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(policy.ttlSeconds)),
            renewCount: 0,
            policy: policy,
            suspended: false,
            suspendedReason: nil
        )
        lock.lock()
        leases[lease.id] = lease
        lock.unlock()

        Log.info("keep-awake acquired", ["id": lease.id, "scope": scope.rawValue, "owner": owner,
                                         "ttl": "\(policy.ttlSeconds)s"])
        runMaintenance()
        startTimerIfNeeded()
        return currentLease(lease.id) ?? lease
    }

    /// Heartbeat. Pushes the expiry out by one TTL.
    @discardableResult
    public func renew(_ id: String, ttlSeconds: Int? = nil) throws -> KeepAwakeLease {
        lock.lock()
        guard var lease = leases[id] else {
            lock.unlock()
            throw VibeError(.sessionNotFound, "no keep-awake lease with id '\(id)'")
        }
        if let ttlSeconds { lease.policy.ttlSeconds = max(5, ttlSeconds) }
        let now = Date()
        lease.lastRenewedAt = now
        lease.expiresAt = now.addingTimeInterval(TimeInterval(lease.policy.ttlSeconds))
        lease.renewCount += 1
        leases[id] = lease
        lock.unlock()

        runMaintenance()
        return currentLease(id) ?? lease
    }

    public func release(_ id: String) throws {
        lock.lock()
        guard leases.removeValue(forKey: id) != nil else {
            lock.unlock()
            throw VibeError(.sessionNotFound, "no keep-awake lease with id '\(id)'")
        }
        lock.unlock()
        Log.info("keep-awake released", ["id": id])
        runMaintenance()
    }

    /// Release every lease held by one owner (e.g. one agent session).
    @discardableResult
    public func releaseAll(owner: String) -> Int {
        lock.lock()
        let victims = leases.values.filter { $0.owner == owner }.map(\.id)
        victims.forEach { leases.removeValue(forKey: $0) }
        lock.unlock()
        if !victims.isEmpty {
            Log.info("keep-awake released by owner", ["owner": owner, "count": "\(victims.count)"])
            runMaintenance()
        }
        return victims.count
    }

    /// Full teardown. Called on daemon shutdown and from signal handlers.
    public func releaseEverything() {
        lock.lock()
        leases.removeAll()
        let held = assertions
        assertions.removeAll()
        lock.unlock()
        for (scope, id) in held {
            IOPMAssertionRelease(id)
            Log.debug("assertion released", ["scope": scope.rawValue])
        }
        stopTimer()
    }

    public func allLeases() -> [KeepAwakeLease] {
        lock.lock(); defer { lock.unlock() }
        return leases.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func currentLease(_ id: String) -> KeepAwakeLease? {
        lock.lock(); defer { lock.unlock() }
        return leases[id]
    }

    public func activeScopes() -> [KeepAwakeScope] {
        lock.lock(); defer { lock.unlock() }
        return assertions.keys.sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: - Maintenance (eviction cycle)

    /// Idempotent reconciliation: expire, evaluate conditions, then make the
    /// set of held assertions exactly match the set of live scopes.
    public func runMaintenance() {
        let now = Date()
        var changed = false

        lock.lock()

        // 1. Time-based eviction.
        for (id, lease) in leases {
            var evict = false
            if lease.expiresAt <= now { evict = true }
            if let cap = lease.policy.maxDurationSeconds,
               now.timeIntervalSince(lease.createdAt) >= TimeInterval(cap) { evict = true }
            if evict {
                leases.removeValue(forKey: id)
                changed = true
                Log.info("keep-awake evicted", ["id": id, "owner": lease.owner, "reason": "expired"])
            }
        }

        // 2. Condition-based suspend/resume.
        for (id, var lease) in leases {
            let (ok, reason) = lease.policy.conditionsSatisfied(now: now)
            if lease.suspended != !ok {
                lease.suspended = !ok
                lease.suspendedReason = reason
                leases[id] = lease
                changed = true
                Log.info(ok ? "keep-awake resumed" : "keep-awake suspended",
                         ["id": id, "reason": reason ?? "conditions met"])
            }
        }

        let wanted = Set(leases.values.filter { !$0.suspended }.map(\.scope))
        let held = Set(assertions.keys)
        let toCreate = wanted.subtracting(held)
        let toDrop = held.subtracting(wanted)
        let snapshot = leases.values.sorted { $0.createdAt < $1.createdAt }

        var created: [KeepAwakeScope: IOPMAssertionID] = [:]
        for scope in toCreate {
            if let assertionID = Self.createAssertion(scope: scope) {
                created[scope] = assertionID
            } else {
                Log.error("failed to create power assertion", ["scope": scope.rawValue])
            }
        }
        created.forEach { assertions[$0.key] = $0.value }

        var dropped: [IOPMAssertionID] = []
        for scope in toDrop {
            if let assertionID = assertions.removeValue(forKey: scope) {
                dropped.append(assertionID)
            }
        }
        lock.unlock()

        dropped.forEach { IOPMAssertionRelease($0) }
        if !toCreate.isEmpty || !toDrop.isEmpty { changed = true }
        if changed { onChange?(snapshot) }

        if snapshot.isEmpty { stopTimer() }
    }

    private static func createAssertion(scope: KeepAwakeScope) -> IOPMAssertionID? {
        var assertionID: IOPMAssertionID = 0
        let rc = IOPMAssertionCreateWithName(
            scope.assertionType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "display-cli: \(scope.rawValue) keep-awake" as CFString,
            &assertionID
        )
        guard rc == kIOReturnSuccess else { return nil }
        Log.debug("assertion created", ["scope": scope.rawValue, "id": "\(assertionID)"])
        return assertionID
    }

    // MARK: - Timer

    private func startTimerIfNeeded() {
        lock.lock()
        let alreadyRunning = timer != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.runMaintenance() }
        t.resume()

        lock.lock()
        timer = t
        lock.unlock()
    }

    private func stopTimer() {
        lock.lock()
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
    }
}
