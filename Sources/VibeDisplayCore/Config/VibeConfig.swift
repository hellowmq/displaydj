import Foundation

/// Lifecycle states of an agent task. Phase transitions are what drive
/// brightness and keep-awake changes — nothing else does.
///
/// ```text
///   idle ──begin──▶ starting ──▶ running ⇄ waiting
///                                  │          │
///                                  └── end ───┴──▶ succeeded | failed ──▶ idle
/// ```
public enum AgentPhase: String, Codable, CaseIterable, Sendable {
    case idle
    case starting
    case running
    case waiting     // blocked on human input / review
    case succeeded
    case failed

    public var isTerminal: Bool { self == .succeeded || self == .failed || self == .idle }

    /// Aliases accepted on the CLI and HTTP API.
    public static func parse(_ raw: String) throws -> AgentPhase {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "idle", "none": return .idle
        case "start", "starting", "begin": return .starting
        case "run", "running", "progress", "working": return .running
        case "wait", "waiting", "blocked", "review": return .waiting
        case "success", "succeeded", "ok", "done", "pass": return .succeeded
        case "fail", "failed", "error", "fatal": return .failed
        default:
            throw VibeError(.invalidArgument, "unknown phase '\(raw)'",
                            hint: "one of: \(AgentPhase.allCases.map(\.rawValue).joined(separator: ", "))")
        }
    }
}

/// What should happen to the machine when a task enters a phase.
public struct PhaseProfile: Codable, Equatable, Sendable {
    /// Brightness expression: `0.7`, `70%`, `+10%`, `restore`, or `null` to
    /// leave brightness untouched for this phase.
    public var brightness: String?
    /// Which displays this phase targets. Defaults to the global default.
    public var selector: String?
    public var rampMs: Int?
    /// Keep-awake scopes to hold while in this phase. Empty = release.
    public var keepAwake: [KeepAwakeScope]
    public var keepAwakeTTLSeconds: Int?
    public var requireACPower: Bool?
    public var activeWindow: String?

    public init(brightness: String? = nil,
                selector: String? = nil,
                rampMs: Int? = nil,
                keepAwake: [KeepAwakeScope] = [],
                keepAwakeTTLSeconds: Int? = nil,
                requireACPower: Bool? = nil,
                activeWindow: String? = nil) {
        self.brightness = brightness
        self.selector = selector
        self.rampMs = rampMs
        self.keepAwake = keepAwake
        self.keepAwakeTTLSeconds = keepAwakeTTLSeconds
        self.requireACPower = requireACPower
        self.activeWindow = activeWindow
    }
}

public struct DaemonConfig: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var requireToken: Bool
    /// Seconds. A session with no heartbeat for this long is force-ended and
    /// its brightness restored. The backstop against a crashed agent.
    public var sessionReaperTTLSeconds: Int

    public init(host: String = "127.0.0.1",
                port: Int = 7643,
                requireToken: Bool = true,
                sessionReaperTTLSeconds: Int = 900) {
        self.host = host
        self.port = port
        self.requireToken = requireToken
        self.sessionReaperTTLSeconds = sessionReaperTTLSeconds
    }
}

public struct DisplayOverride: Codable, Equatable, Sendable {
    /// Force a specific external `DCPAVServiceProxy` slot for DDC.
    public var ddcServiceIndex: Int?
    /// Never touch this display.
    public var exclude: Bool?
    /// Clamp applied brightness to this range.
    public var minBrightness: Double?
    public var maxBrightness: Double?

    public init(ddcServiceIndex: Int? = nil,
                exclude: Bool? = nil,
                minBrightness: Double? = nil,
                maxBrightness: Double? = nil) {
        self.ddcServiceIndex = ddcServiceIndex
        self.exclude = exclude
        self.minBrightness = minBrightness
        self.maxBrightness = maxBrightness
    }
}

/// Top-level config, read from `~/.displaydj/config.json`.
public struct VibeConfig: Codable, Equatable, Sendable {
    public var version: Int
    public var defaultSelector: String
    public var defaultRampMs: Int
    public var daemon: DaemonConfig
    public var phases: [String: PhaseProfile]
    /// Keyed by display slug or uuid.
    public var displays: [String: DisplayOverride]

    public init(version: Int = 1,
                defaultSelector: String = "all",
                defaultRampMs: Int = 400,
                daemon: DaemonConfig = DaemonConfig(),
                phases: [String: PhaseProfile] = VibeConfig.defaultPhases,
                displays: [String: DisplayOverride] = [:]) {
        self.version = version
        self.defaultSelector = defaultSelector
        self.defaultRampMs = defaultRampMs
        self.daemon = daemon
        self.phases = phases
        self.displays = displays
    }

    /// Opinionated but conservative defaults:
    /// * agent starts → nudge brightness up a little, hold the screen awake
    /// * agent needs you → bright, so you notice
    /// * agent finished → put brightness back exactly where the user had it
    public static let defaultPhases: [String: PhaseProfile] = [
        AgentPhase.starting.rawValue: PhaseProfile(
            brightness: "70%", rampMs: 400,
            keepAwake: [.display], keepAwakeTTLSeconds: 300
        ),
        AgentPhase.running.rawValue: PhaseProfile(
            brightness: "45%", rampMs: 1200,
            keepAwake: [.display], keepAwakeTTLSeconds: 300
        ),
        AgentPhase.waiting.rawValue: PhaseProfile(
            brightness: "85%", rampMs: 250,
            keepAwake: [.display], keepAwakeTTLSeconds: 900
        ),
        AgentPhase.succeeded.rawValue: PhaseProfile(
            brightness: "restore", rampMs: 600, keepAwake: []
        ),
        AgentPhase.failed.rawValue: PhaseProfile(
            brightness: "restore", rampMs: 200, keepAwake: []
        ),
        AgentPhase.idle.rawValue: PhaseProfile(
            brightness: "restore", rampMs: 600, keepAwake: []
        )
    ]

    public func profile(for phase: AgentPhase) -> PhaseProfile {
        phases[phase.rawValue] ?? VibeConfig.defaultPhases[phase.rawValue] ?? PhaseProfile()
    }

    public func validate() throws {
        guard version == 1 else {
            throw VibeError(.configInvalid, "unsupported config version \(version)", hint: "expected 1")
        }
        guard daemon.port > 0, daemon.port < 65536 else {
            throw VibeError(.configInvalid, "daemon.port \(daemon.port) is out of range")
        }
        for (name, profile) in phases {
            _ = try AgentPhase.parse(name)
            if let b = profile.brightness {
                _ = try BrightnessTarget.parse(b)
            }
        }
        for (key, override) in displays {
            if let lo = override.minBrightness, lo < 0 || lo > 1 {
                throw VibeError(.configInvalid, "displays.\(key).minBrightness must be 0.0-1.0")
            }
            if let hi = override.maxBrightness, hi < 0 || hi > 1 {
                throw VibeError(.configInvalid, "displays.\(key).maxBrightness must be 0.0-1.0")
            }
        }
    }
}

public enum ConfigLoader {
    /// Load config, falling back to defaults when the file is absent.
    /// A *malformed* file is an error — silently ignoring it would make an
    /// agent's brightness behaviour mysteriously wrong.
    public static func load(from url: URL = Paths.configFile) throws -> VibeConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return VibeConfig()
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VibeError(.ioFailure, "cannot read config at \(url.path): \(error.localizedDescription)")
        }
        do {
            let config = try JSONCoding.decoder.decode(VibeConfig.self, from: data)
            try config.validate()
            return config
        } catch let err as VibeError {
            throw err
        } catch {
            throw VibeError(.configInvalid, "config at \(url.path) is not valid: \(error)",
                            hint: "delete it to fall back to defaults, or run `display-cli config init --force`")
        }
    }

    public static func save(_ config: VibeConfig, to url: URL = Paths.configFile) throws {
        try config.validate()
        let data = try JSONCoding.encoder.encode(config)
        try Paths.writeSecure(data, to: url)
    }
}
