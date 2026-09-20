import Foundation
import VibeDisplayCore
import VibeDisplayServer

enum DaemonCommands {

    // MARK: serve

    static func serve(_ args: Arguments) throws {
        var config = try ConfigLoader.load()
        if let port = args.int("port") { config.daemon.port = port }
        if let host = args.string("host") { config.daemon.host = host }
        if args.has("no-token") { config.daemon.requireToken = false }

        if args.has("detach", "background", "bg") {
            try detach(args)
            return
        }

        let service = DaemonService(config: config)
        AgentSessionManager.shared.updateConfig(config)
        try service.run(foreground: true)
    }

    /// Re-exec ourselves in the background with stdio pointed at a log file.
    /// Deliberately not a launchd job: agents start and stop this constantly
    /// and a plist would be a worse fit than a plain detached process.
    private static func detach(_ args: Arguments) throws {
        if let existing = DaemonDescriptor.loadIfAlive() {
            throw VibeError(.daemonAlreadyRunning,
                            "daemon already running on \(existing.baseURL) (pid \(existing.pid))")
        }
        try Paths.ensureHome()
        let logURL = Paths.logDirectory.appendingPathComponent("daemon.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        handle.seekToEndOfFile()

        var childArgs = ["serve"]
        if let port = args.string("port") { childArgs += ["--port", port] }
        if let host = args.string("host") { childArgs += ["--host", host] }
        if args.has("no-token") { childArgs.append("--no-token") }
        if args.has("verbose") { childArgs.append("--verbose") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = childArgs
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Wait for the descriptor to appear so `serve --detach && curl ...`
        // works without the caller sleeping.
        var descriptor: DaemonDescriptor?
        for _ in 0..<50 {
            usleep(100_000)
            if let d = DaemonDescriptor.loadIfAlive() { descriptor = d; break }
        }
        guard let descriptor else {
            throw VibeError(.daemonUnavailable,
                            "daemon did not come up within 5s",
                            hint: "check \(logURL.path)")
        }
        Output.emit(DaemonStatusPayload(running: true, descriptor: descriptor, logPath: logURL.path)) {
            "daemon started on \(descriptor.baseURL) (pid \(descriptor.pid))\nlog: \(logURL.path)"
        }
    }

    // MARK: daemon subcommands

    static func daemon(_ args: Arguments) throws {
        switch args.positional(1) ?? "status" {
        case "status":    try status(args)
        case "stop":      try stop(args)
        case "restart":   try restart(args)
        case "log", "logs": try logs(args)
        case "install":   try install(args)
        case "uninstall", "remove": try uninstall(args)
        default:
            throw VibeError(.invalidArgument, "unknown subcommand",
                            hint: "one of: status, install, uninstall, stop, restart, logs")
        }
    }

    private static func status(_ args: Arguments) throws {
        let logPath = Paths.logDirectory.appendingPathComponent("daemon.log").path
        // Always report the LaunchAgent: "not running" with an installed plist
        // is a different problem from "not running" with nothing installed.
        let agent = LaunchAgent.status(loaded: LaunchCtl.isLoaded(LaunchAgent.label))
        guard let descriptor = DaemonDescriptor.loadIfAlive() else {
            Output.emit(DaemonStatusPayload(running: false, descriptor: nil, logPath: logPath,
                                            launchAgent: agent)) {
                var text = "daemon: not running"
                text += "\n  autostart: \(agent.installed ? "installed" : "not installed") (\(agent.plistPath))"
                if !agent.installed {
                    text += "\n  hint: `display-cli daemon install` starts it at login and restarts it on crash"
                }
                return text
            }
            exit(5)
        }
        // Prove it actually answers, not just that the pid exists.
        var health: HealthSnapshot?
        if let client = DaemonClient(timeout: 3) {
            health = try? client.decode(HealthSnapshot.self, "GET", "/v1/health")
        }
        Output.emit(DaemonStatusPayload(running: true, descriptor: descriptor,
                                        logPath: logPath, health: health,
                                        launchAgent: agent)) {
            var text = "daemon: running\n  url: \(descriptor.baseURL)\n  pid: \(descriptor.pid)\n  version: \(descriptor.version)"
            if let health {
                text += "\n  uptime: \(health.uptimeSeconds)s\n  sessions: \(health.activeSessions)\n  leases: \(health.activeLeases)"
            } else {
                text += "\n  warning: process alive but not answering /v1/health"
            }
            text += "\n  autostart: \(agent.installed ? "installed" : "not installed")"
            if agent.loaded == true {
                text += " — launchd restarts this process if it dies"
            }
            text += "\n  log: \(logPath)"
            return text
        }
    }

    private static func stop(_ args: Arguments) throws {
        guard let descriptor = DaemonDescriptor.loadIfAlive() else {
            Output.emit(DaemonStatusPayload(running: false, descriptor: nil, logPath: nil)) {
                "daemon: not running"
            }
            return
        }
        // launchd owns the job, it respawns on death — so reporting "stopped"
        // without saying so would be a lie. Surface it in the payload too;
        // JSON callers need the same warning the human gets.
        let managedByLaunchd = LaunchCtl.isLoaded(LaunchAgent.label)
        let managedNote = managedByLaunchd
            ? "launchd owns this job and will restart it immediately; `display-cli daemon uninstall` stops it for good"
            : nil
        if let managedNote { Output.note(managedNote) }

        // SIGTERM lets the daemon restore displays before exiting.
        kill(descriptor.pid, SIGTERM)
        for _ in 0..<50 {
            usleep(100_000)
            if DaemonDescriptor.loadIfAlive() == nil { break }
        }
        if DaemonDescriptor.loadIfAlive() != nil {
            Output.note("daemon did not exit within 5s; sending SIGKILL (displays may need `display-cli panic`)")
            kill(descriptor.pid, SIGKILL)
            DaemonDescriptor.remove()
        }
        Output.emit(DaemonStatusPayload(running: false, descriptor: nil, logPath: nil,
                                        launchAgent: LaunchAgent.status(loaded: managedByLaunchd),
                                        note: managedNote)) {
            "daemon stopped (pid \(descriptor.pid))"
        }
    }

    private static func restart(_ args: Arguments) throws {
        try? stop(args)
        usleep(300_000)
        try detach(args)
    }

    private static func logs(_ args: Arguments) throws {
        let logURL = Paths.logDirectory.appendingPathComponent("daemon.log")
        guard let data = try? Data(contentsOf: logURL), let text = String(data: data, encoding: .utf8) else {
            Output.note("no log at \(logURL.path)")
            return
        }
        let limit = args.int("lines") ?? 50
        let lines = text.split(separator: "\n").suffix(limit)
        print(lines.joined(separator: "\n"))
    }

    // MARK: - LaunchAgent autostart (R04)

    /// Register a LaunchAgent so the daemon starts at login and is restarted
    /// by launchd if it dies.
    ///
    /// Deliberately not the default: `serve --detach` covers the agent case,
    /// where the daemon is started on demand for one task. This is opt-in
    /// persistence for machines where gamma dimming or long-lived leases need a
    /// resident process that survives a reboot.
    private static func install(_ args: Arguments) throws {
        let fm = FileManager.default
        let plistURL = LaunchAgent.plistURL
        do {
            try fm.createDirectory(at: LaunchAgent.agentsDirectory,
                                   withIntermediateDirectories: true)
        } catch {
            throw VibeError(.ioFailure,
                            "could not create \(LaunchAgent.agentsDirectory.path)",
                            hint: "\(error)")
        }
        try Paths.ensureHome()

        let executable = LaunchAgent.resolveExecutable(CommandLine.arguments[0])
        guard fm.isExecutableFile(atPath: executable) else {
            throw VibeError(.ioFailure,
                            "refusing to register a LaunchAgent for a binary that is not executable",
                            hint: "resolved '\(CommandLine.arguments[0])' to '\(executable)'")
        }

        let logFile = Paths.logDirectory.appendingPathComponent("daemon.log").path
        let data = try LaunchAgent.plistData(executable: executable,
                                             logFile: logFile,
                                             environment: LaunchAgent.inheritedEnvironment())
        do {
            try data.write(to: plistURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistURL.path)
        } catch {
            throw VibeError(.ioFailure, "could not write \(plistURL.path)", hint: "\(error)")
        }

        var warnings: [String] = []
        var loaded: Bool?

        if args.has("no-load") {
            warnings.append("plist written but not registered (--no-load); it takes effect at your next login")
        } else {
            // Re-bootstrapping a job launchd already owns fails, so evict the
            // old one first. A failure here only means it was never loaded.
            if LaunchCtl.isLoaded(LaunchAgent.label) {
                _ = try? LaunchCtl.bootout(LaunchAgent.label)
            }
            do {
                try LaunchCtl.bootstrap(plistURL)
                loaded = true
            } catch let failure as LaunchCtl.Failure {
                loaded = false
                warnings.append("launchctl bootstrap failed (\(failure.status)): \(failure.output)")
                warnings.append("the plist is in place and will load at your next login")
            } catch let error as VibeError {
                loaded = false
                warnings.append(error.description)
            }
        }

        let agent = LaunchAgent.status(loaded: loaded)
        Output.emit(LaunchAgentPayload(action: "install", agent: agent,
                                       executable: executable,
                                       warnings: warnings.isEmpty ? nil : warnings)) {
            var text = "LaunchAgent installed: \(plistURL.path)"
            text += "\n  label:    \(agent.label)"
            text += "\n  binary:   \(executable)"
            text += "\n  loaded:   \(describe(loaded))"
            text += "\n  logs:     \(logFile)"
            for warning in warnings { text += "\n  warning:  \(warning)" }
            if loaded == true {
                text += "\nlaunchd now owns the daemon: it starts at login and restarts on crash."
                text += "\nRemove it with `display-cli daemon uninstall`."
            }
            return text
        }
    }

    /// Remove the LaunchAgent and forget the job. Idempotent: uninstalling
    /// something that is not installed succeeds, because the end state is the
    /// one that was asked for.
    private static func uninstall(_ args: Arguments) throws {
        let plistURL = LaunchAgent.plistURL
        var warnings: [String] = []

        if !args.has("no-load") {
            // bootout stops the running job too, which is what someone typing
            // "uninstall" means. Failure usually just means it was not loaded.
            do {
                try LaunchCtl.bootout(LaunchAgent.label)
            } catch let failure as LaunchCtl.Failure {
                if LaunchCtl.isLoaded(LaunchAgent.label) {
                    warnings.append("launchctl bootout failed (\(failure.status)): \(failure.output)")
                }
            } catch let error as VibeError {
                warnings.append(error.description)
            }
        }

        var removed = false
        if LaunchAgent.isInstalled() {
            do {
                try FileManager.default.removeItem(at: plistURL)
                removed = true
            } catch {
                throw VibeError(.ioFailure, "could not remove \(plistURL.path)", hint: "\(error)")
            }
        }

        let agent = LaunchAgent.status(loaded: args.has("no-load") ? nil : LaunchCtl.isLoaded(LaunchAgent.label))
        Output.emit(LaunchAgentPayload(action: "uninstall", agent: agent,
                                       executable: nil,
                                       warnings: warnings.isEmpty ? nil : warnings)) {
            var text = removed
                ? "LaunchAgent removed: \(plistURL.path)"
                : "LaunchAgent was not installed; nothing to remove"
            if !args.has("no-load") {
                text += "\n  loaded:   \(describe(agent.loaded))"
            }
            for warning in warnings { text += "\n  warning:  \(warning)" }
            return text
        }
    }

    private static func describe(_ loaded: Bool?) -> String {
        guard let loaded else { return "not checked" }
        return loaded ? "yes" : "no"
    }
}

struct DaemonStatusPayload: Codable {
    let running: Bool
    let descriptor: DaemonDescriptor?
    let logPath: String?
    var health: HealthSnapshot? = nil
    /// Present once autostart is a thing the CLI can manage. Optional so an
    /// agent that only knows the 0.1.0 shape keeps parsing.
    var launchAgent: LaunchAgent.Status? = nil
    /// Set when the reported state is true but not the whole truth — e.g. stop
    /// succeeded yet launchd is about to restart the process.
    var note: String? = nil
}

struct LaunchAgentPayload: Codable {
    let action: String
    let agent: LaunchAgent.Status
    var executable: String? = nil
    var warnings: [String]? = nil
}

struct HealthSnapshot: Codable {
    let status: String
    let version: String
    let uptimeSeconds: Int
    let activeSessions: Int
    let activeLeases: Int
}
