import Foundation
import VibeDisplayCore

enum PowerCommands {

    static func keepAwake(_ args: Arguments) throws {
        let sub = args.positional(1) ?? "list"
        switch sub {
        case "start", "acquire", "on":
            try start(args)
        case "list", "ls", "status":
            try list(args)
        case "stop", "release", "off":
            try stop(args)
        case "run", "while":
            try runWhileAwake(args)
        default:
            throw VibeError(.invalidArgument, "unknown subcommand 'keepawake \(sub)'",
                            hint: "one of: start, list, stop, run")
        }
    }

    private static func policy(from args: Arguments) -> KeepAwakePolicy {
        KeepAwakePolicy(
            ttlSeconds: args.int("ttl") ?? 300,
            maxDurationSeconds: args.int("max-duration"),
            requireACPower: args.has("require-ac", "ac-only"),
            activeWindow: args.string("window")
        )
    }

    private static func scope(from args: Arguments) throws -> KeepAwakeScope {
        let raw = args.string("scope") ?? args.positional(2) ?? "display"
        guard let scope = KeepAwakeScope(rawValue: raw) else {
            throw VibeError(.invalidArgument, "unknown scope '\(raw)'",
                            hint: "one of: \(KeepAwakeScope.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return scope
    }

    private static func start(_ args: Arguments) throws {
        let scope = try scope(from: args)
        let reason = args.string("reason") ?? "manual"
        let owner = args.string("owner") ?? "cli"
        let p = policy(from: args)

        guard let client = DaemonClient() else {
            throw VibeError(.daemonUnavailable,
                            "a standalone lease needs the resident daemon (assertions die with the process)",
                            hint: "run `display-cli serve --detach` first, or use `display-cli keepawake run -- <command>`")
        }
        var body: [String: Any] = [
            "scope": scope.rawValue,
            "reason": reason,
            "owner": owner,
            "ttlSeconds": p.ttlSeconds,
            "requireACPower": p.requireACPower
        ]
        if let window = p.activeWindow { body["activeWindow"] = window }
        if let cap = p.maxDurationSeconds { body["maxDurationSeconds"] = cap }

        let payload = try client.decode(LeaseListPayload.self, "POST", "/v1/keepawake", body: body)
        Output.emit(payload) {
            guard let lease = payload.leases.first else { return "no lease created" }
            return "lease \(lease.id) — scope=\(lease.scope.rawValue) ttl=\(lease.policy.ttlSeconds)s\n" +
                   "renew with: display-cli keepawake start --ttl \(lease.policy.ttlSeconds)  (or POST /v1/keepawake/\(lease.id)/renew)"
        }
    }

    private static func list(_ args: Arguments) throws {
        let payload: LeaseListPayload
        if let client = DaemonClient() {
            payload = try client.decode(LeaseListPayload.self, "GET", "/v1/keepawake")
        } else {
            let registry = KeepAwakeRegistry.shared
            payload = LeaseListPayload(leases: registry.allLeases(), activeScopes: registry.activeScopes())
            if payload.leases.isEmpty {
                Output.note("no daemon running — only leases held by this process would be listed")
            }
        }
        Output.emit(payload) {
            Table.render(headers: ["ID", "SCOPE", "OWNER", "TTL", "REMAINING", "RENEWS", "STATE"],
                         rows: payload.leases.map {
                             [$0.id, $0.scope.rawValue, $0.owner, "\($0.policy.ttlSeconds)s",
                              "\($0.remainingSeconds)s", "\($0.renewCount)",
                              $0.suspended ? "suspended (\($0.suspendedReason ?? ""))" : "active"]
                         })
        }
    }

    private static func stop(_ args: Arguments) throws {
        guard let client = DaemonClient() else {
            throw VibeError(.daemonUnavailable, "no daemon running; nothing to release")
        }
        if args.has("all") {
            let current = try client.decode(LeaseListPayload.self, "GET", "/v1/keepawake")
            for lease in current.leases {
                _ = try? client.call("DELETE", "/v1/keepawake/\(lease.id)")
            }
            Output.emit(LeaseListPayload(leases: [], activeScopes: [])) {
                "released \(current.leases.count) lease(s)"
            }
            return
        }
        guard let id = args.string("id") ?? args.positional(2) else {
            throw VibeError(.invalidArgument, "missing lease id", hint: "display-cli keepawake stop <id> | --all")
        }
        let payload = try client.decode(LeaseListPayload.self, "DELETE", "/v1/keepawake/\(id)")
        Output.emit(payload) { "released \(id); \(payload.leases.count) lease(s) remain" }
    }

    /// `display-cli keepawake run -- make build`
    ///
    /// The dependency-free path: this process holds the assertion for exactly
    /// as long as the child runs, so no daemon is required and nothing can leak
    /// — when the child exits, so does the assertion.
    private static func runWhileAwake(_ args: Arguments) throws {
        guard !args.passthrough.isEmpty else {
            throw VibeError(.invalidArgument, "nothing to run",
                            hint: "display-cli keepawake run -- <command> [args...]")
        }
        let scope = try scope(from: args)
        let registry = KeepAwakeRegistry.shared
        let lease = registry.acquire(scope: scope,
                                     reason: "wrapping: \(args.passthrough.joined(separator: " "))",
                                     owner: "cli-run",
                                     policy: KeepAwakePolicy(ttlSeconds: args.int("ttl") ?? 3600,
                                                             maxDurationSeconds: nil,
                                                             requireACPower: args.has("require-ac"),
                                                             activeWindow: args.string("window")))
        defer {
            try? registry.release(lease.id)
            registry.releaseEverything()
        }

        Output.note("keeping \(scope.rawValue) awake while: \(args.passthrough.joined(separator: " "))")
        let status = try ProcessRunner.run(args.passthrough)
        exit(status)
    }
}

struct LeaseListPayload: Codable {
    let leases: [KeepAwakeLease]
    let activeScopes: [KeepAwakeScope]
}

/// Runs a child process, forwarding stdio and signals, and returns its exit
/// status. Used by `keepawake run` and `agent run`.
enum ProcessRunner {
    static func run(_ argv: [String]) throws -> Int32 {
        guard let executable = argv.first else {
            throw VibeError(.invalidArgument, "empty command")
        }
        let process = Process()
        // Resolve through the login shell's PATH so `agent run -- npm test`
        // behaves the same as typing it.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            throw VibeError(.ioFailure, "cannot execute '\(executable)': \(error.localizedDescription)")
        }

        // Forward Ctrl-C to the child; our own cleanup runs via `defer`.
        let forwarded: [Int32] = [SIGINT, SIGTERM]
        var sources: [DispatchSourceSignal] = []
        for sig in forwarded {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { kill(process.processIdentifier, sig) }
            source.resume()
            sources.append(source)
        }
        defer { sources.forEach { $0.cancel() } }

        process.waitUntilExit()
        if process.terminationReason == .uncaughtSignal {
            return 128 + process.terminationStatus
        }
        return process.terminationStatus
    }
}
