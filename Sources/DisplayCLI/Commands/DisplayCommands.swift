import Foundation
import VibeDisplayCore

enum DisplayCommands {

    // MARK: displays

    static func list(_ args: Arguments) throws {
        let refresh = !args.has("cached")
        let displays: [DisplayInfo]

        if let client = DaemonClient() {
            let payload = try client.decode(DisplaysListPayload.self, "GET",
                                            "/v1/displays?refresh=\(refresh)")
            displays = payload.displays
        } else {
            displays = BrightnessService.shared.inventory(forceRefresh: refresh)
        }

        Output.emit(DisplaysListPayload(displays: displays, count: displays.count)) {
            let rows = displays.map { d -> [String] in
                let value = BrightnessService.shared.readOne(d)
                return [
                    "#\(d.index)",
                    d.slug,
                    d.name,
                    d.isBuiltin ? "builtin" : "external",
                    "\(d.width)x\(d.height)",
                    d.capability.preferred.rawValue,
                    Table.percent(value),
                    d.isMain ? "main" : ""
                ]
            }
            var text = Table.render(
                headers: ["IDX", "SLUG", "NAME", "TYPE", "RESOLUTION", "TRANSPORT", "BRIGHT", "FLAGS"],
                rows: rows)
            let notes = displays.flatMap { d in d.capability.notes.map { "  \(d.slug): \($0)" } }
            if !notes.isEmpty {
                text += "\n\nnotes:\n" + notes.joined(separator: "\n")
            }
            return text
        }
    }

    // MARK: brightness

    static func brightness(_ args: Arguments) throws {
        let sub = args.positional(1) ?? "get"
        try args.validateSurface(options: sub == "set" || sub == "apply" ? ["display", "d", "selector", "ramp"] : (sub == "restore" ? [] : ["display", "d", "selector"]), maxPositionals: sub == "restore" ? 2 : 3)
        switch sub {
        case "get", "read", "show":
            try get(args)
        case "set", "apply":
            try set(args)
        case "restore":
            try restore(args)
        default:
            throw VibeError(.invalidArgument, "unknown subcommand 'brightness \(sub)'",
                            hint: "one of: get, set, restore")
        }
    }

    private static func get(_ args: Arguments) throws {
        let selector = args.string("display", "d", "selector") ?? args.positional(2) ?? "all"
        let readings: [BrightnessReading]

        if let client = DaemonClient() {
            let encoded = selector.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? selector
            readings = try client.decode(ReadingsPayload.self, "GET",
                                         "/v1/displays/\(encoded)/brightness").readings
        } else {
            readings = try BrightnessService.shared.read(DisplaySelector(selector))
        }

        Output.emit(ReadingsPayload(readings: readings)) {
            Table.render(headers: ["SLUG", "BRIGHTNESS", "TRANSPORT"],
                         rows: readings.map { [$0.slug, Table.percent($0.value), $0.transport.rawValue] })
        }
    }

    private static func set(_ args: Arguments) throws {
        guard let raw = args.positional(2) else {
            throw VibeError(.invalidArgument, "missing brightness value",
                            hint: "display-cli brightness set 60% --display builtin")
        }
        let selector = args.string("display", "d", "selector")
            ?? AgentSessionManager.shared.currentConfig().defaultSelector
        let ramp = args.int("ramp") ?? 0
        let results = try Runtime.applyBrightness(target: raw, selector: selector, rampMs: ramp)

        Output.emit(ApplyResultsPayload(results: results)) {
            Table.render(headers: ["SLUG", "REQUESTED", "APPLIED", "TRANSPORT", "OK"],
                         rows: results.map {
                             [$0.slug, Table.percent($0.requested), Table.percent($0.applied),
                              $0.transport.rawValue, $0.ok ? "yes" : "NO — \($0.error ?? "")"]
                         })
        }
        if results.contains(where: { !$0.ok }) { exit(1) }
    }

    private static func restore(_ args: Arguments) throws {
        let results: [BrightnessApplyResult]
        if let client = DaemonClient() {
            results = try client.decode(ApplyResultsPayload.self, "POST", "/v1/brightness/restore").results
        } else {
            results = BrightnessService.shared.restoreAll()
            if results.isEmpty {
                Output.note("no snapshot to restore in this process; if a daemon set the brightness, start it or use `display-cli panic`")
            }
        }
        Output.emit(ApplyResultsPayload(results: results)) {
            results.isEmpty ? "nothing to restore"
                : Table.render(headers: ["SLUG", "RESTORED", "OK"],
                               rows: results.map { [$0.slug, Table.percent($0.applied), $0.ok ? "yes" : "no"] })
        }
    }
}

// MARK: - Shared execution path

enum Runtime {
    /// Apply brightness through the daemon when one exists, locally otherwise.
    static func applyBrightness(target: String, selector: String, rampMs: Int) throws -> [BrightnessApplyResult] {
        // Validate before dispatching so a typo fails the same way either side.
        _ = try BrightnessTarget.parse(target)

        if let client = DaemonClient() {
            return try client.decode(ApplyResultsPayload.self, "POST", "/v1/brightness",
                                     body: ["selector": selector, "target": target, "rampMs": rampMs]).results
        }

        warnIfResidencyRequired(selector: selector)
        let parsed = try BrightnessTarget.parse(target)
        return try BrightnessService.shared.apply(parsed, to: DisplaySelector(selector),
                                                  ramp: BrightnessRamp(durationMs: rampMs))
    }

    /// Gamma dimming dies with this process. Say so loudly rather than letting
    /// the user think the command silently failed.
    static func warnIfResidencyRequired(selector: String) {
        let displays = (try? DisplaySelector(selector).resolve(in: BrightnessService.shared.inventory())) ?? []
        let gammaOnly = displays.filter { $0.capability.preferred == .gamma }
        guard !gammaOnly.isEmpty else { return }
        Output.note("""
        warning: \(gammaOnly.map(\.slug).joined(separator: ", ")) can only be dimmed via gamma, \
        which is reset when this process exits.
                 start the daemon to make it stick:  display-cli serve --detach
        """)
    }
}

// MARK: - CLI payload mirrors

struct DisplaysListPayload: Codable {
    let displays: [DisplayInfo]
    let count: Int
}

struct ReadingsPayload: Codable {
    let readings: [BrightnessReading]
}

struct ApplyResultsPayload: Codable {
    let results: [BrightnessApplyResult]
}
