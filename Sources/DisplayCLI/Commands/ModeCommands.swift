import Foundation
import VibeDisplayCore

enum ModeCommands {
    static func run(_ args: Arguments) throws {
        let sub = args.positional(1) ?? "list"
        guard ["list", "set"].contains(sub) else { throw VibeError(.invalidArgument, "use modes list | set <mode-id>") }
        try args.validateSurface(options: ["display", "d", "selector"], flags: sub == "set" ? ["dry-run"] : [], maxPositionals: sub == "set" ? 3 : 2)
        let selector = args.string("display", "d", "selector") ?? (sub == "list" ? "all" : "")
        if sub == "list" {
            let reports: [DisplayModeReport]
            if let client = DaemonClient() {
                reports = try client.decode(ModesPayload.self, "GET", "/v1/modes?selector=\(selector.urlPathEncoded)").displays
            } else { reports = try DisplayModeService.shared.list(DisplaySelector(selector)) }
            Output.emit(ModesPayload(displays: reports)) {
                Table.render(headers: ["DISPLAY", "ID", "SIZE", "PIXELS", "HZ", "FLAGS"], rows: reports.flatMap { report in
                    report.modes.map { mode in
                        [report.slug, String(mode.id), "\(mode.width)x\(mode.height)", "\(mode.pixelWidth)x\(mode.pixelHeight)",
                         mode.refreshRate == 0 ? "unknown" : String(format: "%.2f", mode.refreshRate),
                         [mode.id == report.current.id ? "current" : "", mode.hiDPI ? "HiDPI" : "", mode.usable ? "" : "unusable"].filter { !$0.isEmpty }.joined(separator: ",")]
                    }
                })
            }
        } else {
            guard !selector.isEmpty, let raw = args.positional(2), let mode = Int32(raw), mode >= 0 else {
                throw VibeError(.invalidArgument, "modes set requires a valid mode ID and explicit --display selector")
            }
            let report: DisplayModeChange
            if let client = DaemonClient(timeout: 30) {
                report = try client.decode(DisplayModeChange.self, "POST", "/v1/modes",
                    body: ["selector": selector, "modeID": mode, "dryRun": args.has("dry-run")])
            } else { report = try DisplayModeService.shared.set(mode, selector: DisplaySelector(selector), dryRun: args.has("dry-run")) }
            Output.emit(report) { "\(report.dryRun ? "Preview" : "Verified"): \(report.displayUUID) mode \(report.previous.id) → \(report.requested.id)" }
        }
    }
}

struct ModesPayload: Codable { let displays: [DisplayModeReport] }
