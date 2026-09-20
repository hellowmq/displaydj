import XCTest
@testable import VibeDisplayCore

/// Phase names are the vocabulary every integration writes into its hooks.
/// Once an alias ships it can never be removed without breaking someone's
/// `settings.json`, so each one is locked down by a test.
final class PhaseTests: XCTestCase {

    func testCanonicalNamesParse() throws {
        for phase in AgentPhase.allCases {
            XCTAssertEqual(try AgentPhase.parse(phase.rawValue), phase)
        }
    }

    func testAliases() throws {
        let table: [String: AgentPhase] = [
            "none": .idle,
            "start": .starting, "begin": .starting,
            "run": .running, "progress": .running, "working": .running,
            "wait": .waiting, "blocked": .waiting, "review": .waiting,
            "success": .succeeded, "ok": .succeeded, "done": .succeeded, "pass": .succeeded,
            "fail": .failed, "error": .failed, "fatal": .failed
        ]
        for (alias, expected) in table {
            XCTAssertEqual(try AgentPhase.parse(alias), expected, "alias '\(alias)' regressed")
        }
    }

    func testParsingIsCaseAndWhitespaceInsensitive() throws {
        XCTAssertEqual(try AgentPhase.parse("  RUNNING "), .running)
        XCTAssertEqual(try AgentPhase.parse("Failed"), .failed)
        XCTAssertEqual(try AgentPhase.parse("\tOK"), .succeeded)
    }

    func testUnknownPhaseFailsWithTheListOfValidOnes() {
        XCTAssertThrowsError(try AgentPhase.parse("finished")) { error in
            let err = error as? VibeError
            XCTAssertEqual(err?.code, .invalidArgument)
            // The hint must enumerate the real phases; an agent recovers from
            // this by reading it, not by guessing.
            for phase in AgentPhase.allCases {
                XCTAssertTrue(err?.hint?.contains(phase.rawValue) ?? false,
                              "hint should mention '\(phase.rawValue)'")
            }
        }
    }

    /// Terminal phases are the ones that must release keep-awake leases and
    /// restore brightness. Getting this set wrong pins the screen on forever.
    func testTerminalClassification() {
        XCTAssertTrue(AgentPhase.idle.isTerminal)
        XCTAssertTrue(AgentPhase.succeeded.isTerminal)
        XCTAssertTrue(AgentPhase.failed.isTerminal)
        XCTAssertFalse(AgentPhase.starting.isTerminal)
        XCTAssertFalse(AgentPhase.running.isTerminal)
        XCTAssertFalse(AgentPhase.waiting.isTerminal)
    }

    func testPhaseIsCodableAsItsRawString() throws {
        let data = try JSONCoding.encoder.encode(AgentPhase.waiting)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"waiting\"")
        XCTAssertEqual(try JSONCoding.decoder.decode(AgentPhase.self, from: data), .waiting)
    }

    /// Every phase must have a profile, otherwise a transition would be a
    /// silent no-op and the agent's screen would not change.
    func testEveryPhaseHasADefaultProfile() {
        let config = VibeConfig()
        for phase in AgentPhase.allCases {
            let profile = config.profile(for: phase)
            XCTAssertNotNil(VibeConfig.defaultPhases[phase.rawValue],
                            "no default profile for \(phase.rawValue)")
            if phase.isTerminal && phase != .idle {
                XCTAssertEqual(profile.brightness, "restore",
                               "\(phase.rawValue) must hand the screen back to the human")
                XCTAssertTrue(profile.keepAwake.isEmpty,
                              "\(phase.rawValue) must not hold the machine awake")
            }
        }
    }

    /// A session that entered a terminal phase is no longer active — the
    /// reaper and the CLI both branch on this.
    func testSessionActivityFollowsPhase() {
        func session(_ phase: AgentPhase) -> AgentSession {
            AgentSession(id: "s", label: "t", client: "test", phase: phase,
                         selector: "all", expiresAt: Date().addingTimeInterval(60))
        }
        XCTAssertTrue(session(.running).isActive)
        XCTAssertTrue(session(.waiting).isActive)
        XCTAssertFalse(session(.succeeded).isActive)
        XCTAssertFalse(session(.failed).isActive)
    }
}
