import Foundation
import Security

/// Written by `display-cli serve`, read by every other invocation.
///
/// This is the whole service-discovery mechanism: no mDNS, no port scanning.
/// An agent that wants to talk HTTP reads `~/.displaydj/daemon.json`, or
/// simply shells out to the CLI and lets it do the same.
public struct DaemonDescriptor: Codable, Equatable, Sendable {
    public let pid: Int32
    public let host: String
    public let port: Int
    public let version: String
    public let startedAt: Date
    public let requiresToken: Bool

    public var baseURL: String { "http://\(host):\(port)" }

    public init(pid: Int32, host: String, port: Int, version: String,
                startedAt: Date = Date(), requiresToken: Bool) {
        self.pid = pid
        self.host = host
        self.port = port
        self.version = version
        self.startedAt = startedAt
        self.requiresToken = requiresToken
    }

    public func write() throws {
        let data = try JSONCoding.encoder.encode(self)
        try Paths.writeSecure(data, to: Paths.daemonFile)
    }

    public static func remove() {
        try? FileManager.default.removeItem(at: Paths.daemonFile)
    }

    /// Load the descriptor **only if** the process it describes is still alive.
    /// A stale file from a crashed daemon is deleted rather than returned.
    public static func loadIfAlive() -> DaemonDescriptor? {
        guard let data = try? Data(contentsOf: Paths.daemonFile),
              let descriptor = try? JSONCoding.decoder.decode(DaemonDescriptor.self, from: data) else {
            return nil
        }
        // Signal 0 probes existence without delivering anything.
        if kill(descriptor.pid, 0) != 0, errno == ESRCH {
            Log.debug("removing stale daemon descriptor", ["pid": "\(descriptor.pid)"])
            remove()
            return nil
        }
        return descriptor
    }
}

/// Bearer token for the loopback HTTP API.
///
/// The daemon only binds 127.0.0.1, but loopback is still shared with every
/// process on the machine, so a token keeps a random browser tab or npm
/// postinstall script from dimming the user's screen.
public enum TokenStore {
    public static func loadOrCreate() throws -> String {
        if let existing = load() { return existing }
        let token = generate()
        try Paths.writeSecure(Data(token.utf8), to: Paths.tokenFile)
        return token
    }

    public static func load() -> String? {
        if let env = ProcessInfo.processInfo.environment["DISPLAYDJ_TOKEN"], !env.isEmpty {
            return env
        }
        guard let data = try? Data(contentsOf: Paths.tokenFile),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func rotate() throws -> String {
        let token = generate()
        try Paths.writeSecure(Data(token.utf8), to: Paths.tokenFile)
        return token
    }

    private static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
