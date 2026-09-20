import XCTest
@testable import VibeDisplayCore

/// A config file is the one input a user hand-edits. Validation has to reject
/// anything that would make phase behaviour ambiguous, and it has to do so at
/// load time — not halfway through an agent run.
final class ConfigTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultConfigIsValid() throws {
        XCTAssertNoThrow(try VibeConfig().validate())
    }

    func testDefaultsAreConservative() {
        let config = VibeConfig()
        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.defaultSelector, "all")
        XCTAssertEqual(config.daemon.host, "127.0.0.1", "the daemon must never default to a routable address")
        XCTAssertTrue(config.daemon.requireToken, "auth must be opt-out, never opt-in")
        XCTAssertGreaterThan(config.daemon.sessionReaperTTLSeconds, 0,
                             "without a reaper TTL a crashed agent owns the screen forever")
    }

    /// The waiting phase is the one that asks for a human. It must be the
    /// brightest of the working phases or the signal is useless.
    func testWaitingIsBrighterThanRunning() throws {
        let phases = VibeConfig.defaultPhases
        guard case let .absolute(waiting) = try BrightnessTarget.parse(phases["waiting"]!.brightness!),
              case let .absolute(running) = try BrightnessTarget.parse(phases["running"]!.brightness!) else {
            return XCTFail("both phases should declare absolute brightness")
        }
        XCTAssertGreaterThan(waiting, running)
    }

    // MARK: - Validation

    func testUnsupportedVersionIsRejected() {
        var config = VibeConfig()
        config.version = 2
        assertConfigInvalid(config)
    }

    func testPortRangeIsChecked() {
        for port in [0, -1, 65536, 99999] {
            var config = VibeConfig()
            config.daemon.port = port
            assertConfigInvalid(config, "port \(port) should be rejected")
        }
        for port in [1, 7643, 65535] {
            var config = VibeConfig()
            config.daemon.port = port
            XCTAssertNoThrow(try config.validate(), "port \(port) should be accepted")
        }
    }

    func testUnknownPhaseKeyIsRejected() {
        var config = VibeConfig()
        config.phases["finished"] = PhaseProfile(brightness: "50%")
        assertConfigInvalid(config)
    }

    /// A bad brightness expression buried in a phase must fail at load, not
    /// when the agent happens to enter that phase two hours later.
    func testBadPhaseBrightnessIsRejectedAtLoadTime() {
        var config = VibeConfig()
        config.phases[AgentPhase.running.rawValue] = PhaseProfile(brightness: "very bright")
        assertConfigInvalid(config)
    }

    func testDisplayOverrideRangesAreChecked() {
        for bad in [-0.1, 1.1] {
            var lo = VibeConfig()
            lo.displays["dell"] = DisplayOverride(minBrightness: bad)
            assertConfigInvalid(lo, "minBrightness \(bad) should be rejected")

            var hi = VibeConfig()
            hi.displays["dell"] = DisplayOverride(maxBrightness: bad)
            assertConfigInvalid(hi, "maxBrightness \(bad) should be rejected")
        }
    }

    func testNilBrightnessMeansLeaveItAlone() throws {
        var config = VibeConfig()
        config.phases[AgentPhase.running.rawValue] = PhaseProfile(brightness: nil, keepAwake: [.display])
        XCTAssertNoThrow(try config.validate())
        XCTAssertNil(config.profile(for: .running).brightness)
    }

    // MARK: - Serialisation

    func testRoundTripsThroughJSON() throws {
        var original = VibeConfig()
        original.defaultSelector = "external"
        original.defaultRampMs = 250
        original.daemon.port = 7644
        original.displays["dell-u2723qe"] = DisplayOverride(ddcServiceIndex: 1, minBrightness: 0.1, maxBrightness: 0.9)
        original.phases[AgentPhase.waiting.rawValue] = PhaseProfile(
            brightness: "90%", selector: "main", rampMs: 100,
            keepAwake: [.display, .system], keepAwakeTTLSeconds: 600
        )

        let data = try JSONCoding.encoder.encode(original)
        let decoded = try JSONCoding.decoder.decode(VibeConfig.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertNoThrow(try decoded.validate())
    }

    /// An unknown phase in a file on disk must surface as a config error, not
    /// a decoding stack trace.
    func testMalformedFileIsAConfigError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-config-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("config.json")
        try Data("{ not json at all".utf8).write(to: file)
        XCTAssertThrowsError(try ConfigLoader.load(from: file)) { error in
            XCTAssertEqual((error as? VibeError)?.code, .configInvalid)
        }

        try Data(#"{"version":1,"defaultSelector":"all","defaultRampMs":400,"phases":{"nope":{"keepAwake":[]}},"displays":{},"daemon":{"host":"127.0.0.1","port":7643,"requireToken":true,"sessionReaperTTLSeconds":900}}"#.utf8)
            .write(to: file)
        XCTAssertThrowsError(try ConfigLoader.load(from: file)) { error in
            XCTAssertEqual((error as? VibeError)?.code, .invalidArgument,
                           "an unknown phase key should be reported as an argument problem, with the phase list")
        }
    }

    /// An absent file is not an error — a fresh machine must work with zero
    /// setup, which is the whole point of shipping defaults.
    func testMissingFileFallsBackToDefaults() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-absent-\(UUID().uuidString).json")
        XCTAssertEqual(try ConfigLoader.load(from: missing), VibeConfig())
    }

    // MARK: - Helpers

    private func assertConfigInvalid(_ config: VibeConfig,
                                     _ message: String = "config should be invalid",
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        XCTAssertThrowsError(try config.validate(), message, file: file, line: line) { error in
            let code = (error as? VibeError)?.code
            XCTAssertTrue(code == .configInvalid || code == .invalidArgument,
                          "expected a config/argument error, got \(String(describing: code))",
                          file: file, line: line)
        }
    }
}
