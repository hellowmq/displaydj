import Foundation
import IOKit.pwr_mgt
import IOKit.ps

/// What exactly we are keeping awake.
public enum KeepAwakeScope: String, Codable, CaseIterable, Sendable {
    /// Screen stays lit. The one agents usually want.
    case display
    /// Machine will not idle-sleep, screen may still dim.
    case system
    /// Disks stay spun up (relevant for long build/IO tasks).
    case disk

    /// IOKit assertion type string. These are `CFSTR` macros in IOPMLib.h and
    /// therefore not importable into Swift — the literals are the public,
    /// documented values.
    var assertionType: String {
        switch self {
        case .display: return "PreventUserIdleDisplaySleep"
        case .system: return "PreventUserIdleSystemSleep"
        case .disk: return "PreventDiskIdle"
        }
    }
}

/// Conditions under which a lease is allowed to stay alive.
///
/// Directly modelled on Caffeine's cache policy vocabulary:
/// `expireAfterWrite` maps to `ttl`, a heartbeat is a `refresh`, and the
/// maintenance pass is the `eviction` cycle. The point is the same — an entry
/// nobody keeps touching must go away by itself, so a crashed agent can never
/// pin the display awake forever.
public struct KeepAwakePolicy: Codable, Equatable, Sendable {
    /// Seconds without a heartbeat before the lease is evicted.
    public var ttlSeconds: Int
    /// Hard ceiling regardless of heartbeats. `nil` = unbounded.
    public var maxDurationSeconds: Int?
    /// Suspend the lease while running on battery.
    public var requireACPower: Bool
    /// Suspend the lease outside this local-time window, e.g. `"09:00-20:00"`.
    public var activeWindow: String?

    public init(ttlSeconds: Int = 300,
                maxDurationSeconds: Int? = 4 * 3600,
                requireACPower: Bool = false,
                activeWindow: String? = nil) {
        self.ttlSeconds = max(5, ttlSeconds)
        self.maxDurationSeconds = maxDurationSeconds
        self.requireACPower = requireACPower
        self.activeWindow = activeWindow
    }

    public static let `default` = KeepAwakePolicy()

    /// Evaluate the non-time conditions. A lease that fails this is *suspended*
    /// (assertion dropped) but not evicted — it resumes when conditions return.
    public func conditionsSatisfied(now: Date = Date()) -> (ok: Bool, reason: String?) {
        if requireACPower, !PowerSource.isOnACPower() {
            return (false, "running on battery and policy requires AC power")
        }
        if let window = activeWindow, !Self.isWithin(window: window, at: now) {
            return (false, "outside active window \(window)")
        }
        return (true, nil)
    }

    /// `"HH:mm-HH:mm"`, wrapping past midnight is supported.
    static func isWithin(window: String, at date: Date) -> Bool {
        let parts = window.split(separator: "-")
        guard parts.count == 2,
              let start = minutes(from: String(parts[0])),
              let end = minutes(from: String(parts[1])) else { return true }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        let now = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return start <= end ? (now >= start && now < end) : (now >= start || now < end)
    }

    private static func minutes(from token: String) -> Int? {
        let hm = token.split(separator: ":")
        guard hm.count == 2, let h = Int(hm[0]), let m = Int(hm[1]) else { return nil }
        return h * 60 + m
    }
}

/// One logical reservation on staying awake.
public struct KeepAwakeLease: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let owner: String
    public let scope: KeepAwakeScope
    public let reason: String
    public let createdAt: Date
    public var lastRenewedAt: Date
    public var expiresAt: Date
    public var renewCount: Int
    public var policy: KeepAwakePolicy
    public var suspended: Bool
    public var suspendedReason: String?

    public var remainingSeconds: Int { max(0, Int(expiresAt.timeIntervalSinceNow)) }
    public var ageSeconds: Int { max(0, Int(Date().timeIntervalSince(createdAt))) }
}

/// AC vs battery, via IOKit power sources.
enum PowerSource {
    static func isOnACPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        guard let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String? else { return true }
        return type == "AC Power"
    }
}
