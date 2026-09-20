import XCTest
@testable import VibeDisplayCore

/// Selector resolution is pure logic over a display list, so it is fully
/// testable without hardware. These tests are the contract for how humans and
/// agents address displays.
final class SelectorTests: XCTestCase {

    private func fixture() -> [DisplayInfo] {
        [
            DisplayInfo(id: 1, uuid: "UUID-BUILTIN", slug: "built-in-display",
                        name: "Built-in Display", isBuiltin: true, isMain: true,
                        vendorID: 0x610, modelID: 0xA050, serialNumber: 0,
                        index: 0, width: 3024, height: 1964),
            DisplayInfo(id: 2, uuid: "UUID-DELL", slug: "dell-u2723qe",
                        name: "DELL U2723QE", isBuiltin: false, isMain: false,
                        vendorID: 0x10AC, modelID: 0x41B0, serialNumber: 123,
                        index: 1, width: 3840, height: 2160),
            DisplayInfo(id: 3, uuid: "UUID-LG", slug: "lg-ultrafine",
                        name: "LG UltraFine", isBuiltin: false, isMain: false,
                        vendorID: 0x1E6D, modelID: 0x5B11, serialNumber: 456,
                        index: 2, width: 5120, height: 2880)
        ]
    }

    func testKeywordSelectors() throws {
        let all = fixture()
        XCTAssertEqual(try DisplaySelector("all").resolve(in: all).count, 3)
        XCTAssertEqual(try DisplaySelector("builtin").resolve(in: all).map(\.slug), ["built-in-display"])
        XCTAssertEqual(try DisplaySelector("external").resolve(in: all).count, 2)
        XCTAssertEqual(try DisplaySelector("main").resolve(in: all).map(\.uuid), ["UUID-BUILTIN"])
    }

    func testAddressingForms() throws {
        let all = fixture()
        XCTAssertEqual(try DisplaySelector("#1").resolve(in: all).map(\.slug), ["dell-u2723qe"])
        XCTAssertEqual(try DisplaySelector("2").resolve(in: all).map(\.slug), ["lg-ultrafine"])
        XCTAssertEqual(try DisplaySelector("id:3").resolve(in: all).map(\.slug), ["lg-ultrafine"])
        XCTAssertEqual(try DisplaySelector("uuid:UUID-DELL").resolve(in: all).map(\.slug), ["dell-u2723qe"])
    }

    func testFuzzyMatchingPrefersExactThenPrefixThenSubstring() throws {
        let all = fixture()
        XCTAssertEqual(try DisplaySelector("dell-u2723qe").resolve(in: all).count, 1)
        XCTAssertEqual(try DisplaySelector("dell").resolve(in: all).count, 1)
        XCTAssertEqual(try DisplaySelector("ultrafine").resolve(in: all).count, 1)
        XCTAssertEqual(try DisplaySelector("DELL U2723QE").resolve(in: all).count, 1)
    }

    /// An ambiguous token must fail loudly. Silently picking one display would
    /// mean an agent dims the wrong screen.
    func testAmbiguityIsAnError() {
        let clashing = [
            DisplayInfo(id: 1, uuid: "A", slug: "dell-a", name: "DELL A", isBuiltin: false, isMain: false,
                        vendorID: 0, modelID: 0, serialNumber: 0, index: 0, width: 100, height: 100),
            DisplayInfo(id: 2, uuid: "B", slug: "dell-b", name: "DELL B", isBuiltin: false, isMain: false,
                        vendorID: 0, modelID: 0, serialNumber: 0, index: 1, width: 100, height: 100)
        ]
        XCTAssertThrowsError(try DisplaySelector("dell").resolve(in: clashing)) { error in
            XCTAssertEqual((error as? VibeError)?.code, .ambiguousSelector)
        }
    }

    func testUnknownSelectorIsNotFound() {
        XCTAssertThrowsError(try DisplaySelector("nope").resolve(in: fixture())) { error in
            XCTAssertEqual((error as? VibeError)?.code, .displayNotFound)
        }
    }

    func testRoundTripsThroughRawValue() {
        for raw in ["all", "builtin", "external", "main", "#2", "id:7", "uuid:XYZ", "dell"] {
            XCTAssertEqual(DisplaySelector(raw).rawValue, raw, "selector '\(raw)' did not round-trip")
        }
    }

    func testSlugify() {
        XCTAssertEqual(DisplayRegistry.slugify("DELL U2723QE"), "dell-u2723qe")
        XCTAssertEqual(DisplayRegistry.slugify("Built-in Display"), "built-in-display")
        XCTAssertEqual(DisplayRegistry.slugify("  LG  UltraFine  5K  "), "lg-ultrafine-5k")
        XCTAssertEqual(DisplayRegistry.slugify("!!!"), "")
    }
}
