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
    private var snapshots: [String: Double] = [:]
    /// Backend actually chosen for a display, keyed by uuid.
    private var boundTransport: [String: BrightnessTransport] = [:]
    /// Where auto-snapshots are persisted so a fresh process can still restore.
    private let store: StateStore

    public init(registry: DisplayRegistry = .shared, store: StateStore = .shared) {
        self.registry = registry
        self.store = store
        self.displayServices = DisplayServicesBackend()
        self.ddc = DDCBackend()
        self.gamma = GammaBackend()
    }

    /// Priority order. First backend that claims the display wins.
    private var backends: [BrightnessBackend] { [displayServices, ddc, gamma] }

    // MARK: - Capability probing

    public func capability(for display: DisplayInfo, forceRefresh: Bool = false) -> DisplayCapability {
        lock.lock()
        if !forceRefresh, let cached = capabilityCache[display.uuid] {
            lock.unlock()
            return cached
        }
        lock.unlock()

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
        let backend = backend(for: display)
        if let expectedTransport, backend.transport != expectedTransport {
            return BrightnessApplyResult(displayUUID: display.uuid, slug: display.slug, requested: 0, applied: nil,
                                         transport: backend.transport, ok: false, error: "transport changed before write")
        }
        let current = backend.read(display)
        guard let current else {
            return BrightnessApplyResult(displayUUID: display.uuid, slug: display.slug, requested: 0, applied: nil,
                                         transport: backend.transport, ok: false, error: "cannot read a trustworthy baseline")
        }

        // Invariant: snapshot before the first mutation. A direct `brightness
        // set` outside any agent session must still be restorable, so the
        // pre-change value is recorded (memory + disk) the first time a
        // display is written. `restore` targets never snapshot — they are the
        // undo, not the edit.
        var snapshotTaken = false
        if case .restoreSnapshot = target {
            snapshotTaken = false
        } else {
            snapshotTaken = recordSnapshotIfNeeded(display, current: current)
        }

        let requested: Double
        switch target {
        case .absolute(let v):
            requested = v.clampedBrightness
        case .relative(let delta):
            let base = current
            requested = (base + delta).clampedBrightness
        case .restoreSnapshot:
            lock.lock()
            let saved = snapshots[display.uuid]
            lock.unlock()
            guard let saved else {
                return BrightnessApplyResult(displayUUID: display.uuid, slug: display.slug,
                                             previous: current, requested: current, applied: current,
                                             transport: backend.transport, ok: false,
                                             error: "no snapshot recorded for this display")
            }
            requested = saved
        }

        let wrote = performWrite(backend: backend, display: display,
                              from: current, to: requested, ramp: ramp)

        let observed = wrote ? backend.read(display) : nil
        let ok = wrote && observed != nil

        if ok, case .restoreSnapshot = target {
            lock.lock()
            snapshots.removeValue(forKey: display.uuid)
            lock.unlock()
            store.mutate { $0.brightnessSnapshots.removeValue(forKey: display.uuid) }
            if backend.transport == .gamma { gamma.release(display) }
        }

        return BrightnessApplyResult(
            displayUUID: display.uuid,
            slug: display.slug,
            previous: current,
            requested: requested,
            applied: observed,
            transport: backend.transport,
            ok: ok,
            snapshotTaken: snapshotTaken,
            error: ok ? nil : "backend \(backend.transport.rawValue) rejected the write"
        )
    }

    /// Record the pre-mutation value for a display that has never been touched.
    /// Idempotent (first writer wins, so nested sessions cannot clobber the
    /// user's original) and persisted so `restore` works after a process exit.
    private func recordSnapshotIfNeeded(_ display: DisplayInfo, current: Double) -> Bool {
        lock.lock()
        let isFirst = snapshots[display.uuid] == nil
        if isFirst { snapshots[display.uuid] = current }
        lock.unlock()
        if isFirst {
            store.mutate { state in
                if state.brightnessSnapshots[display.uuid] == nil {
                    state.brightnessSnapshots[display.uuid] = current
                }
            }
        }
        return isFirst
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

    /// Record current brightness so a later `.restoreSnapshot` can put it back.
    /// Idempotent: re-snapshotting an already-snapshotted display is a no-op,
    /// so nested agent sessions cannot clobber the user's original value.
    @discardableResult
    public func snapshot(_ selector: DisplaySelector) throws -> [String: Double] {
        let displays = try selector.resolve(in: registry.displays())
        var taken: [String: Double] = [:]
        for display in displays {
            lock.lock()
            let already = snapshots[display.uuid] != nil
            lock.unlock()
            if already { continue }
            guard let value = backend(for: display).read(display) else { continue }
            lock.lock()
            snapshots[display.uuid] = value
            lock.unlock()
            taken[display.uuid] = value
        }
        return taken
    }

    public func snapshotValues() -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        return snapshots
    }

    public func seedSnapshots(_ values: [String: Double]) {
        lock.lock(); defer { lock.unlock() }
        for (k, v) in values where snapshots[k] == nil {
            snapshots[k] = v
        }
    }

    public func clearSnapshots() {
        lock.lock(); defer { lock.unlock() }
        snapshots.removeAll()
    }

    /// Put everything back and drop all gamma tables. The last thing the daemon
    /// does before exiting.
    @discardableResult
    public func restoreAll(ramp: BrightnessRamp = .smooth) -> [BrightnessApplyResult] {
        lock.lock()
        var pending = snapshots
        lock.unlock()

        // A fresh process (or a daemon that restarted) has no in-memory record
        // of what the user's screen looked like. Recover the snapshots the
        // previous process persisted, so `restore` still lands exactly where
        // it started even across process boundaries.
        seedSnapshots(store.load().brightnessSnapshots)
        lock.lock()
        pending = snapshots
        lock.unlock()

        var results: [BrightnessApplyResult] = []
        let displays = registry.displays(forceRefresh: true)
        for (uuid, _) in pending {
            guard let display = displays.first(where: { $0.uuid == uuid }) else { continue }
            results.append(apply(.restoreSnapshot, to: display, ramp: ramp))
        }
        // Failed and unplugged displays retain their recovery points for a later retry.
        let restored = Set(results.filter(\.ok).map(\.displayUUID))
        store.mutate { state in
            for uuid in restored { state.brightnessSnapshots.removeValue(forKey: uuid) }
        }
        return results
    }
}
