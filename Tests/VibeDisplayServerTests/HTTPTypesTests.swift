import XCTest
@testable import VibeDisplayServer
import VibeDisplayCore

/// Pure-logic tests for the daemon's HTTP surface: request decoding, the
/// query-string fallback, response envelope construction and the incremental
/// HTTP/1.1 parser. Deliberately hardware-free — none of these touch
/// CGDisplay/IOAVService, so the "unit tests do not touch hardware" CI gate
/// stays green.
final class HTTPTypesTests: XCTestCase {

    // MARK: - HTTPRequest.json

    private func request(body: Data) -> HTTPRequest {
        HTTPRequest(method: "POST", path: "/phase", query: [:], headers: [:], body: body)
    }

    private struct Probe: Decodable {
        let phase: String
        let level: Double
    }

    func testJSONDecodesValidBody() throws {
        let req = request(body: Data(#"{"phase":"running","level":0.5}"#.utf8))
        let probe = try req.json(Probe.self)
        XCTAssertEqual(probe.phase, "running")
        XCTAssertEqual(probe.level, 0.5, accuracy: 0.0001)
    }

    func testJSONThrowsInvalidArgumentOnEmptyBody() {
        let req = request(body: Data())
        XCTAssertThrowsError(try req.json(Probe.self)) { error in
            let vibe = error as? VibeError
            XCTAssertEqual(vibe?.code, .invalidArgument)
        }
    }

    func testJSONThrowsInvalidArgumentOnMalformedBody() {
        let req = request(body: Data("not json".utf8))
        XCTAssertThrowsError(try req.json(Probe.self)) { error in
            let vibe = error as? VibeError
            XCTAssertEqual(vibe?.code, .invalidArgument)
        }
    }

    // MARK: - HTTPRequest.value (query fallback)

    func testValuePrefersQueryOverBody() {
        let req = HTTPRequest(method: "POST", path: "/phase",
                              query: ["phase": "running"],
                              headers: [:],
                              body: Data(#"{"phase":"waiting"}"#.utf8))
        XCTAssertEqual(req.value("phase"), "running", "query must win over body")
    }

    func testValueReadsStringFromBody() {
        let req = request(body: Data(#"{"phase":"waiting"}"#.utf8))
        XCTAssertEqual(req.value("phase"), "waiting")
    }

    func testValueCoercesNumberFromBodyToString() {
        let req = request(body: Data(#"{"brightness":0.42}"#.utf8))
        XCTAssertEqual(req.value("brightness"), "0.42", "numeric body fields must be usable from curl")
    }

    func testValueReturnsNilWhenAbsentEverywhere() {
        let req = request(body: Data(#"{"phase":"running"}"#.utf8))
        XCTAssertNil(req.value("nope"))
    }

    func testValueReturnsNilOnEmptyBodyAndNoQuery() {
        let req = request(body: Data())
        XCTAssertNil(req.value("phase"))
    }

    // MARK: - HTTPResponse.json / ok

    func testJSONResponseCarriesContentType() {
        let resp = HTTPResponse.json(["k": "v"])
        XCTAssertEqual(resp.headers["Content-Type"], "application/json; charset=utf-8")
        XCTAssertEqual(resp.status, 200)
        let object = try? JSONSerialization.jsonObject(with: resp.body) as? [String: String]
        XCTAssertEqual(object?["k"], "v")
    }

    func testOKWrapsInVibeEnvelope() throws {
        struct Payload: Encodable { let n: Int }
        let resp = HTTPResponse.ok(Payload(n: 7))
        let envelope = try JSONDecoder().decode(VibeDecodedResponse<[String: Int]>.self, from: resp.body)
        XCTAssertTrue(envelope.ok)
        XCTAssertNil(envelope.error)
    }

    // MARK: - HTTPResponse.failure status mapping

    func testFailureStatusMapping() {
        let cases: [(VibeError.Code, Int)] = [
            (.invalidArgument, 400), (.configInvalid, 400), (.ambiguousSelector, 400),
            (.unauthorized, 401),
            (.displayNotFound, 404), (.sessionNotFound, 404), (.routeNotFound, 404),
            (.sessionConflict, 409), (.daemonAlreadyRunning, 409),
            (.unsupportedOperation, 501), (.notImplemented, 501),
            (.daemonUnavailable, 503),
            (.backendFailure, 500), (.ioFailure, 500),
        ]
        for (code, expected) in cases {
            let resp = HTTPResponse.failure(VibeError(code, "boom"))
            XCTAssertEqual(resp.status, expected, "code \(code.rawValue) should map to \(expected)")
            XCTAssertFalse(resp.body.isEmpty, "failure response must carry an envelope")
        }
    }

    func testFailureEnvelopeIsNotOK() throws {
        let resp = HTTPResponse.failure(VibeError(.unauthorized, "denied"))
        let envelope = try JSONDecoder().decode(VibeDecodedResponse<EmptyPayload>.self, from: resp.body)
        XCTAssertFalse(envelope.ok)
        XCTAssertEqual(envelope.error?.code, .unauthorized)
    }

    // MARK: - HTTPResponse.serialize

    func testSerializeBuildsStatusLineAndHeaders() throws {
        let resp = HTTPResponse.json(["a": 1], status: 201)
        let wire = String(data: resp.serialize(), encoding: .utf8) ?? ""
        XCTAssertTrue(wire.hasPrefix("HTTP/1.1 201 Created\r\n"))
        XCTAssertTrue(wire.contains("Content-Length: \(resp.body.count)\r\n"))
        XCTAssertTrue(wire.contains("Connection: close\r\n"))
        XCTAssertTrue(wire.contains("Server: \(VibeVersion.userAgent)\r\n"))
        let headAndBody = wire.split(separator: "\r\n\r\n", maxSplits: 1)
        XCTAssertEqual(headAndBody.count, 2, "head and body must be separated by a blank line")
    }

    func testSerializeUnknownStatusUsesFallbackText() {
        let resp = HTTPResponse(status: 599)
        let wire = String(data: resp.serialize(), encoding: .utf8) ?? ""
        XCTAssertTrue(wire.hasPrefix("HTTP/1.1 599 Status\r\n"))
    }

    // MARK: - HTTPParser

    func testParserParsesSimpleGET() throws {
        let wire = Data("GET /brightness HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        guard case let .complete(req, consumed) = HTTPParser.parse(wire) else {
            return XCTFail("expected complete parse")
        }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/brightness")
        XCTAssertEqual(consumed, wire.count)
    }

    func testParserExtractsQueryParameters() throws {
        let wire = Data("GET /phase?phase=running&x=1 HTTP/1.1\r\n\r\n".utf8)
        guard case let .complete(req, _) = HTTPParser.parse(wire) else {
            return XCTFail("expected complete parse")
        }
        XCTAssertEqual(req.path, "/phase")
        XCTAssertEqual(req.query["phase"], "running")
        XCTAssertEqual(req.query["x"], "1")
    }

    func testParserURLDecodesQueryValues() throws {
        let wire = Data("GET /phase?phase=waiting&msg=hello%20world&plus=a+b HTTP/1.1\r\n\r\n".utf8)
        guard case let .complete(req, _) = HTTPParser.parse(wire) else {
            return XCTFail("expected complete parse")
        }
        XCTAssertEqual(req.query["phase"], "waiting")
        XCTAssertEqual(req.query["msg"], "hello world")
        XCTAssertEqual(req.query["plus"], "a b", "plus signs in query values must decode as spaces")
    }

    func testParserReadsBodyWithContentLength() throws {
        let payload = #"{"phase":"running"}"#
        let wire = Data("POST /phase HTTP/1.1\r\nContent-Length: \(payload.utf8.count)\r\n\r\n\(payload)".utf8)
        guard case let .complete(req, consumed) = HTTPParser.parse(wire) else {
            return XCTFail("expected complete parse")
        }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(String(data: req.body, encoding: .utf8), payload)
        XCTAssertEqual(consumed, wire.count)
    }

    func testParserNeedsMoreWhenBodyIncomplete() {
        let payload = #"{"phase":"running"}"#
        let wire = Data("POST /phase HTTP/1.1\r\nContent-Length: \(payload.utf8.count)\r\n\r\n".utf8)
        guard case .needMore = HTTPParser.parse(wire) else {
            return XCTFail("expected needMore for an incomplete body")
        }
    }

    func testParserFailsOnOversizedBody() {
        // Declares a body larger than the 1 MiB cap without sending it.
        let wire = Data("POST /phase HTTP/1.1\r\nContent-Length: 2097152\r\n\r\n".utf8)
        guard case let .failed(reason) = HTTPParser.parse(wire) else {
            return XCTFail("expected failure for oversized body")
        }
        XCTAssertTrue(reason.contains("1 MiB"))
    }

    func testParserFailsOnMalformedRequestLine() {
        let wire = Data("GARBAGE\r\n\r\n".utf8)
        guard case let .failed(reason) = HTTPParser.parse(wire) else {
            return XCTFail("expected failure for malformed request line")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testParserFailsOnNonUTF8Headers() {
        var bytes = Data("GET / HTTP/1.1\r\nX-Bad: ".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: Data("\r\n\r\n".utf8))
        guard case let .failed(reason) = HTTPParser.parse(bytes) else {
            return XCTFail("expected failure for non-UTF-8 headers")
        }
        XCTAssertTrue(reason.contains("UTF-8"))
    }
}
