import Foundation

/// Single source of truth for where display-cli keeps things.
///
/// Everything lives under one root so an agent can be told "look in
/// `~/.displaydj`" and find config, state, the daemon descriptor and the
/// auth token without extra discovery logic. `DISPLAYDJ_HOME` relocates the
/// whole tree, which is what the harness uses to get a hermetic sandbox.
public enum Paths {
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["DISPLAYDJ_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".displaydj", isDirectory: true)
    }

    public static var configFile: URL {
        if let override = ProcessInfo.processInfo.environment["DISPLAYDJ_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent("config.json")
    }

    /// Persisted agent sessions + brightness snapshots. Survives daemon restarts
    /// so a crash cannot strand the user's brightness.
    public static var stateFile: URL { home.appendingPathComponent("state.json") }

    /// Written by `serve`, read by every CLI invocation to find the daemon.
    public static var daemonFile: URL { home.appendingPathComponent("daemon.json") }

    public static var tokenFile: URL { home.appendingPathComponent("token") }

    public static var logDirectory: URL { home.appendingPathComponent("logs", isDirectory: true) }

    @discardableResult
    public static func ensureHome() throws -> URL {
        let fm = FileManager.default
        let root = home
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        let logs = logDirectory
        if !fm.fileExists(atPath: logs.path) {
            try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        }
        return root
    }

    /// Write with 0600 and an atomic replace, so a half-written state file can
    /// never be observed by a concurrent CLI call.
    public static func writeSecure(_ data: Data, to url: URL) throws {
        try ensureHome()
        let tmp = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        guard rename(tmp.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
