import XCTest
@testable import VibeDisplayCore

final class GammaWakeTests: XCTestCase {
    private func display(id: UInt32, uuid: String) -> DisplayInfo {
        DisplayInfo(id: id, uuid: uuid, slug: "panel", name: "Panel", isBuiltin: true,
                    isMain: true, vendorID: 1, modelID: 2, serialNumber: 3, index: 0,
                    width: 1920, height: 1080)
    }

    func testWakeReappliesOnlyToMatchingStableIdentityWithNewRuntimeID() {
        let uuid = "B065541D-B57B-4390-A8BC-ABF1531444B8"
        var writes: [(UInt32, Float)] = []
        let gamma = GammaBackend(setTransfer: { id, scale in
            writes.append((id, scale)); return true
        })
        XCTAssertTrue(gamma.write(display(id: 7, uuid: uuid), value: 0.74))
        let unrelated = display(id: 8, uuid: "A065541D-B57B-4390-A8BC-ABF1531444B8")
        XCTAssertTrue(gamma.reapplyActive(to: [unrelated]).isEmpty)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(gamma.reapplyActive(to: [display(id: 9, uuid: uuid)]), [uuid])
        XCTAssertEqual(writes.last?.0, 9)
        XCTAssertEqual(writes.last?.1, Float(0.74))
    }

    func testFailedWakeWriteClearsStaleReportedDimming() {
        let uuid = "B065541D-B57B-4390-A8BC-ABF1531444B8"
        var allowed = true
        let gamma = GammaBackend(setTransfer: { _, _ in allowed })
        let panel = display(id: 7, uuid: uuid)
        XCTAssertTrue(gamma.write(panel, value: 0.82))
        allowed = false
        XCTAssertTrue(gamma.reapplyActive(to: [panel]).isEmpty)
        XCTAssertNil(gamma.read(panel))
        XCTAssertTrue(gamma.activeDisplayUUIDs.isEmpty)
    }
}
