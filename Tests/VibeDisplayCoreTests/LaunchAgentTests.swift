import XCTest
import Foundation
@testable import VibeDisplayCore

/// Covers the parts of the LaunchAgent that can be proven without talking to
/// launchd: the job definition it writes and the binary path it resolves.
///
/// Registration itself is deliberately not tested here — `launchctl bootstrap`
/// mutates the user's session, which belongs in a harness tier, not a unit
/// test that has to pass on a CI runner with no GUI.
final class LaunchAgentTests: XCTestCase {

    // MARK: - job definition

    private func decode(_ data: Data) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(object as? [String: Any])
    }

    func testPlistDeclaresLoginStartAndCrashRestart() throws {
        let dict = try decode(LaunchAgent.plistData(
            executable: "/usr/local/bin/display-cli",
            logFile: "/tmp/vd/logs/daemon.log",
            environment: [:]))

        XCTAssertEqual(dict["Label"] as? String, "io.github.hellowmq.displaydj.daemon")
        XCTAssertEqual(dict["RunAtLoad"] as? Bool, true,
                       "without RunAtLoad the daemon never starts at login")
        XCTAssertEqual(dict["KeepAlive"] as? Bool, true,
                       "without KeepAlive a crash is never recovered")
        XCTAssertEqual(dict["ThrottleInterval"] as? Int, 5,
                       "KeepAlive without a throttle respawns a broken binary in a tight loop")
    }

    func testPlistRunsServeWithAnAbsoluteBinary() throws {
        let dict = try decode(LaunchAgent.plistData(
            executable: "/usr/local/bin/display-cli",
            logFile: "/tmp/vd/logs/daemon.log",
            environment: [:]))

        let args = try XCTUnwrap(dict["ProgramArguments"] as? [String])
        XCTAssertEqual(args.first, "/usr/local/bin/display-cli",
                       "launchd does not search PATH, so the binary must be absolute")
        XCTAssertEqual(args.last, "serve")
        XCTAssertTrue(args.first?.hasPrefix("/") == true)
    }

    func testPlistPointsBothStreamsAtTheLogFile() throws {
        let dict = try decode(LaunchAgent.plistData(
            executable: "/bin/true", logFile: "/tmp/vd/logs/daemon.log", environment: [:]))
        XCTAssertEqual(dict["StandardOutPath"] as? String, "/tmp/vd/logs/daemon.log")
        XCTAssertEqual(dict["StandardErrorPath"] as? String, "/tmp/vd/logs/daemon.log")
    }

    func testPlistOmitsEnvironmentWhenHomeIsNotRelocated() throws {
        let dict = try decode(LaunchAgent.plistData(
            executable: "/bin/true", logFile: "/tmp/x.log", environment: [:]))
        XCTAssertNil(dict["EnvironmentVariables"])
    }

    func testPlistPropagatesARelocatedHome() throws {
        // launchd hands the job a near-empty environment. Without this the
        // daemon would read a different config than the CLI that installed it.
        let dict = try decode(LaunchAgent.plistData(
            executable: "/bin/true", logFile: "/tmp/x.log",
            environment: ["DISPLAYDJ_HOME": "/tmp/vd-home"]))
        let env = try XCTUnwrap(dict["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(env["DISPLAYDJ_HOME"], "/tmp/vd-home")
    }

    // MARK: - executable resolution

    func testBareCommandNameIsResolvedThroughPath() {
        let dir = NSTemporaryDirectory() + "vd-path-\(UUID().uuidString)"
        let bin = dir + "/display-cli"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin, contents: nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let expected = URL(fileURLWithPath: bin).resolvingSymlinksInPath().path
        XCTAssertEqual(LaunchAgent.resolveExecutable("display-cli", searchPath: dir, cwd: "/"),
                       expected,
                       "a bare command name has to become an absolute path")
    }

    func testRelativePathIsAnchoredToTheWorkingDirectory() {
        let resolved = LaunchAgent.resolveExecutable("./tool/vibe", searchPath: "", cwd: "/opt")
        XCTAssertTrue(resolved.hasSuffix("/opt/tool/vibe"), "got \(resolved)")
    }

    func testAbsolutePathKeepsItsPrefix() {
        let resolved = LaunchAgent.resolveExecutable("/usr/bin/env", searchPath: "", cwd: "/")
        XCTAssertTrue(resolved.hasPrefix("/"), "got \(resolved)")
    }

    func testUnresolvableBareNameFallsBackToTheWorkingDirectory() {
        // Nothing on PATH: anchor to the cwd rather than inventing a path, so
        // the caller's "not executable" error quotes somewhere the user can
        // actually look instead of a bare command name.
        let resolved = LaunchAgent.resolveExecutable("not-a-real-binary",
                                                     searchPath: "/nonexistent",
                                                     cwd: "/opt/vd")
        XCTAssertTrue(resolved.hasPrefix("/"), "the job needs an absolute path, got \(resolved)")
        XCTAssertTrue(resolved.hasSuffix("not-a-real-binary"), "got \(resolved)")
    }

    // MARK: - sandbox redirection

    func testAgentsDirectoryIsOverridableForTests() {
        let sandbox = "/tmp/vd-agents-\(UUID().uuidString)"
        setenv("DISPLAYDJ_LAUNCH_AGENTS_DIR", sandbox, 1)
        defer { unsetenv("DISPLAYDJ_LAUNCH_AGENTS_DIR") }

        XCTAssertEqual(LaunchAgent.agentsDirectory.path, sandbox,
                       "the harness must be able to install into a sandbox")
        XCTAssertEqual(LaunchAgent.plistURL.path, sandbox + "/io.github.hellowmq.displaydj.daemon.plist")
    }

    func testStatusReportsThePlistLocation() {
        let sandbox = "/tmp/vd-agents-\(UUID().uuidString)"
        setenv("DISPLAYDJ_LAUNCH_AGENTS_DIR", sandbox, 1)
        defer { unsetenv("DISPLAYDJ_LAUNCH_AGENTS_DIR") }

        let status = LaunchAgent.status(loaded: nil)
        XCTAssertEqual(status.label, "io.github.hellowmq.displaydj.daemon")
        XCTAssertEqual(status.plistPath, sandbox + "/io.github.hellowmq.displaydj.daemon.plist")
        // "installed" reflects the sandbox, which this test never writes to.
        XCTAssertFalse(status.installed)
        XCTAssertNil(status.loaded, "not consulted is not the same as not loaded")
    }
}
