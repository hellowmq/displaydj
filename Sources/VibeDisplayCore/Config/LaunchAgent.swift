import Foundation

/// LaunchAgent plumbing behind `daemon install` / `daemon uninstall`.
///
/// Why this exists at all, given that `serve --detach` already works: a
/// detached process dies with the login session and is never restarted when it
/// crashes. Gamma-dimmed panels and long-lived keep-awake leases both need a
/// process that outlives the agent that happened to create it, so autostart has
/// to be owned by launchd.
///
/// Every filesystem path is overridable by environment variable so the harness
/// can exercise install/uninstall inside a sandbox rather than writing to the
/// user's real `~/Library/LaunchAgents`.
public enum LaunchAgent {

    public static let label = "io.github.hellowmq.displaydj.daemon"

    /// Overridden by `DISPLAYDJ_LAUNCH_AGENTS_DIR` in tests.
    public static var agentsDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["DISPLAYDJ_LAUNCH_AGENTS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    public static var plistURL: URL {
        agentsDirectory.appendingPathComponent("\(label).plist")
    }

    public static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    // MARK: - plist

    /// The job definition, serialised as XML.
    ///
    /// `RunAtLoad` starts the daemon at login; `KeepAlive` restarts it if it
    /// dies. `ThrottleInterval` matters because of the second one: without it a
    /// binary that exits instantly would be respawned in a tight loop.
    /// `ProcessType=Background` keeps launchd from treating a headless service
    /// as a regular app.
    public static func plistData(executable: String,
                                 logFile: String,
                                 environment: [String: String]) throws -> Data {
        var dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "serve"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 5,
            "ProcessType": "Background",
            "StandardOutPath": logFile,
            "StandardErrorPath": logFile
        ]
        if !environment.isEmpty { dict["EnvironmentVariables"] = environment }
        do {
            return try PropertyListSerialization.data(fromPropertyList: dict,
                                                      format: .xml,
                                                      options: 0)
        } catch {
            throw VibeError(.ioFailure, "could not serialise the LaunchAgent plist",
                            hint: "\(error)")
        }
    }

    /// Environment handed to the launchd job. Only `DISPLAYDJ_HOME` is
    /// propagated: launchd gives the job a near-empty environment, so a relocatd
    /// home would otherwise be silently ignored and the daemon would read a
    /// different config than the CLI that installed it.
    public static func inheritedEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        if let home = ProcessInfo.processInfo.environment["DISPLAYDJ_HOME"], !home.isEmpty {
            env["DISPLAYDJ_HOME"] = home
        }
        return env
    }

    // MARK: - executable resolution

    /// Absolute path to this binary, symlinks resolved.
    ///
    /// launchd will not search `PATH`, and `CommandLine.arguments[0]` is
    /// whatever the caller typed — relative paths and bare command names both
    /// have to be turned into something the job can actually exec.
    public static func resolveExecutable(_ argv0: String,
                                         searchPath: String? = ProcessInfo.processInfo.environment["PATH"],
                                         cwd: String = FileManager.default.currentDirectoryPath) -> String {
        var candidate = argv0
        if !candidate.hasPrefix("/") {
            if candidate.contains("/") {
                candidate = (cwd as NSString).appendingPathComponent(candidate)
            } else if let searchPath {
                for dir in searchPath.split(separator: ":") where !dir.isEmpty {
                    let guess = (dir as NSString).appendingPathComponent(candidate)
                    if FileManager.default.isExecutableFile(atPath: guess) {
                        candidate = guess
                        break
                    }
                }
            }
        }
        return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
    }

    // MARK: - status

    public struct Status: Codable {
        public let label: String
        public let plistPath: String
        public let installed: Bool
        /// Whether launchd currently has the job. `nil` when launchctl was not
        /// consulted (`--no-load`), which is not the same as "not loaded".
        public let loaded: Bool?

        public init(label: String, plistPath: String, installed: Bool, loaded: Bool?) {
            self.label = label
            self.plistPath = plistPath
            self.installed = installed
            self.loaded = loaded
        }
    }

    public static func status(loaded: Bool?) -> Status {
        Status(label: label, plistPath: plistURL.path, installed: isInstalled(), loaded: loaded)
    }
}

/// Thin wrapper over `launchctl`, the only part of this that touches the OS.
///
/// `bootstrap`/`bootout` are the modern (macOS 13+) domain-oriented verbs;
/// `load`/`unload` are deprecated and refuse to run against a user agent that
/// launchd already owns. Failures carry launchctl's own stderr, because
/// "not loaded" and "permission denied" need different responses from the
/// caller.
public enum LaunchCtl {

    public static var domain: String { "gui/\(getuid())" }

    public struct Failure: Error {
        public let command: [String]
        public let status: Int32
        public let output: String
    }

    /// `launchctl print` is the only reliable "is it loaded" probe: the plist
    /// being on disk says nothing about whether launchd picked it up.
    public static func isLoaded(_ label: String) -> Bool {
        run(["print", "\(domain)/\(label)"]) != nil
    }

    /// Load and start the job immediately.
    public static func bootstrap(_ plist: URL) throws {
        _ = try runOrThrow(["bootstrap", domain, plist.path])
    }

    /// Stop the job and remove it from launchd. Plist deletion is the caller's
    /// job: bootout only forgets the job, it does not delete the file.
    public static func bootout(_ label: String) throws {
        _ = try runOrThrow(["bootout", "\(domain)/\(label)"])
    }

    /// Returns nil when the command exits non-zero.
    @discardableResult
    public static func run(_ arguments: [String]) -> String? {
        try? runOrThrow(arguments)
    }

    public static func runOrThrow(_ arguments: [String]) throws -> String {
        guard let launchctl = executable() else {
            throw VibeError(.unsupportedOperation,
                            "launchctl not found at /bin/launchctl",
                            hint: "LaunchAgent install is macOS-only")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchctl)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw VibeError(.unsupportedOperation, "could not run launchctl", hint: "\(error)")
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let combined = String(data: outData + errData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw Failure(command: arguments, status: process.terminationStatus,
                          output: combined.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return combined
    }

    private static func executable() -> String? {
        let path = "/bin/launchctl"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}
