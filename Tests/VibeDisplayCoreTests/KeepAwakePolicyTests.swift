import XCTest
@testable import VibeDisplayCore

/// The keep-awake policy is the safety net: it is what guarantees that a
/// crashed agent cannot hold the display on indefinitely. Its arithmetic is
/// pure, so it is tested here rather than by watching a screen for four hours.
final class KeepAwakePolicyTests: XCTestCase {

    // MARK: - TTL

    /// Borrowed from Caffeine's `expireAfterWrite`: a lease nobody keeps
    /// touching must die on its own. A zero or negative TTL would mean
    /// "never expire", which is exactly the failure mode we are preventing.
    func testTTLHasAFloor() {
        XCTAssertEqual(KeepAwakePolicy(ttlSeconds: 0).ttlSeconds, 5)
        XCTAssertEqual(KeepAwakePolicy(ttlSeconds: -60).ttlSeconds, 5)
        XCTAssertEqual(KeepAwakePolicy(ttlSeconds: 1).ttlSeconds, 5)
        XCTAssertEqual(KeepAwakePolicy(ttlSeconds: 300).ttlSeconds, 300)
    }

    func testDefaultPolicyIsBounded() {
        let policy = KeepAwakePolicy.default
        XCTAssertGreaterThanOrEqual(policy.ttlSeconds, 5)
        XCTAssertNotNil(policy.maxDurationSeconds,
                        "the default must carry a hard ceiling even if heartbeats keep arriving")
        XCTAssertEqual(policy.maxDurationSeconds, 4 * 3600)
        XCTAssertFalse(policy.requireACPower, "the default must not silently do nothing on a laptop")
        XCTAssertNil(policy.activeWindow)
    }

    func testPolicyRoundTripsThroughJSON() throws {
        let policy = KeepAwakePolicy(ttlSeconds: 120, maxDurationSeconds: 600,
                                     requireACPower: true, activeWindow: "09:00-20:00")
        let data = try JSONCoding.encoder.encode(policy)
        XCTAssertEqual(try JSONCoding.decoder.decode(KeepAwakePolicy.self, from: data), policy)
    }

    // MARK: - Active window

    private func at(_ hour: Int, _ minute: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        guard let date = Calendar.current.date(from: comps) else {
            XCTFail("could not build a date for \(hour):\(minute)")
            return Date()
        }
        return date
    }

    func testWindowWithinTheSameDay() {
        let window = "09:00-20:00"
        XCTAssertTrue(KeepAwakePolicy.isWithin(window: window, at: at(9, 0)), "start is inclusive")
        XCTAssertTrue(KeepAwakePolicy.isWithin(window: window, at: at(13, 30)))
        XCTAssertTrue(KeepAwakePolicy.isWithin(window: window, at: at(19, 59)))
        XCTAssertFalse(KeepAwakePolicy.isWithin(window: window, at: at(20, 0)), "end is exclusive")
        XCTAssertFalse(KeepAwakePolicy.isWithin(window: window, at: at(8, 59)))
        XCTAssertFalse(KeepAwakePolicy.isWithin(window: window, at: at(3, 0)))
    }

    /// Overnight builds are a real use case, so a window that wraps past
    /// midnight has to work.
    func testWindowWrappingMidnight() {
        let window = "22:00-06:00"
        XCTAssertTrue(KeepAwakePolicy.isWithin(window: window, at: at(23, 30)))
        XCTAssertTrue(KeepAwakePolicy.isWithin(window: window, at: at(0, 1)))
        XCTAssertTrue(KeepAwakePolicy.isWithin(window: window, at: at(5, 59)))
        XCTAssertFalse(KeepAwakePolicy.isWithin(window: window, at: at(6, 0)))
        XCTAssertFalse(KeepAwakePolicy.isWithin(window: window, at: at(12, 0)))
        XCTAssertFalse(KeepAwakePolicy.isWithin(window: window, at: at(21, 59)))
    }

    /// A window that is not parseable must fail *open*. Refusing to keep the
    /// screen awake because of a typo would be a worse outcome than ignoring
    /// the constraint, and the config validator already warns about shape.
    func testMalformedWindowFailsOpen() {
        for window in ["", "nonsense", "09:00", "9-20", "09:00-", "25:99-26:00"] {
            XCTAssertTrue(KeepAwakePolicy.isWithin(window: window, at: at(3, 0)),
                          "malformed window '\(window)' should not disable the lease")
        }
    }

    func testFullDayWindowIsAlwaysOutsideItself() {
        // start == end is a zero-length window: `now >= start && now < end`
        // can never hold. Documented so nobody "fixes" it by accident.
        XCTAssertFalse(KeepAwakePolicy.isWithin(window: "09:00-09:00", at: at(9, 0)))
    }

    // MARK: - Condition evaluation

    func testUnconstrainedPolicyIsAlwaysSatisfied() {
        let (ok, reason) = KeepAwakePolicy(ttlSeconds: 60).conditionsSatisfied(now: at(3, 0))
        XCTAssertTrue(ok)
        XCTAssertNil(reason)
    }

    func testOutsideWindowIsReportedWithAReason() {
        let policy = KeepAwakePolicy(ttlSeconds: 60, activeWindow: "09:00-10:00")
        let (ok, reason) = policy.conditionsSatisfied(now: at(15, 0))
        XCTAssertFalse(ok)
        XCTAssertEqual(reason, "outside active window 09:00-10:00",
                       "the reason is surfaced to the agent, so its wording is part of the contract")
    }

    func testInsideWindowIsSatisfied() {
        let policy = KeepAwakePolicy(ttlSeconds: 60, activeWindow: "09:00-10:00")
        let (ok, reason) = policy.conditionsSatisfied(now: at(9, 30))
        XCTAssertTrue(ok)
        XCTAssertNil(reason)
    }

    // MARK: - Scopes

    func testScopesMapToTheDocumentedIOKitAssertions() {
        XCTAssertEqual(KeepAwakeScope.display.assertionType, "PreventUserIdleDisplaySleep")
        XCTAssertEqual(KeepAwakeScope.system.assertionType, "PreventUserIdleSystemSleep")
        XCTAssertEqual(KeepAwakeScope.disk.assertionType, "PreventDiskIdle")
        XCTAssertEqual(Set(KeepAwakeScope.allCases.map(\.rawValue)), ["display", "system", "disk"])
    }

    func testLeaseRemainingSecondsNeverGoesNegative() {
        let expired = KeepAwakeLease(
            id: "l1", owner: "test", scope: .display, reason: "unit test",
            createdAt: Date().addingTimeInterval(-600),
            lastRenewedAt: Date().addingTimeInterval(-600),
            expiresAt: Date().addingTimeInterval(-60),
            renewCount: 0, policy: .default, suspended: false, suspendedReason: nil
        )
        XCTAssertEqual(expired.remainingSeconds, 0)
        XCTAssertGreaterThanOrEqual(expired.ageSeconds, 600)
    }
}
