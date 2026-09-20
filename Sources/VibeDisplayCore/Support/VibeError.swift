import Foundation

/// Every failure surfaced by display-cli carries a stable machine-readable
/// `code`. Agents branch on `code`; humans read `message`.
public struct VibeError: Error, Codable, CustomStringConvertible, Sendable {
    public let code: Code
    public let message: String
    public let hint: String?

    public enum Code: String, Codable, Sendable {
        case displayNotFound = "display_not_found"
        case routeNotFound = "route_not_found"
        case ambiguousSelector = "ambiguous_selector"
        case unsupportedOperation = "unsupported_operation"
        case backendFailure = "backend_failure"
        case invalidArgument = "invalid_argument"
        case sessionNotFound = "session_not_found"
        case sessionConflict = "session_conflict"
        case daemonUnavailable = "daemon_unavailable"
        case daemonAlreadyRunning = "daemon_already_running"
        case unauthorized = "unauthorized"
        case configInvalid = "config_invalid"
        case ioFailure = "io_failure"
        case notImplemented = "not_implemented"
    }

    public init(_ code: Code, _ message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }

    public var description: String {
        if let hint { return "[\(code.rawValue)] \(message) — \(hint)" }
        return "[\(code.rawValue)] \(message)"
    }

    /// Process exit code. Kept stable so shell-based agents can branch on it.
    public var exitCode: Int32 {
        switch code {
        case .invalidArgument, .configInvalid, .ambiguousSelector: return 2
        case .displayNotFound, .sessionNotFound, .routeNotFound: return 3
        case .unsupportedOperation, .notImplemented: return 4
        case .daemonUnavailable, .daemonAlreadyRunning: return 5
        case .unauthorized: return 6
        default: return 1
        }
    }
}
