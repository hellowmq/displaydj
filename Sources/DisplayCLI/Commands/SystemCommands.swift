import Foundation
import VibeDisplayCore

enum SystemCommands {

    // MARK: doctor

    static func doctor(_ args: Arguments) throws {
        let report = Diagnostics.capabilities()
        Output.emit(report) {
            var lines: [String] = []
            lines.append("display-cli \(report.version) — \(report.platform) \(report.architecture)")
            lines.append("  os                  \(report.osVersion)")
            lines.append("  DisplayServices     \(report.displayServicesAvailable ? "available" : "UNAVAILABLE")")
            lines.append("  DDC/CI (IOAVService) \(report.ddcAvailable ? "available" : "unavailable")")
            lines.append("  DDC engine            \(report.ddcEngine)")
            lines.append("  daemon              \(report.daemonRunning ? "running at \(report.daemonURL ?? "?")" : "not running")")
            lines.append("  config              \(report.configPath)")
            lines.append("  state               \(report.statePath)")
            lines.append("")
            lines.append(Table.render(
                headers: ["SLUG", "TYPE", "TRANSPORT", "READ", "WRITE", "FALLBACKS"],
                rows: report.displays.map {
                    [$0.slug,
                     $0.isBuiltin ? "builtin" : "external",
                     $0.capability.preferred.rawValue,
                     $0.capability.canReadBrightness ? "yes" : "no",
                     $0.capability.canWriteBrightness ? "yes" : "no",
                     $0.capability.transports.map(\.rawValue).joined(separator: ">")]
                }))
            if !report.warnings.isEmpty {
                lines.append("")
                lines.append("warnings:")
                lines.append(contentsOf: report.warnings.map { "  ! \($0)" })
            }
            lines.append("")
            lines.append(report.hasHardwareControl
                ? "verdict: hardware brightness control is available."
                : "verdict: no hardware control detected — software gamma dimming only (daemon required).")
            return lines.joined(separator: "\n")
        }
        // Exit non-zero when nothing at all works, so CI can gate on it.
        if report.displays.isEmpty { exit(1) }
    }

    // MARK: config

    static func config(_ args: Arguments) throws {
        switch args.positional(1) ?? "show" {
        case "init":
            let path = Paths.configFile
            if FileManager.default.fileExists(atPath: path.path), !args.has("force") {
                throw VibeError(.invalidArgument, "config already exists at \(path.path)",
                                hint: "pass --force to overwrite")
            }
            try ConfigLoader.save(VibeConfig())
            Output.emit(ConfigPayload(path: path.path, config: VibeConfig())) {
                "wrote default config to \(path.path)"
            }
        case "show", "dump":
            let config = try ConfigLoader.load()
            Output.emit(ConfigPayload(path: Paths.configFile.path, config: config)) {
                JSONCoding.string(config)
            }
        case "path":
            print(Paths.configFile.path)
        case "validate":
            let config = try ConfigLoader.load()
            try config.validate()
            Output.emit(ConfigPayload(path: Paths.configFile.path, config: config)) { "config is valid" }
        default:
            throw VibeError(.invalidArgument, "unknown subcommand",
                            hint: "one of: init, show, path, validate")
        }
    }

    // MARK: token

    static func token(_ args: Arguments) throws {
        switch args.positional(1) ?? "show" {
        case "show", "print":
            guard let token = TokenStore.load() else {
                throw VibeError(.unauthorized, "no token yet",
                                hint: "it is created on first `display-cli serve`")
            }
            print(token)
        case "rotate", "new":
            let token = try TokenStore.rotate()
            Output.note("token rotated — restart the daemon for it to take effect")
            print(token)
        case "path":
            print(Paths.tokenFile.path)
        default:
            throw VibeError(.invalidArgument, "unknown subcommand", hint: "one of: show, rotate, path")
        }
    }

    // MARK: panic

    /// Escape hatch. Restores every display and drops every assertion, without
    /// caring about session bookkeeping or whether a daemon is alive. This is
    /// what a user runs when an agent left the screen wrong.
    static func panic(_ args: Arguments) throws {
        var results: [BrightnessApplyResult] = []
        if let client = DaemonClient() {
            results = (try? client.decode(ApplyResultsPayload.self, "POST", "/v1/panic-restore").results) ?? []
        }
        // Always do the local pass too: it clears state.json and any gamma this
        // process could still own.
        results += AgentSessionManager.shared.panicRestore()
        StateStore.shared.reset()

        Output.emit(ApplyResultsPayload(results: results)) {
            "restored \(results.count) display state(s); all sessions and leases cleared"
        }
    }

    // MARK: version

    static func version(_ args: Arguments) {
        Output.emit(VersionPayload(version: VibeVersion.current,
                                   apiVersion: VibeVersion.apiVersion,
                                   architecture: Diagnostics.currentArchitecture)) {
            "display-cli \(VibeVersion.current) (api \(VibeVersion.apiVersion), \(Diagnostics.currentArchitecture))"
        }
    }
}

struct ConfigPayload: Codable {
    let path: String
    let config: VibeConfig
}

struct VersionPayload: Codable {
    let version: String
    let apiVersion: String
    let architecture: String
}
