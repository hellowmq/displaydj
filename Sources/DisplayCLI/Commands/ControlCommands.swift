import Foundation
import VibeDisplayCore

enum ControlCommands {
    static func run(_ args: Arguments, control: MonitorControl) throws {
        let sub = args.positional(1) ?? "get"
        guard ["get", "set"].contains(sub) else { throw VibeError(.invalidArgument, "use \(control.rawValue) get | set <value>") }
        try args.validateSurface(options: ["display", "d", "selector"], flags: sub == "set" ? ["dry-run"] : [], maxPositionals: sub == "set" ? 3 : 2)
        let selector = args.string("display", "d", "selector") ?? (sub == "get" ? "external" : "")
        guard !selector.isEmpty else { throw VibeError(.invalidArgument, "set requires an explicit --display selector (use external for all external displays)") }
        let results: [MonitorControlResult]
        if sub == "get" {
            if let client = DaemonClient(timeout: 60) {
                results = try client.decode(ControlResultsPayload.self, "GET", "/v1/controls/\(control.rawValue)?selector=\(selector.urlPathEncoded)").results
            } else { results = try MonitorControlService.shared.read(control, selector: DisplaySelector(selector)) }
        } else {
            guard let target = args.positional(2) else { throw VibeError(.invalidArgument, "missing control value") }
            _ = try MonitorControlService.parseTarget(target)
            if let client = DaemonClient(timeout: 60) {
                results = try client.decode(ControlResultsPayload.self, "POST", "/v1/controls/\(control.rawValue)",
                    body: ["selector": selector, "target": target, "dryRun": args.has("dry-run")]).results
            } else {
                results = try MonitorControlService.shared.set(control, target: target, selector: DisplaySelector(selector), dryRun: args.has("dry-run"))
            }
        }
        Output.emit(ControlResultsPayload(results: results)) {
            Table.render(headers: ["DISPLAY", "CONTROL", "VALUE", "STATUS"], rows: results.map {
                [$0.slug, $0.control.rawValue, Table.percent($0.value), $0.error ?? ($0.dryRun ? "preview → \(Table.percent($0.requested))" : ($0.verified ? "verified" : "read"))]
            })
        }
        if results.contains(where: { !$0.ok }) { exit(1) }
    }
}

struct ControlResultsPayload: Codable { let results: [MonitorControlResult] }

extension String {
    var urlPathEncoded: String { addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self }
}
