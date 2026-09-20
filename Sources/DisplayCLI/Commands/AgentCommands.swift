import Foundation
import VibeDisplayCore

/// Abstracts "do I own the session locally, or does the daemon?" so every
/// agent verb has exactly one implementation.
protocol SessionDriver {
    func begin(label: String, client: String, selector: String?, ttl: Int?, metadata: [String: String], phase: AgentPhase) throws -> AgentSession
    func phase(_ id: String, _ phase: AgentPhase, note: String?) throws -> AgentSession
    func beat(_ id: String) throws -> AgentSession
    func end(_ id: String, outcome: AgentPhase, note: String?) throws -> AgentSession
    func list(all: Bool) throws -> [AgentSession]
}

struct LocalSessionDriver: SessionDriver {
    let manager = AgentSessionManager.shared

    func begin(label: String, client: String, selector: String?, ttl: Int?, metadata: [String: String], phase: AgentPhase) throws -> AgentSession {
        try manager.begin(label: label, client: client, selector: selector,
                          ttlSeconds: ttl, metadata: metadata, initialPhase: phase).session
    }
    func phase(_ id: String, _ phase: AgentPhase, note: String?) throws -> AgentSession {
        try manager.transition(id, to: phase, note: note).session
    }
    func beat(_ id: String) throws -> AgentSession { try manager.heartbeat(id) }
    func end(_ id: String, outcome: AgentPhase, note: String?) throws -> AgentSession {
        try manager.end(id, outcome: outcome, note: note).session
    }
    func list(all: Bool) throws -> [AgentSession] { manager.sessions(includeEnded: all) }
}

struct RemoteSessionDriver: SessionDriver {
    let client: DaemonClient

    private struct ReportEnvelope: Codable { let session: AgentSession }

    func begin(label: String, client clientName: String, selector: String?, ttl: Int?, metadata: [String: String], phase: AgentPhase) throws -> AgentSession {
        var body: [String: Any] = ["label": label, "client": clientName, "phase": phase.rawValue]
        if let selector { body["selector"] = selector }
        if let ttl { body["ttlSeconds"] = ttl }
        if !metadata.isEmpty { body["metadata"] = metadata }
        return try client.decode(ReportEnvelope.self, "POST", "/v1/agent/sessions", body: body).session
    }
    func phase(_ id: String, _ phase: AgentPhase, note: String?) throws -> AgentSession {
        var body: [String: Any] = ["phase": phase.rawValue]
        if let note { body["note"] = note }
        return try client.decode(ReportEnvelope.self, "POST", "/v1/agent/sessions/\(id)/phase", body: body).session
    }
    func beat(_ id: String) throws -> AgentSession {
        try client.decode(ReportEnvelope.self, "POST", "/v1/agent/sessions/\(id)/heartbeat").session
    }
    func end(_ id: String, outcome: AgentPhase, note: String?) throws -> AgentSession {
        var path = "/v1/agent/sessions/\(id)?outcome=\(outcome.rawValue)"
        if let note, let encoded = note.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            path += "&note=\(encoded)"
        }
        return try client.decode(ReportEnvelope.self, "DELETE", path).session
    }
    func list(all: Bool) throws -> [AgentSession] {
        struct P: Codable { let sessions: [AgentSession] }
        return try client.decode(P.self, "GET", "/v1/agent/sessions?all=\(all)").sessions
    }
}

enum AgentCommands {

    static func driver() -> SessionDriver {
        if let client = DaemonClient() { return RemoteSessionDriver(client: client) }
        return LocalSessionDriver()
    }

    /// Best-effort identification of the calling tool, so `agent list` is
    /// readable when several tools share the machine.
    static func detectClient(_ args: Arguments) -> String {
        if let explicit = args.string("client") { return explicit }
        let env = ProcessInfo.processInfo.environment
        if let override = env["DISPLAYDJ_CLIENT"], !override.isEmpty { return override }
        if env["CLAUDECODE"] != nil || env["CLAUDE_CODE"] != nil { return "claude-code" }
        if env["CURSOR_TRACE_ID"] != nil || env["CURSOR_SESSION_ID"] != nil { return "cursor" }
        if env["CODEX_SANDBOX"] != nil { return "codex" }
        if env["GITHUB_ACTIONS"] != nil { return "github-actions" }
        if let term = env["TERM_PROGRAM"], !term.isEmpty { return term.lowercased() }
        return "cli"
    }

    static func dispatch(_ args: Arguments) throws {
        let sub = args.positional(1) ?? "list"
        switch sub {
        case "begin", "start":     try begin(args)
        case "phase", "set":       try phase(args)
        case "beat", "heartbeat":  try beat(args)
        case "end", "stop", "finish": try end(args)
        case "list", "ls", "status":  try list(args)
        case "run", "wrap":        try run(args)
        default:
            throw VibeError(.invalidArgument, "unknown subcommand 'agent \(sub)'",
                            hint: "one of: begin, phase, beat, end, list, run")
        }
    }

    // MARK: begin

    private static func begin(_ args: Arguments) throws {
        let label = args.string("label") ?? args.positional(2) ?? "agent task"
        let phase = try AgentPhase.parse(args.string("phase") ?? "starting")

        if DaemonClient() == nil {
            Runtime.warnIfResidencyRequired(selector: args.string("selector", "display", "d")
                                            ?? AgentSessionManager.shared.currentConfig().defaultSelector)
            Output.note("warning: no daemon running — keep-awake will be released the moment this command exits.\n" +
                        "         start one with `display-cli serve --detach`, or use `display-cli agent run -- <command>`")
        }

        let session = try driver().begin(label: label,
                                         client: detectClient(args),
                                         selector: args.string("selector", "display", "d"),
                                         ttl: args.int("ttl"),
                                         metadata: args.metadata(),
                                         phase: phase)
        Output.emit(SessionEnvelope(session: session)) {
            // Printed bare so shells can do: SID=$(display-cli agent begin ...)
            session.id
        }
    }

    // MARK: phase / beat / end

    private static func phase(_ args: Arguments) throws {
        guard let id = sessionID(args, positional: 2) else {
            throw VibeError(.invalidArgument, "missing session id",
                            hint: "display-cli agent phase <id> running")
        }
        let rawPhase = args.string("phase") ?? args.positional(3) ?? "running"
        let session = try driver().phase(id, try AgentPhase.parse(rawPhase), note: args.string("note"))
        Output.emit(SessionEnvelope(session: session)) { "\(session.id) -> \(session.phase.rawValue)" }
    }

    private static func beat(_ args: Arguments) throws {
        guard let id = sessionID(args, positional: 2) else {
            throw VibeError(.invalidArgument, "missing session id")
        }
        let session = try driver().beat(id)
        Output.emit(SessionEnvelope(session: session)) {
            "\(session.id) heartbeat #\(session.heartbeatCount), expires in \(max(0, Int(session.expiresAt.timeIntervalSinceNow)))s"
        }
    }

    private static func end(_ args: Arguments) throws {
        let d = driver()
        if args.has("all") {
            let active = try d.list(all: false)
            for session in active {
                _ = try? d.end(session.id, outcome: .idle, note: "end --all")
            }
            Output.emit(SessionsEnvelope(sessions: [])) { "ended \(active.count) session(s)" }
            return
        }
        guard let id = sessionID(args, positional: 2) else {
            throw VibeError(.invalidArgument, "missing session id", hint: "display-cli agent end <id> | --all")
        }
        let outcome = try AgentPhase.parse(args.string("outcome") ?? "succeeded")
        let session = try d.end(id, outcome: outcome, note: args.string("note"))
        Output.emit(SessionEnvelope(session: session)) { "\(session.id) ended (\(session.phase.rawValue))" }
    }

    private static func list(_ args: Arguments) throws {
        let sessions = try driver().list(all: args.has("all"))
        Output.emit(SessionsEnvelope(sessions: sessions)) {
            Table.render(headers: ["ID", "CLIENT", "PHASE", "LABEL", "AGE", "STALE", "BEATS"],
                         rows: sessions.map {
                             [$0.id, $0.client, $0.phase.rawValue, $0.label,
                              "\($0.ageSeconds)s", "\($0.staleSeconds)s", "\($0.heartbeatCount)"]
                         })
        }
    }

    // MARK: run — the wrapper that most integrations should use

    /// `display-cli agent run --label "build" -- npm test`
    ///
    /// One command gets the entire lifecycle right: snapshot, phase changes,
    /// heartbeats on a timer, correct terminal phase from the child's exit
    /// code, and restore on every exit path including Ctrl-C. If an integration
    /// can shell out, this is the only entry point it needs.
    private static func run(_ args: Arguments) throws {
        guard !args.passthrough.isEmpty else {
            throw VibeError(.invalidArgument, "nothing to run",
                            hint: "display-cli agent run --label build -- npm test")
        }
        let command = args.passthrough.joined(separator: " ")
        let label = args.string("label") ?? command
        let beatInterval = max(5, args.int("beat") ?? 30)
        let d = driver()

        let session = try d.begin(label: label,
                                  client: detectClient(args),
                                  selector: args.string("selector", "display", "d"),
                                  ttl: args.int("ttl") ?? (beatInterval * 4),
                                  metadata: args.metadata(),
                                  phase: .starting)
        Output.note("display-cli session \(session.id) — \(label)")

        var finished = false
        let finishLock = NSLock()
        func finish(_ outcome: AgentPhase, note: String?) {
            finishLock.lock()
            if finished { finishLock.unlock(); return }
            finished = true
            finishLock.unlock()
            _ = try? d.end(session.id, outcome: outcome, note: note)
        }

        // Heartbeat timer: keeps both the session and its leases alive while
        // the child runs, and stops the reaper from cutting us off.
        let heartbeat = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.displaydj.beat"))
        heartbeat.schedule(deadline: .now() + Double(beatInterval), repeating: Double(beatInterval))
        heartbeat.setEventHandler { _ = try? d.beat(session.id) }
        heartbeat.resume()
        defer { heartbeat.cancel() }

        // Restore on abnormal termination too.
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { finish(.failed, note: "interrupted by signal \(sig)") }
            source.resume()
            sources.append(source)
        }
        defer { sources.forEach { $0.cancel() } }

        _ = try? d.phase(session.id, .running, note: "child started")

        let status: Int32
        do {
            status = try ProcessRunner.run(args.passthrough)
        } catch {
            finish(.failed, note: "failed to launch child")
            throw error
        }

        finish(status == 0 ? .succeeded : .failed, note: "exit \(status)")
        Output.note("display-cli session \(session.id) ended (exit \(status))")
        exit(status)
    }

    private static func sessionID(_ args: Arguments, positional index: Int) -> String? {
        if let explicit = args.string("id") { return explicit }
        if let value = args.positional(index) { return value }
        if let env = ProcessInfo.processInfo.environment["DISPLAYDJ_SESSION"], !env.isEmpty { return env }
        // Convenience: a single active session needs no id.
        if let only = try? driver().list(all: false), only.count == 1 { return only[0].id }
        return nil
    }
}

struct SessionEnvelope: Codable {
    let session: AgentSession
}

struct SessionsEnvelope: Codable {
    let sessions: [AgentSession]
}
