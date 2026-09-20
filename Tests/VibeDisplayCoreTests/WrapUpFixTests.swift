import XCTest
@testable import VibeDisplayCore

/// Locks in the wrap-up fixes: session `note`, the `previous`/`snapshotTaken`
/// result fields, `heartbeat` on an ended session being `session_not_found`
/// (404/exit 3), and cross-process restore seeding from disk.
final class WrapUpFixTests: XCTestCase {

    // MARK: - Session note

    func testSessionNoteDefaultsToNil() {
        let session = AgentSession(id: "s", label: "t", client: "test",
                                   phase: .starting, selector: "all",
                                   expiresAt: Date().addingTimeInterval(60))
        XCTAssertNil(session.note, "a session without a note must report nil")
    }

    func testSessionNoteSurvivesCodableRoundTrip() throws {
        var session = AgentSession(id: "s", label: "t", client: "test",
                                   phase: .starting, selector: "all",
                                   expiresAt: Date().addingTimeInterval(60))
        session.note = "needs a human"
        let data = try JSONCoding.encoder.encode(session)
        let decoded = try JSONCoding.decoder.decode(AgentSession.self, from: data)
        XCTAssertEqual(decoded.note, "needs a human")
    }

    /// State files written before `note` existed must keep decoding.
    func testSessionDecodesOldPayloadWithoutNote() throws {
        let old = """
        {"id":"s","label":"t","client":"c","phase":"running","selector":"all",
         "createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z",
         "expiresAt":"2026-08-01T01:00:00Z","heartbeatCount":0,"keepAwakeLeaseIDs":[],
         "snapshot":{},"transitions":[],"metadata":{}}
        """
        let decoded = try JSONCoding.decoder.decode(AgentSession.self, from: Data(old.utf8))
        XCTAssertNil(decoded.note)
    }

    // MARK: - BrightnessApplyResult new fields

    func testApplyResultDecodesOldPayloadWithDefaults() throws {
        let old = """
        {"displayUUID":"u","slug":"s","requested":0.5,"applied":0.5,
         "transport":"gamma","ok":true}
        """
        let decoded = try JSONCoding.decoder.decode(BrightnessApplyResult.self, from: Data(old.utf8))
        XCTAssertNil(decoded.previous)
        XCTAssertFalse(decoded.snapshotTaken)
    }

    func testApplyResultRoundTripsNewFields() throws {
        let result = BrightnessApplyResult(displayUUID: "u", slug: "s",
                                           previous: 0.62, requested: 0.45, applied: 0.45,
                                           transport: .displayServices, ok: true,
                                           snapshotTaken: true)
        let data = try JSONCoding.encoder.encode(result)
        let decoded = try JSONCoding.decoder.decode(BrightnessApplyResult.self, from: data)
        XCTAssertEqual(decoded.previous, 0.62)
        XCTAssertTrue(decoded.snapshotTaken)
    }

    // MARK: - Agent lifecycle semantics

    func testHeartbeatOnEndedSessionIsNotFound() {
        let (manager, store) = makeManager()
        let now = Date()
        let ended = AgentSession(id: "ended-session", label: "t", client: "test",
                                 phase: .succeeded, selector: "all",
                                 createdAt: now, updatedAt: now,
                                 expiresAt: now.addingTimeInterval(-10))
        store.mutate { $0.sessions.append(ended) }

        XCTAssertThrowsError(try manager.heartbeat("ended-session")) { error in
            let err = error as? VibeError
            XCTAssertEqual(err?.code, .sessionNotFound,
                           "heartbeat on an ended session must be session_not_found (exit 3), not a conflict")
        }
    }

    func testPhaseNoteIsRecordedOnSession() throws {
        let (manager, store) = makeManager()
        let now = Date()
        let active = AgentSession(id: "note-session", label: "t", client: "test",
                                  phase: .starting, selector: "all",
                                  createdAt: now, updatedAt: now,
                                  expiresAt: now.addingTimeInterval(600))
        store.mutate { $0.sessions.append(active) }

        let report = try manager.transition("note-session", to: .waiting, note: "needs a human")
        XCTAssertEqual(report.session.note, "needs a human")
        XCTAssertEqual(try manager.session("note-session").note, "needs a human",
                       "the note must be visible to later readers, not just the transition reply")
    }

    // MARK: - Cross-process restore

    /// A fresh `BrightnessService` has no in-memory record; `restoreAll` must
    /// recover persisted snapshots and keep those it cannot restore.
    func testRestoreAllSeedsFromDiskAndRetainsUnpluggedDisplay() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        store.mutate { $0.brightnessSnapshots = ["deadbeef-0000": 0.5] }

        let service = BrightnessService(store: store)
        // No display in this (test) registry matches the persisted uuid, but
        // the recovery point must remain available after reconnect.
        let results = service.restoreAll()

        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(service.snapshotValues()["deadbeef-0000"], 0.5)
        XCTAssertEqual(store.load().brightnessSnapshots["deadbeef-0000"], 0.5)
    }

    // MARK: - Helpers

    /// A manager whose phase profiles never touch brightness or keep-awake, so
    /// unit tests cannot move the developer's real screen.
    private func makeManager() -> (AgentSessionManager, StateStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let safePhases: [String: PhaseProfile] = Dictionary(
            uniqueKeysWithValues: AgentPhase.allCases.map { ($0.rawValue, PhaseProfile()) })
        let manager = AgentSessionManager(brightness: BrightnessService(store: store),
                                          keepAwake: KeepAwakeRegistry(),
                                          store: store,
                                          config: VibeConfig(phases: safePhases))
        return (manager, store)
    }
}
