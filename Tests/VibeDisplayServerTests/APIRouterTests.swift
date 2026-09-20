import XCTest
@testable import VibeDisplayServer
import VibeDisplayCore

/// Wiring tests for `APIRouter.make()`: the HTTP surface must be wired onto
/// fresh, in-memory `VibeDisplayCore` instances without touching hardware or
/// the real `~/.displaydj` home.
///
/// Deliberately hardware-free: nothing here calls CGDisplay/IOAVService, and
/// every dependency is constructed with an explicit temporary store, so the
/// "unit tests do not touch hardware" CI gate stays green.
final class APIRouterTests: XCTestCase {

    /// Fresh router with no shared state: temporary state file, empty config.
    private func makeRouter() -> Router {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-apirouter-tests-\(UUID().uuidString)")
        let store = StateStore(url: tmp)
        let registry = DisplayRegistry()
        let brightness = BrightnessService(registry: registry, store: store)
        let keepAwake = KeepAwakeRegistry()
        let sessions = AgentSessionManager(brightness: brightness,
                                           keepAwake: keepAwake,
                                           store: store,
                                           config: VibeConfig())
        return APIRouter.make(brightness: brightness,
                              keepAwake: keepAwake,
                              sessions: sessions,
                              startedAt: Date())
    }

    private func request(_ method: String, _ path: String,
                         query: [String: String] = [:],
                         body: Data = Data()) -> HTTPRequest {
        HTTPRequest(method: method, path: path, query: query, headers: [:], body: body)
    }

    private func jsonRequest(_ method: String, _ path: String,
                             _ object: [String: Any]) -> HTTPRequest {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPRequest(method: method, path: path, query: [:], headers: [:], body: data)
    }

    private func envelope(_ response: HTTPResponse) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    }

    private func errorCode(of response: HTTPResponse) -> String? {
        guard let obj = envelope(response),
              let error = obj["error"] as? [String: Any] else { return nil }
        return error["code"] as? String
    }

    // MARK: - service surface

    func testHealthReturnsOk() {
        let router = makeRouter()
        let resp = router.handle(request("GET", "/v1/health"))
        XCTAssertEqual(resp.status, 200)
        guard let obj = envelope(resp), let ok = obj["ok"] as? Bool else {
            return XCTFail("health response is not a VibeResponse envelope")
        }
        XCTAssertTrue(ok)
        let data = obj["data"] as? [String: Any]
        XCTAssertEqual(data?["status"] as? String, "ok")
        XCTAssertEqual(data?["activeSessions"] as? Int, 0)
        XCTAssertEqual(data?["activeLeases"] as? Int, 0)
    }

    func testRouteTableSelfDescribesEveryEndpoint() {
        let router = makeRouter()
        let resp = router.handle(request("GET", "/v1"))
        XCTAssertEqual(resp.status, 200)
        guard let obj = envelope(resp), let data = obj["data"] as? [String: Any],
              let routes = data["routes"] as? [String] else {
            return XCTFail("GET /v1 did not return a route table")
        }
        // Every endpoint registered in APIRouter.make() must be listed.
        for expected in [
            "GET /v1/health",
            "GET /v1",
            "GET /v1/capabilities",
            "GET /v1/displays",
            "GET /v1/displays/:selector/brightness",
            "PUT /v1/displays/:selector/brightness",
            "POST /v1/brightness",
            "POST /v1/brightness/snapshot",
            "POST /v1/brightness/restore",
            "GET /v1/keepawake",
            "POST /v1/keepawake",
            "POST /v1/keepawake/:id/renew",
            "DELETE /v1/keepawake/:id",
            "GET /v1/agent/sessions",
            "POST /v1/agent/sessions",
            "GET /v1/agent/sessions/:id",
            "POST /v1/agent/sessions/:id/phase",
            "POST /v1/agent/sessions/:id/heartbeat",
            "DELETE /v1/agent/sessions/:id",
            "POST /v1/panic-restore",
        ] {
            XCTAssertTrue(routes.contains(expected), "route table missing \(expected)")
        }
        XCTAssertEqual(routes.count, 20, "route table should list exactly the 20 wired endpoints")
    }

    // MARK: - keep-awake (pure registry, no hardware)

    func testKeepAwakeListIsEmptyOnFreshRegistry() {
        let router = makeRouter()
        let resp = router.handle(request("GET", "/v1/keepawake"))
        XCTAssertEqual(resp.status, 200)
        guard let obj = envelope(resp), let data = obj["data"] as? [String: Any],
              let leases = data["leases"] as? [Any] else {
            return XCTFail("keep-awake list did not return a leases payload")
        }
        XCTAssertEqual(leases.count, 0)
    }

    // MARK: - agent sessions (fresh store, empty state)

    func testAgentSessionsListIsEmptyOnFreshStore() {
        let router = makeRouter()
        let resp = router.handle(request("GET", "/v1/agent/sessions"))
        XCTAssertEqual(resp.status, 200)
        guard let obj = envelope(resp), let data = obj["data"] as? [String: Any],
              let sessions = data["sessions"] as? [Any] else {
            return XCTFail("agent sessions list did not return a sessions payload")
        }
        XCTAssertEqual(sessions.count, 0)
    }

    // MARK: - error mapping

    func testUnknownPhaseIs400InvalidArgument() {
        let router = makeRouter()
        let resp = router.handle(jsonRequest("POST", "/v1/agent/sessions",
                                             ["phase": "definitely-not-a-phase"]))
        XCTAssertEqual(resp.status, 400)
        XCTAssertEqual(errorCode(of: resp), "invalid_argument")
    }

    func testMalformedJsonBodyIs400() {
        let router = makeRouter()
        let body = Data("{not valid json".utf8)
        let resp = router.handle(request("POST", "/v1/keepawake", body: body))
        XCTAssertEqual(resp.status, 400)
        XCTAssertEqual(errorCode(of: resp), "invalid_argument")
    }

    func testUnknownRouteIs404() {
        let router = makeRouter()
        let resp = router.handle(request("GET", "/v1/no-such-endpoint"))
        XCTAssertEqual(resp.status, 404)
        XCTAssertEqual(errorCode(of: resp), "route_not_found")
    }

    func testWrongMethodIsNotAllowed() {
        let router = makeRouter()
        // GET /v1/keepawake exists; DELETE on it matches the path but not the
        // method — Router reports that as method-not-allowed (400 invalid_argument).
        let resp = router.handle(request("DELETE", "/v1/keepawake"))
        XCTAssertEqual(resp.status, 400)
        XCTAssertEqual(errorCode(of: resp), "invalid_argument")
    }
}
