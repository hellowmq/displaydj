import Foundation
import VibeDisplayCore

enum DisplayControlRoutes {
    static func register(on router: Router, brightness: BrightnessService,
                         controls: MonitorControlService, modes: DisplayModeService,
                         profiles: DisplayProfileService, store: DisplayProfileStore) {
        router.get("/v1/controls/:control") { request, params in
            .ok(ControlsPayload(results: try controls.read(parseControl(params), selector: DisplaySelector(request.query["selector"] ?? "external"))))
        }
        router.post("/v1/controls/:control") { request, params in
            let payload = try request.json(ControlRequest.self)
            try requireSelector(payload.selector)
            return .ok(ControlsPayload(results: try controls.set(parseControl(params), target: payload.target,
                selector: DisplaySelector(payload.selector), dryRun: payload.dryRun ?? false)))
        }
        router.get("/v1/modes") { request, _ in
            .ok(ModePayload(displays: try modes.list(DisplaySelector(request.query["selector"] ?? "all"))))
        }
        router.post("/v1/modes") { request, _ in
            let payload = try request.json(ModeRequest.self)
            try requireSelector(payload.selector)
            return .ok(try modes.set(payload.modeID, selector: DisplaySelector(payload.selector), dryRun: payload.dryRun ?? false))
        }
        router.get("/v1/profiles") { _, _ in .ok(ProfilesPayload(profiles: try store.list())) }
        router.get("/v1/profiles/:name") { _, params in .ok(try store.get(params["name"] ?? "")) }
        router.post("/v1/profiles/:name") { request, params in
            let payload = try request.json(SaveProfileRequest.self)
            return .ok(try profiles.save(params["name"] ?? "", selector: DisplaySelector(payload.selector ?? "all"), replace: payload.replace ?? false))
        }
        router.post("/v1/profiles/:name/apply") { request, params in
            let payload = try request.json(ApplyProfileRequest.self)
            return .ok(try profiles.apply(params["name"] ?? "", dryRun: payload.dryRun ?? false))
        }
        router.delete("/v1/profiles/:name") { _, params in
            let name = params["name"] ?? ""
            try store.delete(name)
            return .ok(["deleted": name])
        }
    }

    private static func requireSelector(_ raw: String) throws {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VibeError(.invalidArgument, "an explicit display selector is required")
        }
    }
    private static func parseControl(_ params: [String: String]) throws -> MonitorControl {
        guard let control = MonitorControl(rawValue: params["control"] ?? "") else {
            throw VibeError(.invalidArgument, "supported controls: contrast, volume")
        }
        return control
    }
}

private struct ControlRequest: Decodable { let selector: String; let target: String; let dryRun: Bool? }
private struct ModeRequest: Decodable { let selector: String; let modeID: Int32; let dryRun: Bool? }
private struct SaveProfileRequest: Decodable { let selector: String?; let replace: Bool? }
private struct ApplyProfileRequest: Decodable { let dryRun: Bool? }
private struct ControlsPayload: Encodable { let results: [MonitorControlResult] }
private struct ModePayload: Encodable { let displays: [DisplayModeReport] }
private struct ProfilesPayload: Encodable { let profiles: [DisplayProfile] }
