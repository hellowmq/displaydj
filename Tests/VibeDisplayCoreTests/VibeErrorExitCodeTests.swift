import XCTest
@testable import VibeDisplayCore

/// Direct coverage of the frozen `VibeError.Code -> process exit code` table.
/// Shell hooks branch on these numbers, so a regression here would silently
/// break every agent wrapper in the wild. `docs/API.md` (Exit codes section)
/// is the source of truth; this test freezes that contract in code.
final class VibeErrorExitCodeTests: XCTestCase {

    /// Every one of the 14 codes must map to the documented number.
    /// Table (docs/API.md):
    ///   2 = bad input      3 = not found      4 = unsupported
    ///   5 = daemon         6 = auth           1 = generic failure
    func testExitCodeFreezeTable() {
        let expectations: [(VibeError.Code, Int32)] = [
            // 2 — bad input
            (.invalidArgument, 2),
            (.configInvalid, 2),
            (.ambiguousSelector, 2),
            // 3 — not found
            (.displayNotFound, 3),
            (.sessionNotFound, 3),
            (.routeNotFound, 3),
            // 4 — unsupported
            (.unsupportedOperation, 4),
            (.notImplemented, 4),
            // 5 — daemon
            (.daemonUnavailable, 5),
            (.daemonAlreadyRunning, 5),
            // 6 — auth
            (.unauthorized, 6),
            // 1 — generic failure (default; session_conflict is not in the
            // documented table but must not crash a shell hook)
            (.backendFailure, 1),
            (.ioFailure, 1),
            (.sessionConflict, 1),
        ]
        XCTAssertEqual(expectations.count, 14, "the table must cover all 14 codes")
        for (code, expected) in expectations {
            XCTAssertEqual(VibeError(code, "probe").exitCode, expected,
                           "\(code.rawValue) must exit \(expected)")
        }
    }

    /// Sanity: the raw value used in logs/HTTP is the stable snake_case string.
    func testRawValuesAreStable() {
        XCTAssertEqual(VibeError.Code.invalidArgument.rawValue, "invalid_argument")
        XCTAssertEqual(VibeError.Code.daemonUnavailable.rawValue, "daemon_unavailable")
        XCTAssertEqual(VibeError.Code.notImplemented.rawValue, "not_implemented")
    }

    /// The description is the human-facing surface: code, message, optional hint.
    func testDescriptionWithHintAndWithout() {
        let plain = VibeError(.ioFailure, "disk full")
        XCTAssertEqual(plain.description, "[io_failure] disk full")

        let hinted = VibeError(.unauthorized, "token rejected", hint: "set DISPLAYDJ_TOKEN")
        XCTAssertEqual(hinted.description, "[unauthorized] token rejected — set DISPLAYDJ_TOKEN")
    }
}
