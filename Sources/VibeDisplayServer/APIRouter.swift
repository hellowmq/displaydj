import Foundation
import VibeDisplayCore

/// Wires the HTTP surface onto `VibeDisplayCore`.
///
/// Every endpoint returns the same `{ ok, data, error }` envelope so an agent
/// only has to write one response handler. Endpoint semantics mirror the CLI
/// exactly — `docs/API.md` documents the pairs side by side, and
/// `harness/checks/30-cli-contract.sh` asserts they stay in sync.
public enum APIRouter {
    public static func make(brightness: BrightnessService = .shared,
                            keepAwake: KeepAwakeRegistry = .shared,
                            sessions: AgentSessionManager = .shared,
                            startedAt: Date,
                            controls: MonitorControlService = .shared, modes: DisplayModeService = .shared,
                            profileStore: DisplayProfileStore = .shared, profileService: DisplayProfileService? = nil) -> Router {
        let router = Router()

        // MARK: service

        router.get("/v1/health") { _, _ in
            .ok(HealthPayload(
                status: "ok",
                version: VibeVersion.current,
                apiVersion: VibeVersion.apiVersion,
                pid: ProcessInfo.processInfo.processIdentifier,
                uptimeSeconds: Int(Date().timeIntervalSince(startedAt)),
                activeSessions: sessions.sessions().count,
                activeLeases: keepAwake.allLeases().count
            ))
        }

        router.get("/v1") { _, _ in
            .ok(RoutesPayload(service: "display-cli",
                              version: VibeVersion.current,
                              routes: router.routeTable))
        }

        router.get("/v1/capabilities") { _, _ in
            .ok(Diagnostics.capabilities(brightness: brightness))
        }

        // MARK: displays

        router.get("/v1/displays") { request, _ in
            let refresh = request.query["refresh"] == "true"
            let list = brightness.inventory(forceRefresh: refresh)
            return .ok(DisplaysPayload(displays: list, count: list.count))
        }

        router.get("/v1/displays/:selector/brightness") { _, params in
            let selector = DisplaySelector(params["selector"] ?? "all")
            return .ok(BrightnessPayload(readings: try brightness.read(selector)))
        }

        router.put("/v1/displays/:selector/brightness") { request, params in
            let selector = DisplaySelector(params["selector"] ?? "all")
            let payload = try request.json(SetBrightnessRequest.self)
            let ramp = BrightnessRamp(durationMs: payload.rampMs ?? 0)
            let results = try brightness.apply(.absolute(payload.value), to: selector, ramp: ramp)
            return .ok(ApplyPayload(results: results))
        }

        router.post("/v1/brightness") { request, _ in
            let payload: ApplyBrightnessRequest
            if request.body.isEmpty, let target = request.value("target") {
                payload = ApplyBrightnessRequest(selector: request.value("selector"),
                                                 target: target,
                                                 rampMs: request.value("rampMs").flatMap(Int.init))
            } else {
                payload = try request.json(ApplyBrightnessRequest.self)
            }
            let selector = DisplaySelector(payload.selector ?? sessions.currentConfig().defaultSelector)
            let target = try BrightnessTarget.parse(payload.target)
            let ramp = BrightnessRamp(durationMs: payload.rampMs ?? 0)
            return .ok(ApplyPayload(results: try brightness.apply(target, to: selector, ramp: ramp)))
        }

        router.post("/v1/brightness/snapshot") { request, _ in
            let selector = DisplaySelector(request.value("selector") ?? "all")
            let taken = try brightness.snapshot(selector)
            return .ok(SnapshotPayload(snapshot: taken))
        }

        router.post("/v1/brightness/restore") { _, _ in
            .ok(ApplyPayload(results: brightness.restoreAll()))
        }

        // MARK: keep-awake

        router.get("/v1/keepawake") { _, _ in
            .ok(LeasesPayload(leases: keepAwake.allLeases(), activeScopes: keepAwake.activeScopes()))
        }

        router.post("/v1/keepawake") { request, _ in
            let payload: CreateLeaseRequest = request.body.isEmpty
                ? CreateLeaseRequest(
                    scope: request.value("scope").flatMap(KeepAwakeScope.init(rawValue:)),
                    reason: request.value("reason"),
                    owner: request.value("owner"),
                    ttlSeconds: request.value("ttlSeconds").flatMap(Int.init))
                : try request.json(CreateLeaseRequest.self)

            let policy = KeepAwakePolicy(
                ttlSeconds: payload.ttlSeconds ?? 300,
                maxDurationSeconds: payload.maxDurationSeconds,
                requireACPower: payload.requireACPower ?? false,
                activeWindow: payload.activeWindow
            )
            let lease = keepAwake.acquire(scope: payload.scope ?? .display,
                                          reason: payload.reason ?? "http client",
                                          owner: payload.owner ?? "http",
                                          policy: policy)
            return .ok(LeasesPayload(leases: [lease], activeScopes: keepAwake.activeScopes()))
        }

        router.post("/v1/keepawake/:id/renew") { request, params in
            let id = params["id"] ?? ""
            let ttl = request.value("ttlSeconds").flatMap(Int.init)
            let lease = try keepAwake.renew(id, ttlSeconds: ttl)
            return .ok(LeasesPayload(leases: [lease], activeScopes: keepAwake.activeScopes()))
        }

        router.delete("/v1/keepawake/:id") { _, params in
            try keepAwake.release(params["id"] ?? "")
            return .ok(LeasesPayload(leases: keepAwake.allLeases(), activeScopes: keepAwake.activeScopes()))
        }

        // MARK: agent sessions

        router.get("/v1/agent/sessions") { request, _ in
            let all = request.query["all"] == "true"
            return .ok(SessionsPayload(sessions: sessions.sessions(includeEnded: all)))
        }

        router.post("/v1/agent/sessions") { request, _ in
            let payload: BeginSessionRequest = request.body.isEmpty
                ? BeginSessionRequest(label: request.value("label"),
                                      client: request.value("client"),
                                      selector: request.value("selector"),
                                      ttlSeconds: request.value("ttlSeconds").flatMap(Int.init),
                                      phase: request.value("phase"))
                : try request.json(BeginSessionRequest.self)

            let phase = try AgentPhase.parse(payload.phase ?? "starting")
            let report = try sessions.begin(label: payload.label ?? "agent task",
                                            client: payload.client ?? "http",
                                            selector: payload.selector,
                                            ttlSeconds: payload.ttlSeconds,
                                            metadata: payload.metadata ?? [:],
                                            initialPhase: phase)
            return .json(VibeResponse(data: report), status: 201)
        }

        router.get("/v1/agent/sessions/:id") { _, params in
            .ok(SessionPayload(session: try sessions.session(params["id"] ?? "")))
        }

        router.post("/v1/agent/sessions/:id/phase") { request, params in
            let payload: PhaseRequest = request.body.isEmpty
                ? PhaseRequest(phase: request.value("phase") ?? "running",
                               note: request.value("note"),
                               ttlSeconds: request.value("ttlSeconds").flatMap(Int.init))
                : try request.json(PhaseRequest.self)
            let phase = try AgentPhase.parse(payload.phase)
            let report = try sessions.transition(params["id"] ?? "", to: phase,
                                                 note: payload.note, ttlSeconds: payload.ttlSeconds)
            return .ok(report)
        }

        router.post("/v1/agent/sessions/:id/heartbeat") { request, params in
            let ttl = request.value("ttlSeconds").flatMap(Int.init)
            let session = try sessions.heartbeat(params["id"] ?? "", ttlSeconds: ttl)
            return .ok(SessionPayload(session: session))
        }

        router.delete("/v1/agent/sessions/:id") { request, params in
            let outcome = try AgentPhase.parse(request.query["outcome"] ?? "succeeded")
            let report = try sessions.end(params["id"] ?? "", outcome: outcome,
                                          note: request.query["note"])
            return .ok(report)
        }

        // MARK: emergency

        router.post("/v1/panic-restore") { _, _ in
            .ok(ApplyPayload(results: sessions.panicRestore()))
        }

        DisplayControlRoutes.register(on: router, brightness: brightness, controls: controls, modes: modes,
                                     profiles: profileService ?? DisplayProfileService(brightness: brightness, store: profileStore, allowsGamma: true), store: profileStore)
        return router
    }
}

public struct SnapshotPayload: Codable {
    public let snapshot: [String: Double]
}
