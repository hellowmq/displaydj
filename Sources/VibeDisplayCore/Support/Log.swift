import Foundation

/// Minimal, dependency-free structured logger.
///
/// Human mode writes `HH:mm:ss LEVEL message` to stderr.
/// JSON mode writes one JSON object per line to stderr — meant to be tailed by
/// an agent supervisor.
public enum Log {
    public enum Level: Int, Comparable, Sendable {
        case debug = 0, info = 1, warn = 2, error = 3

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .debug: return "DEBUG"
            case .info: return "INFO"
            case .warn: return "WARN"
            case .error: return "ERROR"
            }
        }
    }

    nonisolated(unsafe) public static var minimumLevel: Level = .info
    nonisolated(unsafe) public static var jsonMode: Bool = false
    nonisolated(unsafe) private static var sink: FileHandle = .standardError
    private static let lock = NSLock()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func redirect(to handle: FileHandle) {
        lock.lock(); defer { lock.unlock() }
        sink = handle
    }

    public static func debug(_ msg: @autoclosure () -> String, _ fields: [String: String] = [:]) {
        emit(.debug, msg(), fields)
    }

    public static func info(_ msg: @autoclosure () -> String, _ fields: [String: String] = [:]) {
        emit(.info, msg(), fields)
    }

    public static func warn(_ msg: @autoclosure () -> String, _ fields: [String: String] = [:]) {
        emit(.warn, msg(), fields)
    }

    public static func error(_ msg: @autoclosure () -> String, _ fields: [String: String] = [:]) {
        emit(.error, msg(), fields)
    }

    private static func emit(_ level: Level, _ msg: String, _ fields: [String: String]) {
        guard level >= minimumLevel else { return }
        let line: String
        if jsonMode {
            var payload: [String: String] = [
                "ts": ISO8601DateFormatter().string(from: Date()),
                "level": level.label.lowercased(),
                "msg": msg
            ]
            fields.forEach { payload[$0.key] = $0.value }
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
            line = String(data: data, encoding: .utf8) ?? "{}"
        } else {
            let extras = fields.isEmpty
                ? ""
                : " " + fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            line = "\(stamp.string(from: Date())) \(level.label.padding(toLength: 5, withPad: " ", startingAt: 0)) \(msg)\(extras)"
        }
        lock.lock(); defer { lock.unlock() }
        if let data = (line + "\n").data(using: .utf8) {
            sink.write(data)
        }
    }
}
