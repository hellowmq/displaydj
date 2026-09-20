import Foundation

/// One agent task's claim on the machine's display state.
public struct AgentSession: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    /// Human label, e.g. `"claude: refactor auth module"`.
    public var label: String
    /// Which tool created the session — `codex`, `cursor`, `claude-code`, ...
    public var client: String
    /// Free-form note from the most recent phase transition, e.g. why the
    /// agent moved to `waiting`. `nil` until a transition carries one.
    public var note: String?
    public var phase: AgentPhase
    public var selector: String
    public let createdAt: Date
    public var updatedAt: Date
    /// Force-ended if no heartbeat arrives before this.
    public var expiresAt: Date
    public var heartbeatCount: Int
    public var keepAwakeLeaseIDs: [String]
    /// Brightness this session recorded before it changed anything.
    public var snapshot: [String: Double]
    public var transitions: [PhaseTransition]
    public var metadata: [String: String]
    /// Set when the reaper (not the client) ended the session.
    public var endedBy: String?

    public struct PhaseTransition: Codable, Equatable, Sendable {
        public let from: AgentPhase
        public let to: AgentPhase
        public let at: Date
        public let note: String?

        public init(from: AgentPhase, to: AgentPhase, at: Date = Date(), note: String? = nil) {
            self.from = from
            self.to = to
            self.at = at
            self.note = note
        }
    }

    public var isActive: Bool { !phase.isTerminal }
    public var ageSeconds: Int { max(0, Int(Date().timeIntervalSince(createdAt))) }
    public var staleSeconds: Int { max(0, Int(Date().timeIntervalSince(updatedAt))) }

    public init(id: String,
                label: String,
                client: String,
                phase: AgentPhase,
                selector: String,
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                expiresAt: Date,
                heartbeatCount: Int = 0,
                keepAwakeLeaseIDs: [String] = [],
                snapshot: [String: Double] = [:],
                transitions: [PhaseTransition] = [],
                metadata: [String: String] = [:],
                note: String? = nil,
                endedBy: String? = nil) {
        self.id = id
        self.label = label
        self.client = client
        self.note = note
        self.phase = phase
        self.selector = selector
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.heartbeatCount = heartbeatCount
        self.keepAwakeLeaseIDs = keepAwakeLeaseIDs
        self.snapshot = snapshot
        self.transitions = transitions
        self.metadata = metadata
        self.endedBy = endedBy
    }
}

/// Result of a phase application — returned to the agent so it can log or
/// assert on what actually happened.
public struct PhaseApplyReport: Codable, Equatable, Sendable {
    public let session: AgentSession
    public let brightness: [BrightnessApplyResult]
    public let keepAwake: [KeepAwakeLease]
    public let warnings: [String]

    public init(session: AgentSession,
                brightness: [BrightnessApplyResult],
                keepAwake: [KeepAwakeLease],
                warnings: [String] = []) {
        self.session = session
        self.brightness = brightness
        self.keepAwake = keepAwake
        self.warnings = warnings
    }
}
