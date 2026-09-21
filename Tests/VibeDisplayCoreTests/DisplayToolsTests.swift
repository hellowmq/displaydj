import XCTest
@testable import VibeDisplayCore

final class DisplayToolsTests: XCTestCase {
    private let uuid = "B065541D-B57B-4390-A8BC-ABF1531444B8"
    private func display(builtin: Bool = false, transport: BrightnessTransport = .ddc) -> DisplayInfo {
        DisplayInfo(id: 7, uuid: uuid, slug: "panel", name: "Panel", isBuiltin: builtin, isMain: true,
                    vendorID: 1, modelID: 2, serialNumber: 3, index: 0, width: 1920, height: 1080,
                    capability: DisplayCapability(canReadBrightness: true, canWriteBrightness: true, transports: [transport], preferred: transport))
    }
    private func store() -> DisplayProfileStore {
        DisplayProfileStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("displaydj-profiles-\(UUID().uuidString)/profiles.json"))
    }
    private func result(_ d: DisplayInfo, _ value: Double, ok: Bool = true) -> BrightnessApplyResult {
        BrightnessApplyResult(displayUUID: d.uuid, slug: d.slug, requested: value, applied: ok ? value : nil, transport: d.capability.preferred, ok: ok, error: ok ? nil : "injected failure")
    }
    func testEmptyAndAmbiguousExactSelectorsAreRejected() {
        XCTAssertThrowsError(try DisplaySelector("").resolve(in: [display()]))
        XCTAssertThrowsError(try DisplaySelector("Panel").resolve(in: [display(), display()]))
        XCTAssertThrowsError(try DisplaySelector("uuid:" + uuid).resolve(in: [display(), display()]))
    }

    func testControlPreviewNeverWritesAndRelativeUsesTransaction() throws {
        var writes = 0
        let service = MonitorControlService(inventory: { [self.display()] }, read: { control, id in
            XCTAssertEqual(control, .volume); XCTAssertEqual(id, "uuid:\(self.uuid.lowercased())"); return 0.6
        }, write: { control, _, value, relative in
            XCTAssertEqual(control, .volume); XCTAssertEqual(value, -0.1); XCTAssertTrue(relative); writes += 1; return 0.5
        })
        let preview = try service.set(.volume, target: "+10%", selector: .all, dryRun: true)
        XCTAssertEqual(preview[0].requested!, 0.7, accuracy: 0.0001)
        XCTAssertFalse(preview[0].verified); XCTAssertEqual(writes, 0)
        let applied = try service.set(.volume, target: "-10%", selector: .all)
        XCTAssertEqual(applied[0].value, 0.5); XCTAssertTrue(applied[0].verified); XCTAssertEqual(writes, 1)
        XCTAssertThrowsError(try service.set(.volume, target: "restore", selector: .all))
        XCTAssertThrowsError(try service.set(.volume, target: "+101%", selector: .all))
    }
    func testUnsupportedControlAndReadFailureAreVisible() throws {
        let service = MonitorControlService(inventory: { [self.display(builtin: true)] }, read: { _, _ in XCTFail(); return 1 }, write: { _, _, _, _ in XCTFail(); return 1 })
        XCTAssertFalse(try service.read(.contrast, selector: .all)[0].ok)
        XCTAssertFalse(try service.set(.volume, target: "0.5", selector: .all)[0].ok)
        let failed = MonitorControlService(inventory: { [self.display()] }, read: { _, _ in .nan }, write: { _, _, _, _ in .infinity })
        XCTAssertFalse(try failed.read(.contrast, selector: .all)[0].ok)
    }
    func testModePreviewAndReadbackRollback() throws {
        let original = DisplayModeInfo(id: 1, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60)
        let target = DisplayModeInfo(id: 2, width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, refreshRate: 75)
        var writes: [Int32] = []
        let service = DisplayModeService(inventory: { [self.display()] }, read: { _ in (original, [original, target]) }, apply: { _, mode in writes.append(mode) })
        let preview = try service.set(2, selector: .main, dryRun: true)
        XCTAssertTrue(preview.dryRun); XCTAssertFalse(preview.verified); XCTAssertTrue(writes.isEmpty)
        XCTAssertThrowsError(try service.set(999, selector: .main))
        XCTAssertTrue(writes.isEmpty)
        XCTAssertThrowsError(try service.set(2, selector: .main))
        XCTAssertEqual(writes, [2, 1])
        let json = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(preview.previous)) as! [String: Any]
        XCTAssertEqual(json["hiDPI"] as? Bool, true)
    }
    func testModeRejectsMultipleDisplaysBeforeWrite() throws {
        let service = DisplayModeService(inventory: { [self.display(), self.display()] }, read: { _ in XCTFail(); throw VibeError(.backendFailure, "unexpected") }, apply: { _, _ in XCTFail() })
        XCTAssertThrowsError(try service.set(1, selector: .all))
    }
    func testProfilePersistencePreviewAndReplace() throws {
        let store = store()
        var value = 0.7
        var writes = 0
        let service = DisplayProfileService(store: store, inventory: { [self.display()] }, read: { _ in value }, write: { d, v in writes += 1; return self.result(d, v) })
        _ = try service.save("work", selector: .all)
        XCTAssertThrowsError(try service.save("work", selector: .all))
        value = 0.3
        let preview = try service.apply("work", dryRun: true)
        XCTAssertEqual(preview.plan.first?.requested, 0.7); XCTAssertEqual(preview.plan.first?.previous, 0.3)
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(try service.apply("work").ok); XCTAssertEqual(writes, 1)
        _ = try service.save("work", selector: .all, replace: true)
        XCTAssertEqual(try store.get("work").displays.first?.brightness, 0.3)
        try store.delete("work"); XCTAssertTrue(try store.list().isEmpty)
        XCTAssertThrowsError(try store.get("work"))
    }
    func testChineseProfileNamePersistsAndApplies() throws {
        let store = store()
        let name = "夜间模式_2"
        let service = DisplayProfileService(store: store, inventory: { [self.display()] }, read: { _ in 0.4 }, write: { d, v in self.result(d, v) })
        _ = try service.save(name, selector: .all)
        XCTAssertEqual(try store.list().map(\.name), [name])
        XCTAssertEqual(try store.get(name).name, name)
        XCTAssertEqual(try service.apply(name, dryRun: true).name, name)
        try store.delete(name)
        XCTAssertTrue(try store.list().isEmpty)
    }
    func testProfilePreflightRejectsTransportChangeOrMissingDisplay() throws {
        let store = store()
        let service = DisplayProfileService(store: store, inventory: { [self.display()] }, read: { _ in 0.7 }, write: { d, v in XCTFail(); return self.result(d, v) })
        _ = try service.save("work", selector: .all)
        let offline = DisplayProfileService(store: store, inventory: { [] }, read: { _ in XCTFail(); return 1 }, write: { d, v in XCTFail(); return self.result(d, v) })
        XCTAssertThrowsError(try offline.apply("work"))
        let changed = DisplayProfileService(store: store, inventory: { [self.display(transport: .gamma)] }, read: { _ in 1 }, write: { d, v in XCTFail(); return self.result(d, v) })
        XCTAssertThrowsError(try changed.apply("work"))
    }
    func testProfileFailedWriteIsRolledBackAndReported() throws {
        let store = store()
        var current = 0.7
        var values: [Double] = []
        let service = DisplayProfileService(store: store, inventory: { [self.display()] }, read: { _ in current }, write: { d, v in
            values.append(v); return self.result(d, v, ok: values.count > 1)
        })
        _ = try service.save("work", selector: .all)
        current = 0.3
        let report = try service.apply("work")
        XCTAssertFalse(report.ok); XCTAssertEqual(values, [0.7, 0.3]); XCTAssertTrue(report.rollback[0].ok)
    }
    func testCorruptProfilesAreNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("displaydj-corrupt-\(UUID().uuidString).json")
        let bytes = Data("broken".utf8)
        try bytes.write(to: url)
        let store = DisplayProfileStore(url: url)
        XCTAssertThrowsError(try store.list())
        XCTAssertThrowsError(try store.save(DisplayProfile(name: "work", savedAt: Date(), displays: [DisplayProfileEntry(displayUUID: uuid, name: "Panel", brightness: 0.5, transport: .ddc)])))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        for name in ["", "../work", "a/b", "a b"] { XCTAssertThrowsError(try DisplayProfileStore.validateName(name)) }
    }
    func testMultiDisplayPreflightAndReverseRollback() throws {
        let first = display()
        let second = DisplayInfo(id: 8, uuid: "B065541D-B57B-4390-A8BC-ABF1531444B9", slug: "panel-2", name: "Second", isBuiltin: false, isMain: false, vendorID: 1, modelID: 2, serialNumber: 4, index: 1, width: 1920, height: 1080, capability: first.capability)
        var online = [first, second]
        var writes: [String] = []
        let service = DisplayProfileService(store: store(), inventory: { online }, read: { _ in 0.6 }, write: { d, value in
            writes.append(d.uuid)
            return self.result(d, value, ok: writes.count != 2)
        })
        _ = try service.save("both", selector: .all)
        online = [first]
        XCTAssertThrowsError(try service.apply("both"))
        XCTAssertTrue(writes.isEmpty)
        online = [first, second]
        let report = try service.apply("both")
        XCTAssertFalse(report.ok)
        XCTAssertEqual(writes, [first.uuid, second.uuid, second.uuid, first.uuid])
        XCTAssertEqual(report.rollback.count, 2)
    }

    func testModeSuccessfulWriteReportsObservedAndProfileStoresRereadDisk() throws {
        let original = DisplayModeInfo(id: 1, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60)
        let target = DisplayModeInfo(id: 2, width: 1280, height: 720, pixelWidth: 1280, pixelHeight: 720, refreshRate: 60)
        var current = original
        let service = DisplayModeService(inventory: { [self.display()] }, read: { _ in (current, [original, target]) }, apply: { _, _ in current = target })
        let report = try service.set(2, selector: .main)
        XCTAssertTrue(report.verified)
        XCTAssertEqual(report.observed, target)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("displaydj-shared-\(UUID().uuidString)/profiles.json")
        let firstStore = DisplayProfileStore(url: url)
        let secondStore = DisplayProfileStore(url: url)
        let entries = [DisplayProfileEntry(displayUUID: uuid, name: "Panel", brightness: 0.5, transport: .ddc)]
        try firstStore.save(DisplayProfile(name: "one", savedAt: Date(), displays: entries))
        XCTAssertEqual(try secondStore.list().count, 1)
        try secondStore.save(DisplayProfile(name: "two", savedAt: Date(), displays: entries))
        XCTAssertEqual(try firstStore.list().map(\.name), ["one", "two"])
    }

}
