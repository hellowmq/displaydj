import XCTest
@testable import VibeDisplayCore

final class UnifiedBackendTests: XCTestCase {
    private func display(uuid: String = "B065541D-B57B-4390-A8BC-ABF1531444B8", builtin: Bool = false) -> DisplayInfo {
        DisplayInfo(id: 42, uuid: uuid, slug: "panel", name: "Panel", isBuiltin: builtin,
                    isMain: false, vendorID: 1, modelID: 2, serialNumber: 3, index: 0, width: 1920, height: 1080)
    }

    func testCanonicalIdentityAndNormalizedRead() {
        let backend = DDCBackend(read: { selector in
            XCTAssertEqual(selector, "uuid:b065541d-b57b-4390-a8bc-abf1531444b8")
            return 0.37
        }, write: { _, _ in XCTFail("read must never write"); return false })
        XCTAssertEqual(backend.read(display()), 0.37)
    }

    func testInvalidIdentityAndBuiltinNeverReachHardware() {
        let backend = DDCBackend(read: { _ in XCTFail("invalid target"); return 1 },
                                 write: { _, _ in XCTFail("invalid target"); return true })
        XCTAssertNil(backend.read(display(uuid: "VMS-1-2-3")))
        XCTAssertFalse(backend.write(display(builtin: true), value: 0.4))
        XCTAssertFalse(backend.write(display(), value: .nan))
        XCTAssertFalse(backend.write(display(), value: .infinity))
    }

    func testVerifiedResultAndFailureAreNotGuessed() {
        let backend = DDCBackend(read: { _ in throw VibeError(.backendFailure, "read failed") },
                                 write: { _, value in XCTAssertEqual(value, 0.4); return false })
        XCTAssertNil(backend.read(display()))
        XCTAssertFalse(backend.supports(display()))
        XCTAssertFalse(backend.write(display(), value: 0.4))
    }

    func testBridgeAllowsMainActorDiscovery() throws {
        let value = try SynchronousTask.run { await MainActor.run { 42 } }
        XCTAssertEqual(value, 42)
    }

    func testNonFiniteRelativeTargetsAreRejected() {
        for value in ["+inf", "-inf", "+nan", "-nan", "1e999"] {
            XCTAssertThrowsError(try BrightnessTarget.parse(value), value)
        }
    }

    func testUnpluggedDisplayKeepsRecoveryPoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = StateStore(url: directory.appendingPathComponent("state.json"))
        store.mutate { $0.brightnessSnapshots["unplugged-test-display"] = 0.72 }
        let service = BrightnessService(store: store)
        let results = service.restoreAll(ramp: .instant)
        XCTAssertFalse(results.contains { $0.displayUUID == "unplugged-test-display" })
        XCTAssertEqual(store.load().brightnessSnapshots["unplugged-test-display"], 0.72)
        XCTAssertEqual(service.snapshotValues()["unplugged-test-display"], 0.72)
        store.reload()
        XCTAssertEqual(store.load().brightnessSnapshots["unplugged-test-display"], 0.72)
        let manager = AgentSessionManager(brightness: service, store: store)
        _ = manager.panicRestore()
        XCTAssertEqual(store.load().brightnessSnapshots["unplugged-test-display"], 0.72)
    }
}
