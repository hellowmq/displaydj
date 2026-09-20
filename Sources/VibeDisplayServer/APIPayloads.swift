import Foundation
import VibeDisplayCore

// MARK: - Responses

public struct HealthPayload: Codable {
    public let status: String
    public let version: String
    public let apiVersion: String
    public let pid: Int32
    public let uptimeSeconds: Int
    public let activeSessions: Int
    public let activeLeases: Int
}

public struct DisplaysPayload: Codable {
    public let displays: [DisplayInfo]
    public let count: Int
}

public struct BrightnessPayload: Codable {
    public let readings: [BrightnessReading]
}

public struct ApplyPayload: Codable {
    public let results: [BrightnessApplyResult]
}

public struct LeasesPayload: Codable {
    public let leases: [KeepAwakeLease]
    public let activeScopes: [KeepAwakeScope]
}

public struct SessionsPayload: Codable {
    public let sessions: [AgentSession]
}

public struct SessionPayload: Codable {
    public let session: AgentSession
}

public struct RoutesPayload: Codable {
    public let service: String
    public let version: String
    public let routes: [String]
}

// MARK: - Requests

public struct ApplyBrightnessRequest: Codable {
    public var selector: String?
    /// `0.5`, `50%`, `+10%`, `restore`
    public var target: String
    public var rampMs: Int?
}

public struct SetBrightnessRequest: Codable {
    public var value: Double
    public var rampMs: Int?
}

public struct CreateLeaseRequest: Codable {
    public var scope: KeepAwakeScope?
    public var reason: String?
    public var owner: String?
    public var ttlSeconds: Int?
    public var maxDurationSeconds: Int?
    public var requireACPower: Bool?
    public var activeWindow: String?
}

public struct BeginSessionRequest: Codable {
    public var label: String?
    public var client: String?
    public var selector: String?
    public var ttlSeconds: Int?
    public var phase: String?
    public var metadata: [String: String]?
}

public struct PhaseRequest: Codable {
    public var phase: String
    public var note: String?
    public var ttlSeconds: Int?
}
