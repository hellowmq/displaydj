import XCTest
@testable import VibeDisplayCore

/// Direct coverage of `TokenStore` and `DaemonDescriptor` — the auth and
/// service-discovery surface the daemon's loopback HTTP API relies on.
/// Both are pure logic over `Paths`, which relocates via `DISPLAYDJ_HOME`,
/// so a temp dir keeps this suite hermetic (no real `~/.displaydj`).
final class DaemonDescriptorTests: XCTestCase {

    private var dir: URL!
    private var oldHome: String?
    private var oldToken: String?

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-desctest-\(UUID().uuidString)", isDirectory: true)
        oldHome = ProcessInfo.processInfo.environment["DISPLAYDJ_HOME"]
        oldToken = ProcessInfo.processInfo.environment["DISPLAYDJ_TOKEN"]
        setenv("DISPLAYDJ_HOME", dir.path, 1)
        unsetenv("DISPLAYDJ_TOKEN")
    }

    override func tearDown() {
        if let oldHome { setenv("DISPLAYDJ_HOME", oldHome, 1) } else { unsetenv("DISPLAYDJ_HOME") }
        if let oldToken { setenv("DISPLAYDJ_TOKEN", oldToken, 1) } else { unsetenv("DISPLAYDJ_TOKEN") }
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - TokenStore

    /// The env token wins over a persisted file: agents in CI can inject a
    /// token without touching the daemon's on-disk state.
    func testEnvTokenTakesPrecedenceOverFile() throws {
        let fileToken = try TokenStore.loadOrCreate()
        setenv("DISPLAYDJ_TOKEN", "env-token", 1)
        XCTAssertEqual(TokenStore.load(), "env-token",
                       "DISPLAYDJ_TOKEN must shadow the token file")
        XCTAssertNotEqual(fileToken, "env-token")
    }

    /// An empty env var is treated as unset and falls through to the file.
    func testEmptyEnvTokenFallsThroughToFile() throws {
        let fileToken = try TokenStore.loadOrCreate()
        setenv("DISPLAYDJ_TOKEN", "", 1)
        XCTAssertEqual(TokenStore.load(), fileToken)
    }

    /// Repeated calls must never mint a second token: the daemon and CLI
    /// racing on first boot share one secret.
    func testLoadOrCreateIsIdempotent() throws {
        let first = try TokenStore.loadOrCreate()
        let second = try TokenStore.loadOrCreate()
        XCTAssertEqual(first, second, "loadOrCreate must be idempotent")
    }

    /// 24 random bytes -> 48 lowercase hex chars.
    func testGeneratedTokenIs48Hex() throws {
        let token = try TokenStore.loadOrCreate()
        XCTAssertEqual(token.count, 48)
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                       "token must be lowercase hex")
    }

    /// Rotate must write a new secret to disk and invalidate the old one.
    func testRotateReplacesToken() throws {
        let old = try TokenStore.loadOrCreate()
        let rotated = try TokenStore.rotate()
        XCTAssertNotEqual(rotated, old)
        XCTAssertEqual(TokenStore.load(), rotated, "load after rotate must see the new token")
        XCTAssertNotEqual(TokenStore.load(), old)
    }

    /// The token file must be 0600 — loopback is shared with every local process.
    func testTokenFileIs0600() throws {
        _ = try TokenStore.loadOrCreate()
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("token").path)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "token file must be 0600, got \(String(describing: perms))")
    }

    // MARK: - DaemonDescriptor

    /// baseURL is the only derived value: host+port glued into a URL.
    func testBaseURL() {
        let descriptor = DaemonDescriptor(pid: 42, host: "127.0.0.1", port: 7643,
                                          version: "0.1.0", requiresToken: true)
        XCTAssertEqual(descriptor.baseURL, "http://127.0.0.1:7643")
    }

    /// JSON round-trip must survive the daemon writing the file and a CLI
    /// reading it back — same encoder/decoder pair, iso8601 dates.
    func testJSONRoundTrip() throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000) // whole second, iso8601-safe
        let descriptor = DaemonDescriptor(pid: 42, host: "127.0.0.1", port: 7643,
                                          version: "0.1.0", startedAt: started,
                                          requiresToken: false)
        let data = try JSONCoding.encoder.encode(descriptor)
        let decoded = try JSONCoding.decoder.decode(DaemonDescriptor.self, from: data)
        XCTAssertEqual(decoded, descriptor)
    }

    /// write + loadIfAlive round-trip: a live pid (this test process) must be
    /// returned as-is; the stale-file deletion path is left to the harness
    /// since it depends on process-aliveness semantics.
    func testWriteAndLoadIfAlive() throws {
        // Whole-second timestamp: JSONCoding uses iso8601 (second precision),
        // so sub-second components would not survive the round-trip.
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let descriptor = DaemonDescriptor(pid: Int32(getpid()), host: "127.0.0.1",
                                          port: 7643, version: "0.1.0",
                                          startedAt: started, requiresToken: true)
        try descriptor.write()
        let loaded = DaemonDescriptor.loadIfAlive()
        XCTAssertNotNil(loaded, "a descriptor pointing at a live process must load")
        XCTAssertEqual(loaded, descriptor)
    }
}
