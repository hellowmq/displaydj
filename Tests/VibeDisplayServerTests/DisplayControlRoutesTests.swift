import XCTest
@testable import VibeDisplayServer
@testable import VibeDisplayCore

final class DisplayControlRoutesTests: XCTestCase {
    private func request(_ method: String, _ path: String, _ body: String = "") -> HTTPRequest {
        HTTPRequest(method: method, path: path, query: [:], headers: [:], body: Data(body.utf8))
    }
    func testNewRoutesValidateBeforeHardwareAndShareProfileStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("displaydj-route-\(UUID().uuidString)")
        let store = DisplayProfileStore(url: root.appendingPathComponent("profiles.json"))
        let state = StateStore(url: root.appendingPathComponent("state.json"))
        let brightness = BrightnessService(store: state)
        let controls = MonitorControlService(inventory: { XCTFail("invalid input must not query hardware"); return [] }, read: { _, _ in XCTFail(); return 1 }, write: { _, _, _, _ in XCTFail(); return 1 })
        let modes = DisplayModeService(inventory: { XCTFail(); return [] }, read: { _ in XCTFail(); throw VibeError(.backendFailure, "unexpected") }, apply: { _, _ in XCTFail() })
        let sessions = AgentSessionManager(brightness: brightness, store: state)
        let router = APIRouter.make(brightness: brightness, sessions: sessions, startedAt: Date(), controls: controls, modes: modes, profileStore: store)
        for req in [
            request("POST", "/v1/controls/volume", "{\"target\":\"50%\"}"),
            request("POST", "/v1/controls/volume", "{\"selector\":\"\",\"target\":\"50%\"}"),
            request("POST", "/v1/controls/volume", "{\"selector\":\"external\",\"target\":\"restore\"}"),
            request("POST", "/v1/controls/mute", "{\"selector\":\"external\",\"target\":\"1\"}"),
            request("POST", "/v1/modes", "{\"modeID\":1}"),
            request("POST", "/v1/modes", "{\"selector\":\"\",\"modeID\":1}"),
            request("POST", "/v1/modes", "{\"selector\":\"main\",\"modeID\":1,\"dryRun\":\"false\"}"),
        ] { XCTAssertEqual(router.handle(req).status, 400, req.path) }
        let profile = DisplayProfile(name: "夜间模式", savedAt: Date(), displays: [DisplayProfileEntry(displayUUID: "B065541D-B57B-4390-A8BC-ABF1531444B8", name: "Panel", brightness: 0.6, transport: .ddc)])
        try store.save(profile)
        let path = "/v1/profiles/" + profile.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        XCTAssertEqual(router.handle(request("GET", path)).status, 200)
        XCTAssertEqual(router.handle(request("DELETE", path)).status, 200)
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testControlPreviewReportsPlannedValueAndNoWrite() throws {
        let display = DisplayInfo(id: 1, uuid: "B065541D-B57B-4390-A8BC-ABF1531444B8", slug: "panel", name: "Panel", isBuiltin: false, isMain: true, vendorID: 1, modelID: 2, serialNumber: 3, index: 0, width: 1920, height: 1080)
        let controls = MonitorControlService(inventory: { [display] }, read: { _, _ in 0.4 }, write: { _, _, _, _ in XCTFail("preview wrote hardware"); return 0 })
        let router = APIRouter.make(startedAt: Date(), controls: controls)
        let response = router.handle(request("POST", "/v1/controls/contrast", "{\"selector\":\"external\",\"target\":\"+10%\",\"dryRun\":true}"))
        XCTAssertEqual(response.status, 200)
        let decoded = try JSONCoding.decoder.decode(VibeDecodedResponse<Results>.self, from: response.body)
        XCTAssertEqual(decoded.data?.results.first?.requested, 0.5)
        XCTAssertEqual(decoded.data?.results.first?.dryRun, true)
        XCTAssertEqual(decoded.data?.results.first?.verified, false)
    }
    private struct Results: Decodable { let results: [MonitorControlResult] }
}
