import XCTest
@testable import VibeDisplayCore

/// Brightness parsing is the single place where a typo in an agent hook turns
/// into a wrong screen state, so the grammar is pinned down here rather than
/// discovered at runtime on someone's monitor.
final class BrightnessTargetTests: XCTestCase {

    // MARK: - Absolute

    func testAbsoluteFractions() throws {
        XCTAssertEqual(try BrightnessTarget.parse("0"), .absolute(0))
        XCTAssertEqual(try BrightnessTarget.parse("1"), .absolute(1))
        XCTAssertEqual(try BrightnessTarget.parse("0.42"), .absolute(0.42))
        XCTAssertEqual(try BrightnessTarget.parse(" 0.5 "), .absolute(0.5))
    }

    func testAbsolutePercentages() throws {
        XCTAssertEqual(try BrightnessTarget.parse("0%"), .absolute(0))
        XCTAssertEqual(try BrightnessTarget.parse("100%"), .absolute(1))
        guard case let .absolute(v) = try BrightnessTarget.parse("45%") else {
            return XCTFail("45% should be absolute")
        }
        XCTAssertEqual(v, 0.45, accuracy: 1e-9)
    }

    /// `70%` and `0.7` must be the same instruction. If they ever diverge,
    /// every config file in the wild silently changes meaning.
    func testPercentAndFractionAgree() throws {
        for percent in stride(from: 0, through: 100, by: 5) {
            let a = try BrightnessTarget.parse("\(percent)%")
            let b = try BrightnessTarget.parse(String(Double(percent) / 100.0))
            guard case let .absolute(x) = a, case let .absolute(y) = b else {
                return XCTFail("both forms should be absolute at \(percent)%")
            }
            XCTAssertEqual(x, y, accuracy: 1e-9, "\(percent)% disagreed with its fraction")
        }
    }

    // MARK: - Relative

    func testRelativeDeltas() throws {
        XCTAssertEqual(try BrightnessTarget.parse("+0.1"), .relative(0.1))
        XCTAssertEqual(try BrightnessTarget.parse("-0.15"), .relative(-0.15))
        guard case let .relative(up) = try BrightnessTarget.parse("+10%") else {
            return XCTFail("+10% should be relative")
        }
        XCTAssertEqual(up, 0.10, accuracy: 1e-9)
        guard case let .relative(down) = try BrightnessTarget.parse("-25%") else {
            return XCTFail("-25% should be relative")
        }
        XCTAssertEqual(down, -0.25, accuracy: 1e-9)
    }

    /// A signed value is a delta, so it is legitimately allowed to exceed the
    /// 0...1 range that bounds absolute values — clamping happens on apply.
    func testRelativeIsNotRangeChecked() throws {
        XCTAssertEqual(try BrightnessTarget.parse("+2.0"), .relative(2.0))
        XCTAssertEqual(try BrightnessTarget.parse("-500%"), .relative(-5.0))
    }

    // MARK: - Restore

    func testRestoreKeyword() throws {
        XCTAssertEqual(try BrightnessTarget.parse("restore"), .restoreSnapshot)
        XCTAssertEqual(try BrightnessTarget.parse("RESTORE"), .restoreSnapshot)
        XCTAssertEqual(try BrightnessTarget.parse("  Restore "), .restoreSnapshot)
    }

    // MARK: - Rejection

    func testGarbageIsRejected() {
        for raw in ["", "bright", "0.5.5", "%", "abc%", "++1", "one"] {
            XCTAssertThrowsError(try BrightnessTarget.parse(raw), "'\(raw)' should not parse") { error in
                XCTAssertEqual((error as? VibeError)?.code, .invalidArgument)
            }
        }
    }

    func testAbsoluteOutOfRangeIsRejected() {
        for raw in ["1.5", "101%", "2", "999%"] {
            XCTAssertThrowsError(try BrightnessTarget.parse(raw), "'\(raw)' should be out of range") { error in
                XCTAssertEqual((error as? VibeError)?.code, .invalidArgument)
            }
        }
    }

    /// Errors carry a hint because the caller is often a shell script whose
    /// only feedback channel is stderr.
    func testErrorsCarryAHint() {
        XCTAssertThrowsError(try BrightnessTarget.parse("nope")) { error in
            let hint = (error as? VibeError)?.hint
            XCTAssertNotNil(hint)
            XCTAssertFalse(hint?.isEmpty ?? true)
        }
    }

    // MARK: - Ramp

    func testRampClampsNonsenseValues() {
        let negative = BrightnessRamp(durationMs: -100, steps: -5)
        XCTAssertEqual(negative.durationMs, 0)
        XCTAssertEqual(negative.steps, 1, "a ramp must always take at least one step")

        XCTAssertEqual(BrightnessRamp.instant.durationMs, 0)
        XCTAssertEqual(BrightnessRamp.instant.steps, 1)
        XCTAssertGreaterThan(BrightnessRamp.smooth.durationMs, 0)
        XCTAssertGreaterThan(BrightnessRamp.smooth.steps, 1)
    }
}
