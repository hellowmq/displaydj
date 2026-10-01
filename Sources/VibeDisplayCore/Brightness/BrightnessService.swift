import Foundation

/// What a caller wants the brightness to become.
public enum BrightnessTarget: Equatable, Sendable {
    case absolute(Double)          // 0...1
    case relative(Double)          // signed delta applied to the current value
    case restoreSnapshot           // whatever was recorded by `snapshot()`

    /// Parse `0.4`, `40%`, `+10%`, `-0.15`, `restore`.
    public static func parse(_ raw: String) throws -> BrightnessTarget {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "restore" { return .restoreSnapshot }

        let signed = s.hasPrefix("+") || s.hasPrefix("-")
        var body = s
        var isPercent = false
        if body.hasSuffix("%") {
            isPercent = true
            body.removeLast()
        }
        guard let number = Double(body), number.isFinite else {
            throw VibeError(.invalidArgument, "cannot parse brightness '\(raw)'",
                            hint: "use 0.0-1.0, 0-100%, or a signed delta like +10%")
        }
        let value = isPercent ? number / 100.0 : number
        if signed { return .relative(value) }
        guard value >= 0, value <= 1 else {
            throw VibeError(.invalidArgument, "brightness \(raw) is out of range",
                            hint: "absolute values must be within 0.0-1.0 (or 0-100%)")
        }
        return .absolute(value)
    }
}

/// How the change is delivered over time.
public struct BrightnessRamp: Equatable, Sendable {
    public let durationMs: Int
    public let steps: Int

    public static let instant = BrightnessRamp(durationMs: 0, steps: 1)
    public static let smooth = BrightnessRamp(durationMs: 400, steps: 16)

    public init(durationMs: Int, steps: Int = 16) {
        self.durationMs = max(0, durationMs)
        self.steps = max(1, steps)
    }
}

/// Front door for all brightness work: probes backends, picks a transport per
/// display, applies values, and keeps the snapshot used by session restore.
public final class BrightnessService {
    public static let shared = BrightnessService()

    private let registry: DisplayRegistry
    public let displayServices: DisplayServicesBackend
    public let ddc: DDCBackend
    public let gamma: GammaBackend

    private let lock = NSLock()
    private var capabilityCache: [String: DisplayCapability] = [:]
    /// Backend actually chosen for a display, keyed by uuid.
    private var boundTransport: [String: BrightnessTransport] = [:]
    /// Where auto-snapshots are persisted so a fresh process can still restore.
    private let store: StateStore
    let coordinator: BrightnessCoordinator
    private var injectedBackends: [BrightnessBackend]?

    public init(registry: DisplayRegistry = .shared, store: StateStore = .shared) {
        self.registry = registry
        self.store = store
        self.coordinator = BrightnessCoordinator(store: store)
        self.displayServices = DisplayServicesBackend()
        self.ddc = DDCBackend()
        self.gamma = GammaBackend()
    }

    /// Priority order. First backend that claims the display wins.
    private var backends: [BrightnessBackend] { injectedBackends ?? [displayServices, ddc, gamma] }

    convenience init(registry: DisplayRegistry, store: StateStore, backends: [BrightnessBackend]) {
        self.init(registry: registry, store: store)
        injectedBackends = backends
    }

    // MARK: - Capability probing

    public func capability(for display: DisplayInfo, forceRefresh: Bool = false) -> DisplayCapability {
        lock.lock()
        if !forceRefresh, let cached = capabilityCache[display.uuid] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        if let injectedBackends {
            let transports = injectedBackends.filter { $0.supports(display) }.map(\.transport)
            return DisplayCapability(canReadBrightness: !transports.isEmpty,
                canWriteBrightness: !transports.isEmpty, transports: transports, preferred: transports.first ?? .none, notes: [])
        }

        var transports: [BrightnessTransport] = []
        var notes: [String] = []

        if displayServices.supports(display) {
            transports.append(.displayServices)
        } else if display.isBuiltin, !displayServices.isAvailable {
            notes.append("DisplayServices private framework unavailable on this macOS build")
        }

        if ddc.supports(display) {
            transports.append(.ddc)
        } else if !display.isBuiltin {
            #if arch(arm64)
            notes.append("DDC/CI read was unavailable to this app; this does not establish a cable, hub, or monitor limitation")
            #else
            notes.append("DDC on Intel Macs is not implemented yet (roadmap: ddc-intel)")
            #endif
        }

        transports.append(.gamma)
        if transports.count == 1 {
            notes.append("hardware backlight control unavailable; using software gamma dimming, which requires `display-cli serve` to persist")
        }

        let preferred = transports.first ?? .none
        let canRead = preferred == .displayServices
            || (preferred == .ddc && ddc.read(display) != nil)
            || preferred == .gamma

        let cap = DisplayCapability(
            canReadBrightness: canRead,
            canWriteBrightness: preferred != .none,
            transports: transports,
            preferred: preferred,
            notes: notes
        )

        lock.lock()
        capabilityCache[display.uuid] = cap
        boundTransport[display.uuid] = preferred
        lock.unlock()
        return cap
    }

    /// Displays enriched with probed capabilities.
    public func inventory(forceRefresh: Bool = false) -> [DisplayInfo] {
        registry.displays(forceRefresh: forceRefresh).map { display in
            var copy = display
            copy.capability = capability(for: display, forceRefresh: forceRefresh)
            return copy
        }
    }

    public func invalidate() {
        lock.lock()
        capabilityCache.removeAll()
        boundTransport.removeAll()
        lock.unlock()
        registry.invalidate()
    }

    private func backend(for display: DisplayInfo) -> BrightnessBackend {
        let preferred = capability(for: display).preferred
        return backends.first { $0.transport == preferred } ?? gamma
    }

    // MARK: - Read

    public func read(_ selector: DisplaySelector) throws -> [BrightnessReading] {
        let targets = try selector.resolve(in: registry.displays())
        return try targets.map { display in
            let backend = backend(for: display)
            guard let value = backend.read(display) else {
                throw VibeError(.backendFailure, "cannot read brightness for \(display.slug) via \(backend.transport.rawValue)")
            }
            return BrightnessReading(displayUUID: display.uuid,
                                     slug: display.slug,
                                     value: value,
                                     transport: backend.transport)
        }
    }

    public func readOne(_ display: DisplayInfo) -> Double? {
        backend(for: display).read(display)
    }

    /// Explicit software dimming. It changes gamma tables, never panel backlight.
    /// The caller must live in the resident daemon for the effect to persist.
    public func softwareDimming(_ selector: DisplaySelector) throws -> [BrightnessReading] {
        let displays = try selector.resolve(in: registry.displays(forceRefresh: true))
        guard !displays.isEmpty else { throw VibeError(.displayNotFound, "no display for software dimming") }
        return displays.map { display in
            BrightnessReading(displayUUID: display.uuid, slug: display.slug,
                              value: gamma.read(display) ?? 1, transport: .gamma)
        }
    }

    public func setSoftwareDimming(_ value: Double, to selector: DisplaySelector) throws -> [BrightnessApplyResult] {
        guard value.isFinite, (GammaBackend.floor...1).contains(value) else {
            throw VibeError(.invalidArgument, "software dimming must be between 8% and 100%; use off to restore colors")
        }
        let displays = try selector.resolve(in: registry.displays(forceRefresh: true))
        guard !displays.isEmpty else { throw VibeError(.displayNotFound, "no display for software dimming") }
        return try displays.map { display in
            try coordinator.transaction {
                try coordinator.takeManualControl(stableID: display.uuid)
                let previous = gamma.read(display) ?? 1
                let wrote = gamma.write(display, value: value)
                let observed = gamma.read(display)
                let ok = wrote && observed.map { abs($0 - value) <= 0.001 } == true
                return BrightnessApplyResult(displayUUID: display.uuid, slug: display.slug,
                                             previous: previous, requested: value, applied: observed,
                                             transport: .gamma, ok: ok,
                                             error: ok ? nil : "software dimming was not applied")
            }
        }
    }

    public func stopSoftwareDimming(_ selector: DisplaySelector) throws -> [BrightnessApplyResult] {
        let displays = try selector.resolve(in: registry.displays(forceRefresh: true))
        guard !displays.isEmpty else { throw VibeError(.displayNotFound, "no display for software dimming") }
        return try displays.map { display in
            try coordinator.transaction {
                try coordinator.takeManualControl(stableID: display.uuid)
                let previous = gamma.read(display) ?? 1
                gamma.release(display)
                return BrightnessApplyResult(displayUUID: display.uuid, slug: display.slug,
                                             previous: previous, requested: 1, applied: 1,
                                             transport: .gamma, ok: true)
            }
        }
    }

    // MARK: - Write

    @discardableResult
    public func apply(_ target: BrightnessTarget,
                      to selector: DisplaySelector,
                      ramp: BrightnessRamp = .instant) throws -> [BrightnessApplyResult] {
        let displays = try selector.resolve(in: registry.displays())
        guard !displays.isEmpty else {
            throw VibeError(.displayNotFound, "selector '\(selector.rawValue)' matched no displays")
        }
        return displays.map { apply(target, to: $0, ramp: ramp) }
    }

    public func apply(_ target: BrightnessTarget,
                      to display: DisplayInfo,
                      ramp: BrightnessRamp = .instant,
                      expectedTransport: BrightnessTransport? = nil) -> BrightnessApplyResult {
        apply(target, to: display, ramp: ramp, expectedTransport: expectedTransport, origin: .manual)
    }

    func apply(_ target: BrightnessTarget, to display: DisplayInfo,
               ramp: BrightnessRamp = .instant, expectedTransport: BrightnessTransport? = nil,
               origin: BrightnessWriteOrigin) -> BrightnessApplyResult {
        do {
            return try coordinator.transaction {
                try applyCoordinated(target, to: display, ramp: ramp,
                                     expectedTransport: expectedTransport, origin: origin)
              }
        } catch {
            return BrightnessApplyResult(displayUUID: display.uuid, slug: display.slug,
                requested: 0, applied: nil, transport: expectedTransport ?? .none, ok: false,
                error: "brightness control refused: \(error)")
        }
    }

    func applyCoordinated(_ target: BrightnessTarget, to display: DisplayInfo,
                                 ramp: BrightnessRamp, expectedTransport: BrightnessTransport?,
                                 origin: BrightnessWriteOrigin) throws -> BrightnessApplyResult {
        let state = try coordinator.freshState()
        let key = BrightnessCoordinator.key(display.uuid)
        let ownership = state.brightnessSnapshotOwnership?[display.uuid]
        var skip: String?
        switch origin {
        case .manual: break
        case .agent(let sessionID, let revisions):
            if revisions[key] == nil {
                skip = "unclaimed_display"
            } else if revisions[key] != state.brightnessRevisions?[key] {
                skip = "manual_override"
            } else if case .restoreSnapshot = target {
                if ownership?.revision != revisions[key] || ownership?.sessionID == nil {
                    skip = "recovery_not_owned"
                } else if state.sessions.contains(where: {
                    $0.id != sessionID && $0.isActive && $0.brightnessRevisions?[key] == revisions[key]
                }) { skip = "another_session_active" }
            }
        case .automaticRestore:
            if ownership?.sessionID == nil || ownership?.revision != state.brightnessRevisions?[key] {
                skip = "recovery_not_owned"
            } else if state.sessions.contains(where: {
                $0.isActive && $0.brightnessRevisions?[key] == ownership?.revision
            }) { skip = "another_session_active" }
        }
        if let skip {
            let requested: Double
            if case .absolute(let value) = target { requested = value }
            else { requested = state.brightnessSnapshots[display.uuid] ?? 0 }
            return BrightnessApplyResult(displayUUID: display.uuid, slug: display.slug,
                requested: requested, applied: nil,
                transport: state.brightnessSnapshotTransports?[display.uuid] ?? .none,
                ok: true, skippedReason: skip)
        }

        // Lock acquisition may have waited behind another process. Re-resolve
        // the UUID before using a native runtime ID or selecting a backend.
        let matches = registry.displays(forceRefresh: true).filter { $0.uuid.lowercased() == display.uuid.lowercased() }
        guard matches.count == 1, let live = matches.first else {
            return BrightnessApplyResult(displayUUID: display.uuid, slug: display.slug,
                requested: 0, applied: nil, transport: .none, ok: false,
                error: "display is offline or ambiguous before brightness write")
        }
        let backend = backend(for: live)
        if let expectedTransport, backend.transport != expectedTransport {
            return BrightnessApplyResult(displayUUID: display.uuid, slug: display.slug, requested: 0, applied: nil,
                transport: backend.transport, ok: false, error: "transport changed before write")
        }
        // A session cannot migrate a recovery point to another transport.
        if case .agent = origin, let saved = state.brightnessSnapshotTransports?[display.uuid], saved != backend.transport {
            return BrightnessApplyResult(displayUUID: display.uuid, slug: display.slug, requested: 0, applied: nil,
                transport: backend.transport, ok: false, error: "snapshot transport changed; manual recovery required")
        }
        guard let current = backend.read(live), current.isFinite, (0...1).contains(current) else {
            return BrightnessApplyResult(displayUUID: display.uuid, slug: display.slug, requested: 0, applied: nil,
                transport: backend.transport, ok: false, error: "cannot read a trustworthy baseline")
        }

        let requested: Double
        var snapshotTaken = false
        switch target {
        case .restoreSnapshot:
            guard let saved = state.brightnessSnapshots[display.uuid] else {
                return BrightnessApplyResult(displayUUID: display.uuid, slug: display.slug, previous: current,
                    requested: current, applied: current, transport: backend.transport, ok: false,
                    error: "no snapshot recorded for this display")
            }
            guard state.brightnessSnapshotTransports?[display.uuid] == backend.transport else {
                return BrightnessApplyResult(displayUUID: display.uuid, slug: display.slug, previous: current,
                    requested: saved, applied: nil, transport: backend.transport, ok: false,
                    error: "snapshot transport is missing or changed; manual recovery required")
            }
            // Explicit restore is a manual action too: freeze old sessions, but
            // keep the recovery point until the hardware confirms restoration.
            if case .manual = origin {
                try store.mutateChecked {
                    var revisions = $0.brightnessRevisions ?? [:]
                    revisions[key] = UUID().uuidString
                    $0.brightnessRevisions = revisions
                }
            }
            requested = saved
        case .absolute(let value):
            requested = value.clampedBrightness
            snapshotTaken = try prepareWrite(display, current: current, transport: backend.transport, origin: origin)
        case .relative(let delta):
            requested = (current + delta).clampedBrightness
            snapshotTaken = try prepareWrite(display, current: current, transport: backend.transport, origin: origin)
        }

        let wrote = performWrite(backend: backend, display: live,
                                 from: current, to: requested, ramp: ramp)
        let observed = wrote ? backend.read(live) : nil
        let ok = wrote && observed.map { abs($0 - requested) <= 0.02 } == true
        if ok, case .restoreSnapshot = target {
            try store.mutateChecked { BrightnessCoordinator.removeSnapshot(display.uuid, from: &$0) }
            if backend.transport == .gamma { gamma.release(display) }
        }
        return BrightnessApplyResult(displayUUID: display.uuid, slug: display.slug,
            previous: current, requested: requested, applied: observed,
            transport: backend.transport, ok: ok, snapshotTaken: snapshotTaken,
            error: ok ? nil : "backend \(backend.transport.rawValue) did not confirm the requested brightness")
    }

    private func prepareWrite(_ display: DisplayInfo, current: Double,
                              transport: BrightnessTransport, origin: BrightnessWriteOrigin) throws -> Bool {
        if case .manual = origin {
            try coordinator.takeManualControl(stableID: display.uuid, retainingManualUndo: true)
        }
        let state = try coordinator.freshState()
        if state.brightnessSnapshots[display.uuid] != nil {
            guard state.brightnessSnapshotTransports?[display.uuid] == transport else {
                throw VibeError(.backendFailure, "existing recovery point uses another or unknown transport")
            }
            return false
        }
        let key = BrightnessCoordinator.key(display.uuid)
        let revision = state.brightnessRevisions?[key] ?? UUID().uuidString
        let sessionID: String?
        if case .agent(let id, _) = origin { sessionID = id } else { sessionID = nil }
        try store.mutateChecked { state in
            state.brightnessSnapshots[display.uuid] = current
            var transports = state.brightnessSnapshotTransports ?? [:]
            transports[display.uuid] = transport
            state.brightnessSnapshotTransports = transports
            var revisions = state.brightnessRevisions ?? [:]
            revisions[key] = revision
            state.brightnessRevisions = revisions
            var ownership = state.brightnessSnapshotOwnership ?? [:]
            ownership[display.uuid] = .init(revision: revision, sessionID: sessionID)
            state.brightnessSnapshotOwnership = ownership
        }
        return true
    }

    private func performWrite(backend: BrightnessBackend,
                              display: DisplayInfo,
                              from current: Double?,
                              to requested: Double,
                              ramp: BrightnessRamp) -> Bool {
        guard ramp.durationMs > 0, ramp.steps > 1, let start = current,
              abs(start - requested) > 0.01 else {
            return backend.write(display, value: requested)
        }
        let interval = UInt32(max(1, ramp.durationMs / ramp.steps) * 1000)
        var lastOK = false
        for step in 1...ramp.steps {
            let t = Double(step) / Double(ramp.steps)
            // easeInOutSine — visually gentler than linear at both ends.
            let eased = -(cos(Double.pi * t) - 1) / 2
            let value = start + (requested - start) * eased
            lastOK = backend.write(display, value: value)
            if !lastOK { return false }
            if step < ramp.steps { usleep(interval) }
        }
        return lastOK
    }

    // MARK: - Snapshot / restore

    /// Explicit snapshots are manual undo points, never automatic shutdown work.
    @discardableResult
    public func snapshot(_ selector: DisplaySelector) throws -> [String: Double] {
        try coordinator.transaction {
            var taken: [String: Double] = [:]
            for display in try selector.resolve(in: registry.displays()) {
                let chosen = backend(for: display)
                guard let value = chosen.read(display) else { continue }
                if try prepareWrite(display, current: value, transport: chosen.transport, origin: .manual) {
                    taken[display.uuid] = value
                }
            }
            return taken
        }
    }

    /// Capture claims for all configured phase targets once. A new display or a
    /// manual takeover never grants an old session fresh permission to write.
    func captureAgentSnapshots(_ selectors: [DisplaySelector], sessionID: String, excluding: Set<String> = [])
        throws -> (values: [String: Double], revisions: [String: String]) {
        try coordinator.transaction {
            var values: [String: Double] = [:]
            var revisions: [String: String] = [:]
            var targets: [String: DisplayInfo] = [:]
            for selector in selectors {
                for display in try selector.resolve(in: registry.displays()) { targets[display.uuid] = display }
            }
            for display in targets.values {
                if excluding.contains(display.uuid.lowercased()) || excluding.contains(display.slug.lowercased()) { continue }
                let chosen = backend(for: display)
                guard let current = chosen.read(display), current.isFinite, (0...1).contains(current) else { continue }
                let state = try coordinator.freshState()
                if state.brightnessSnapshots[display.uuid] != nil && state.brightnessSnapshotOwnership?[display.uuid] == nil {
                    throw VibeError(.sessionConflict, "legacy recovery point requires explicit restore or manual control before starting an Agent")
                }
                let key = BrightnessCoordinator.key(display.uuid)
                let revision = state.brightnessRevisions?[key] ?? UUID().uuidString
                let old = state.brightnessSnapshotOwnership?[display.uuid]
                let share = old?.sessionID != nil && old?.revision == revision
                if share && state.brightnessSnapshotTransports?[display.uuid] != chosen.transport {
                    throw VibeError(.backendFailure, "existing recovery point uses another transport")
                }
                let baseline = share ? (state.brightnessSnapshots[display.uuid] ?? current) : current
                try store.mutateChecked { state in
                    var rev = state.brightnessRevisions ?? [:]
                    rev[key] = revision
                    state.brightnessRevisions = rev
                    state.brightnessSnapshots[display.uuid] = baseline
                    var transports = state.brightnessSnapshotTransports ?? [:]
                    transports[display.uuid] = chosen.transport
                    state.brightnessSnapshotTransports = transports
                    var ownership = state.brightnessSnapshotOwnership ?? [:]
                    ownership[display.uuid] = .init(revision: revision, sessionID: share ? old?.sessionID : sessionID)
                    state.brightnessSnapshotOwnership = ownership
                }
                values[display.uuid] = baseline
                revisions[key] = revision
            }
            return (values, revisions)
        }
    }

    public func snapshotValues() -> [String: Double] {
        (try? coordinator.freshState().brightnessSnapshots) ?? [:]
    }

    public func snapshotTransportValues() -> [String: BrightnessTransport] {
        (try? coordinator.freshState().brightnessSnapshotTransports) ?? [:]
    }

    /// Compatibility helper for callers importing recovery points. Unowned
    /// points remain explicit-only until a new session captures a valid claim.
    public func seedSnapshots(_ values: [String: Double], transports: [String: BrightnessTransport] = [:]) {
        do {
              _ = try coordinator.transaction {
                try store.mutateChecked { state in
                    for (uuid, value) in values where state.brightnessSnapshots[uuid] == nil {
                        state.brightnessSnapshots[uuid] = value
                        var saved = state.brightnessSnapshotTransports ?? [:]
                        saved[uuid] = transports[uuid]
                        state.brightnessSnapshotTransports = saved
                    }
                }
              }
        } catch { Log.error("cannot import recovery points: \(error)") }
    }

    public func clearSnapshots() {
        do {
              _ = try coordinator.transaction {
                try store.mutateChecked { state in
                    for uuid in Array(state.brightnessSnapshots.keys) {
                        BrightnessCoordinator.removeSnapshot(uuid, from: &state)
                    }
                }
              }
        } catch { Log.error("cannot clear recovery points: \(error)") }
    }

    /// Explicit recovery may use legacy snapshots, but still checks transport.
    /// Automatic cleanup only restores recovery points owned by automation.
    public func restoreAll(ramp: BrightnessRamp = .smooth) -> [BrightnessApplyResult] {
        restoreAll(ramp: ramp, origin: .manual)
    }

    public func restoreAutomatic(ramp: BrightnessRamp = .instant) -> [BrightnessApplyResult] {
        restoreAll(ramp: ramp, origin: .automaticRestore)
    }

    private func restoreAll(ramp: BrightnessRamp, origin: BrightnessWriteOrigin) -> [BrightnessApplyResult] {
        do {
            return try coordinator.transaction {
                let persisted = try coordinator.freshState()
                return registry.displays(forceRefresh: true).compactMap { display in
                    guard persisted.brightnessSnapshots[display.uuid] != nil else { return nil }
                    do { return try applyCoordinated(.restoreSnapshot, to: display, ramp: ramp,
                                                   expectedTransport: nil, origin: origin) }
                    catch {
                        return BrightnessApplyResult(displayUUID: display.uuid, slug: display.slug,
                            requested: persisted.brightnessSnapshots[display.uuid] ?? 0, applied: nil,
                            transport: persisted.brightnessSnapshotTransports?[display.uuid] ?? .none,
                            ok: false, error: "cannot restore brightness: \(error)")
                    }
                }
              }
        } catch {
            Log.error("brightness restoration refused: \(error)")
            return [BrightnessApplyResult(displayUUID: "", slug: "control-state", requested: 0,
                applied: nil, transport: .none, ok: false, error: "cannot read recovery state: \(error)")]
        }
    }
}
