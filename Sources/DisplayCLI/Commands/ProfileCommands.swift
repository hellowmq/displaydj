import Foundation
import VibeDisplayCore

enum ProfileCommands {
    static func run(_ args: Arguments) throws {
        let sub = args.positional(1) ?? "list"
        let allowed = ["list", "show", "save", "apply", "delete"]
        guard allowed.contains(sub) else { throw VibeError(.invalidArgument, "use profile \(allowed.joined(separator: " | "))") }
        try args.validateSurface(options: sub == "save" ? ["display", "d", "selector"] : [],
                                 flags: sub == "save" ? ["replace"] : (sub == "apply" ? ["dry-run"] : []),
                                 maxPositionals: sub == "list" ? 2 : 3)
        let store = DisplayProfileStore.shared
        if sub == "list" {
            let payload: ProfilesPayload
            if let client = DaemonClient() { payload = try client.decode(ProfilesPayload.self, "GET", "/v1/profiles") }
            else { payload = ProfilesPayload(profiles: try store.list()) }
            Output.emit(payload) {
                Table.render(headers: ["NAME", "DISPLAYS", "SAVED"], rows: payload.profiles.map { [$0.name, String($0.displays.count), ISO8601DateFormatter().string(from: $0.savedAt)] })
            }
            return
        }
        guard let name = args.positional(2) else { throw VibeError(.invalidArgument, "missing profile name") }
        try DisplayProfileStore.validateName(name)
        let client = DaemonClient(timeout: 120)
        switch sub {
        case "show", "save":
            let profile: DisplayProfile
            if sub == "show" {
                profile = try client?.decode(DisplayProfile.self, "GET", "/v1/profiles/\(name)") ?? store.get(name)
            } else {
                let selector = args.string("display", "d", "selector") ?? "all"
                if let client {
                    profile = try client.decode(DisplayProfile.self, "POST", "/v1/profiles/\(name)",
                        body: ["selector": selector, "replace": args.has("replace")])
                } else { profile = try DisplayProfileService().save(name, selector: DisplaySelector(selector), replace: args.has("replace")) }
            }
            Output.emit(profile) {
                "\(profile.name)\n" + Table.render(headers: ["DISPLAY", "BRIGHTNESS", "TRANSPORT"], rows: profile.displays.map { [$0.name, Table.percent($0.brightness), $0.transport.rawValue] })
            }
        case "apply":
            let report: ProfileApplyReport
            if let client { report = try client.decode(ProfileApplyReport.self, "POST", "/v1/profiles/\(name)/apply", body: ["dryRun": args.has("dry-run")]) }
            else { report = try DisplayProfileService().apply(name, dryRun: args.has("dry-run")) }
            Output.emit(report) {
                "\(report.dryRun ? "Preview" : (report.ok ? "Applied" : "Failed; inspect rollback results")): \(name)\n" +
                Table.render(headers: ["DISPLAY", "BEFORE", "TARGET", "TRANSPORT"], rows: report.plan.map { [$0.name, Table.percent($0.previous), Table.percent($0.requested), $0.transport.rawValue] }) +
                (report.results + report.rollback).compactMap { $0.error }.map { "\nerror: \($0)" }.joined()
            }
            if !report.ok { exit(1) }
        case "delete":
            if let client { try client.call("DELETE", "/v1/profiles/\(name)") }
            else { try store.delete(name) }
            Output.emit(["deleted": name]) { "deleted profile \(name)" }
        default: break
        }
    }
}
struct ProfilesPayload: Codable { let profiles: [DisplayProfile] }
