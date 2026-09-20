import XCTest
@testable import VibeDisplayCore

/// Direct coverage of `StateStore`'s crash-tolerance surface, which the
/// indirect callers (WrapUpFixTests, APIRouterTests) never assert on:
/// corrupt-file recovery, `reload` re-reading an external write, and
/// `reset` wiping memory and disk. All tests inject a temp-file URL, so a
/// test run can never touch the developer's real `~/.displaydj/state.json`.
final class StateStoreTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-statetest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeStore() -> StateStore {
        StateStore(url: dir.appendingPathComponent("state.json"))
    }

    /// Missing file -> fresh state, no crash, no cache poisoning.
    func testLoadReturnsFreshStateWhenFileAbsent() {
        let store = makeStore()
        let state = store.load()
        XCTAssertEqual(state.version, 1)
        XCTAssertTrue(state.sessions.isEmpty)
        XCTAssertTrue(state.brightnessSnapshots.isEmpty)
    }

    /// A corrupt state file must degrade to a clean state instead of throwing
    /// or crashing; the daemon must survive a half-written file.
    func testCorruptJSONRecoversToFreshState() throws {
        try Data("{ this is not valid json".utf8).write(to: storeURL())
        let store = makeStore()
        let state = store.load()
        XCTAssertEqual(state.version, 1, "corrupt file must yield a fresh state")
        XCTAssertTrue(state.sessions.isEmpty)
        XCTAssertTrue(state.brightnessSnapshots.isEmpty)
    }

    /// Corrupt recovery must also heal the cache, so a second load stays clean
    /// even after the file is removed.
    func testCorruptThenMissingFileStaysFresh() throws {
        try Data("not json either".utf8).write(to: storeURL())
        let store = makeStore()
        _ = store.load()                       // corrupt -> fresh, cached
        try FileManager.default.removeItem(at: storeURL())
        let again = store.load()               // cache path, no re-read
        XCTAssertEqual(again.version, 1)
        XCTAssertTrue(again.sessions.isEmpty)
    }

    /// mutate -> encode -> write; a fresh store instance must see the data.
    func testMutatePersistsToDisk() {
        let store = makeStore()
        store.mutate { $0.brightnessSnapshots = ["deadbeef-0000": 0.5] }

        let fresh = makeStore()
        let state = fresh.load()
        XCTAssertEqual(state.brightnessSnapshots["deadbeef-0000"], 0.5)
    }

    /// reload() must drop the cache and re-read what another process wrote.
    func testReloadReReadsExternalWrite() throws {
        let store = makeStore()
        store.mutate { $0.sessions = [] }      // establishes the cache
        XCTAssertEqual(store.load().sessions.count, 0)

        // Simulate another process (or `restore`) rewriting the file.
        var external = PersistedState()
        external.brightnessSnapshots = ["external-1111": 0.25]
        let data = try JSONCoding.encoder.encode(external)
        try data.write(to: storeURL())

        // Cache still holds the old view until reload is called.
        XCTAssertTrue(store.load().brightnessSnapshots.isEmpty,
                      "cache must not see the external write before reload")
        store.reload()
        XCTAssertEqual(store.load().brightnessSnapshots["external-1111"], 0.25,
                       "reload must pick up the externally written snapshot")
    }

    /// reload() on a deleted file must fall back to fresh instead of keeping
    /// a stale cache (e.g. after `restore` clears the file).
    func testReloadAfterFileRemovedReturnsFresh() throws {
        let store = makeStore()
        store.mutate { $0.brightnessSnapshots = ["deadbeef-0000": 0.5] }
        XCTAssertEqual(store.load().brightnessSnapshots.count, 1)

        try FileManager.default.removeItem(at: storeURL())
        store.reload()
        XCTAssertTrue(store.load().brightnessSnapshots.isEmpty,
                      "reload on a missing file must not resurrect stale data")
    }

    /// reset() must clear memory and delete the file, so the next process
    /// starts truly clean.
    func testResetWipesMemoryAndDisk() {
        let store = makeStore()
        store.mutate { $0.brightnessSnapshots = ["deadbeef-0000": 0.5] }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL().path))

        store.reset()

        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL().path),
                       "reset must remove the state file from disk")
        let state = store.load()
        XCTAssertTrue(state.brightnessSnapshots.isEmpty,
                      "reset must clear in-memory state too")
    }

    private func storeURL() -> URL {
        dir.appendingPathComponent("state.json")
    }
}
