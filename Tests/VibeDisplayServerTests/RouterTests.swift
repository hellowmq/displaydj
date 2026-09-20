import XCTest
@testable import VibeDisplayServer
import VibeDisplayCore

/// Pure-logic tests for the path router: pattern matching, `:param` extraction,
/// method routing, error mapping and registration-order semantics.
/// Deliberately hardware-free — none of these touch CGDisplay/IOAVService, so
/// the "unit tests do not touch hardware" CI gate stays green.
final class RouterTests: XCTestCase {

    private func router() -> Router { Router() }

    private func request(_ method: String, _ path: String) -> HTTPRequest {
        HTTPRequest(method: method, path: path, query: [:], headers: [:], body: Data())
    }

    private func ok(_ body: String = "ok") -> Router.Handler {
        { _, _ in HTTPResponse(status: 200, body: Data(body.utf8)) }
    }

    private func errorCode(of response: HTTPResponse) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let error = obj["error"] as? [String: Any] else { return nil }
        return error["code"] as? String
    }

    private func bodyString(_ response: HTTPResponse) -> String {
        String(data: response.body, encoding: .utf8) ?? ""
    }

    // MARK: - route-not-found

    func testEmptyRouterReturnsRouteNotFound() {
        let resp = router().handle(request("GET", "/v1/health"))
        XCTAssertEqual(resp.status, 404)
        XCTAssertEqual(errorCode(of: resp), "route_not_found")
    }

    func testUnknownRouteIs404() {
        let r = router()
        r.get("/v1/health", ok())
        let resp = r.handle(request("GET", "/v1/no-such-route"))
        XCTAssertEqual(resp.status, 404)
        XCTAssertEqual(errorCode(of: resp), "route_not_found")
    }

    // MARK: - static matching

    func testStaticPathMatches() {
        let r = router()
        r.get("/v1/health", ok("healthy"))
        let resp = r.handle(request("GET", "/v1/health"))
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(bodyString(resp), "healthy")
    }

    func testSegmentCountMismatchIs404() {
        let r = router()
        r.get("/v1/keepawake", ok())
        // Extra segment and missing segment both fail to match.
        XCTAssertEqual(r.handle(request("GET", "/v1/keepawake/extra")).status, 404)
        XCTAssertEqual(r.handle(request("GET", "/v1")).status, 404)
    }

    func testTrailingSlashIsIgnored() {
        let r = router()
        r.get("/v1/health", ok())
        XCTAssertEqual(r.handle(request("GET", "/v1/health/")).status, 200)
    }

    // MARK: - :param extraction

    func testParamExtraction() {
        let r = router()
        r.get("/v1/keepawake/:id") { _, params in
            HTTPResponse(status: 200, body: Data((params["id"] ?? "").utf8))
        }
        let resp = r.handle(request("GET", "/v1/keepawake/abc-123"))
        XCTAssertEqual(resp.status, 200)
        XCTAssertEqual(bodyString(resp), "abc-123")
    }

    func testParamIsPercentDecoded() {
        let r = router()
        r.get("/v1/agent/sessions/:id") { _, params in
            HTTPResponse(status: 200, body: Data((params["id"] ?? "").utf8))
        }
        let resp = r.handle(request("GET", "/v1/agent/sessions/hello%20world"))
        XCTAssertEqual(bodyString(resp), "hello world")
    }

    func testParamCountMismatchIs404() {
        let r = router()
        r.get("/v1/keepawake/:id", ok())
        XCTAssertEqual(r.handle(request("GET", "/v1/keepawake")).status, 404)
        XCTAssertEqual(r.handle(request("GET", "/v1/keepawake/a/b")).status, 404)
    }

    // MARK: - method routing

    func testPathMatchedButWrongMethodIs400() {
        let r = router()
        r.get("/v1/keepawake", ok())
        let resp = r.handle(request("POST", "/v1/keepawake"))
        XCTAssertEqual(resp.status, 400)
        XCTAssertEqual(errorCode(of: resp), "invalid_argument")
        XCTAssertTrue(bodyString(resp).contains("not allowed"))
    }

    func testDifferentMethodsShareAPath() {
        let r = router()
        r.get("/v1/keepawake", ok("got"))
        r.post("/v1/keepawake", ok("posted"))
        XCTAssertEqual(bodyString(r.handle(request("GET", "/v1/keepawake"))), "got")
        XCTAssertEqual(bodyString(r.handle(request("POST", "/v1/keepawake"))), "posted")
    }

    func testMethodIsNormalizedToUppercase() {
        let r = router()
        r.add("get", "/v1/health", ok())
        XCTAssertEqual(r.handle(request("GET", "/v1/health")).status, 200)
    }

    // MARK: - handler error mapping

    func testHandlerThrowingVibeErrorKeepsItsCode() {
        let r = router()
        r.get("/v1/x") { _, _ in throw VibeError(.sessionNotFound, "gone") }
        let resp = r.handle(request("GET", "/v1/x"))
        XCTAssertEqual(resp.status, 404)
        XCTAssertEqual(errorCode(of: resp), "session_not_found")
    }

    func testHandlerThrowingPlainErrorBecomesBackendFailure() {
        let r = router()
        r.get("/v1/x") { _, _ in throw NSError(domain: "test", code: 42) }
        let resp = r.handle(request("GET", "/v1/x"))
        XCTAssertEqual(resp.status, 500)
        XCTAssertEqual(errorCode(of: resp), "backend_failure")
    }

    // MARK: - registration order & route table

    func testFirstRegisteredMatchWins() {
        let r = router()
        r.get("/v1/:resource", ok("generic"))
        r.get("/v1/keepawake", ok("specific"))
        // The :param route is registered first, so it wins even though the
        // static route is a more specific pattern.
        XCTAssertEqual(bodyString(r.handle(request("GET", "/v1/keepawake"))), "generic")
    }

    func testRouteTableIsSortedAndNormalized() {
        let r = router()
        r.get("/b", ok())
        r.post("/a", ok())
        r.delete("/c", ok())
        r.add("get", "/a", ok())
        // Lowercase "get" is normalized to "GET"; entries are lexically sorted.
        XCTAssertEqual(r.routeTable, ["DELETE /c", "GET /a", "GET /b", "POST /a"])
    }
}
