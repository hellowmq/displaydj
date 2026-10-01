import XCTest
@testable import VibeDisplayCore

private final class OwnershipBackend: BrightnessBackend {
    let transport: BrightnessTransport
    var values: [String: Double]
    var writes: [(String, Double)] = []
    var fails = false
    var failWhen: ((DisplayInfo, Double) -> Bool)?
    init(_ values: [String: Double], transport: BrightnessTransport = .ddc) {
        self.values = values; self.transport = transport
    }
    func supports(_ display: DisplayInfo) -> Bool { values[display.uuid] != nil }
    func read(_ display: DisplayInfo) -> Double? { values[display.uuid] }
    func write(_ display: DisplayInfo, value: Double) -> Bool {
        writes.append((display.uuid, value))
        if fails || failWhen?(display, value) == true { return false }
        values[display.uuid] = value
        return true
    }
}

final class BrightnessOwnershipTests: XCTestCase {
    private var dir: URL!
    private let first = "AAAAAAAA-1111-2222-3333-444444444444"
    private let second = "BBBBBBBB-1111-2222-3333-444444444444"
    private var panels: [DisplayInfo] = []
    private var backend: OwnershipBackend!
    private var store: StateStore!
    private var brightness: BrightnessService!
    private var manager: AgentSessionManager!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("displaydj-ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        panels = [panel(first, index: 0), panel(second, index: 1)]
        backend = OwnershipBackend([first: 0.6, second: 0.8])
        store = StateStore(url: dir.appendingPathComponent("state.json"))
        brightness = service(store)
        manager = makeManager(brightness, store)
    }

    private func panel(_ uuid: String, index: Int) -> DisplayInfo {
        DisplayInfo(id: UInt32(index + 1), uuid: uuid, slug: "panel\(index)", name: "Panel \(index)",
            isBuiltin: false, isMain: index == 0, vendorID: 1, modelID: 2, serialNumber: UInt32(index),
            index: index, width: 1920, height: 1080)
    }

    private func service(_ store: StateStore, using backend: OwnershipBackend? = nil) -> BrightnessService {
        BrightnessService(registry: DisplayRegistry(loadDisplays: { self.panels }), store: store,
                          backends: [backend ?? self.backend!])
    }

    private func makeManager(_ service: BrightnessService, _ store: StateStore) -> AgentSessionManager {
        let phases: [String: PhaseProfile] = Dictionary(uniqueKeysWithValues: AgentPhase.allCases.map {
            ($0.rawValue, PhaseProfile(brightness: $0.isTerminal ? "restore" : ($0 == .waiting ? "85%" : "30%"),
                                     rampMs: 0, keepAwake: []))
        })
        return AgentSessionManager(brightness: service, keepAwake: KeepAwakeRegistry(), store: store,
            config: VibeConfig(defaultSelector: "all", defaultRampMs: 0, phases: phases))
    }

    func testDirectManualWriteWinsAgainstPhaseEndAndShutdownOnOnlyItsDisplay() throws {
        let started = try manager.begin(label: "job", client: "test")
        XCTAssertEqual(backend.values[first], 0.3)
        let manual = brightness.apply(.absolute(0.5), to: panels[0])
        XCTAssertTrue(manual.ok)
        let phase = try manager.transition(started.session.id, to: .waiting)
        XCTAssertEqual(phase.brightness.first { $0.displayUUID == first }?.skippedReason, "manual_override")
        XCTAssertEqual(backend.values[first], 0.5)
        XCTAssertEqual(backend.values[second], 0.85)
        XCTAssertTrue(phase.warnings.contains { $0.contains("manual_override") })
        let ended = try manager.end(started.session.id)
        XCTAssertEqual(ended.brightness.first { $0.displayUUID == first }?.skippedReason, "manual_override")
        XCTAssertEqual(backend.values[first], 0.5)
        XCTAssertEqual(backend.values[second], 0.8)
        _ = brightness.restoreAutomatic()
        XCTAssertEqual(backend.values[first], 0.5)
        // Explicit undo is still available for the direct CLI-style edit.
        XCTAssertTrue(brightness.restoreAll(ramp: .instant).allSatisfy(\.ok))
        XCTAssertEqual(backend.values[first], 0.3)
    }

    func testAnotherProcessManualClaimInvalidatesCachedDaemonAndSurvivesRestart() throws {
        let started = try manager.begin(label: "job", client: "test")
        _ = store.load() // daemon has a cached old recovery point
        let independent = StateStore(url: dir.appendingPathComponent("state.json"))
        let coordinator = BrightnessCoordinator(store: independent)
        try coordinator.transaction {
            // GUI/legacy stable IDs use lower-case uuid: prefixes.
            try coordinator.takeManualControl(stableID: "uuid:" + first.lowercased())
            backend.values[first] = 0.5
        }
        XCTAssertNil(brightness.snapshotValues()[first])
        let restarted = makeManager(service(StateStore(url: dir.appendingPathComponent("state.json"))),
                                    StateStore(url: dir.appendingPathComponent("state.json")))
        _ = try restarted.end(started.session.id)
        _ = brightness.restoreAutomatic()
        XCTAssertEqual(backend.values[first], 0.5)
        XCTAssertEqual(backend.values[second], 0.8)
    }

    func testHeartbeatTimeoutCannotUndoManualAdjustment() throws {
        let started = try manager.begin(label: "job", client: "test", ttlSeconds: 1)
        XCTAssertTrue(brightness.apply(.absolute(0.51), to: panels[0]).ok)
        XCTAssertEqual(manager.reap(now: Date().addingTimeInterval(5)).count, 1)
        XCTAssertEqual(try manager.session(started.session.id).endedBy, "reaper")
        XCTAssertEqual(backend.values[first], 0.51)
        XCTAssertEqual(backend.values[second], 0.8)
    }

    func testNoManualInterventionRestoresBaselineAndRetiresOwnedSnapshots() throws {
        let started = try manager.begin(label: "job", client: "test")
        let report = try manager.end(started.session.id)
        XCTAssertTrue(report.brightness.allSatisfy { $0.ok && $0.skippedReason == nil })
        XCTAssertEqual(backend.values[first], 0.6)
        XCTAssertEqual(backend.values[second], 0.8)
        XCTAssertTrue(brightness.snapshotValues().isEmpty)
        XCTAssertThrowsError(try manager.transition(started.session.id, to: .running))
    }

    func testLastOverlappingSessionRestoresOriginalBaseline() throws {
        let a = try manager.begin(label: "a", client: "test")
        let b = try manager.begin(label: "b", client: "test")
        let early = try manager.end(a.session.id)
        XCTAssertTrue(early.brightness.allSatisfy { $0.skippedReason == "another_session_active" })
        XCTAssertEqual(backend.values[first], 0.3)
        _ = try manager.end(b.session.id)
        XCTAssertEqual(backend.values[first], 0.6)
        XCTAssertEqual(backend.values[second], 0.8)
    }

    func testNewSessionAfterManualTakeoverRestoresTheNewUserBaseline() throws {
        let old = try manager.begin(label: "old", client: "test")
        XCTAssertTrue(brightness.apply(.absolute(0.5), to: panels[0]).ok)
        let new = try manager.begin(label: "new", client: "test")
        _ = try manager.end(old.session.id)
        XCTAssertEqual(backend.values[first], 0.3)
        _ = try manager.end(new.session.id)
        XCTAssertEqual(backend.values[first], 0.5)
    }

    func testManualNoOpAlsoRevokesOldClaim() throws {
        let started = try manager.begin(label: "job", client: "test")
        XCTAssertTrue(brightness.apply(.absolute(0.3), to: panels[0]).ok)
        _ = try manager.end(started.session.id)
        XCTAssertEqual(backend.values[first], 0.3)
    }

    func testFailedManualAttemptStillPausesOldSessionAndKeepsUndo() throws {
        let started = try manager.begin(label: "job", client: "test")
        backend.fails = true
        XCTAssertFalse(brightness.apply(.absolute(0.5), to: panels[0]).ok)
        backend.fails = false
        _ = try manager.transition(started.session.id, to: .waiting)
        XCTAssertEqual(backend.values[first], 0.3)
        XCTAssertEqual(brightness.snapshotValues()[first], 0.3)
    }

    func testFailedAgentRestoreRetainsRecoveryForRetry() throws {
        let started = try manager.begin(label: "job", client: "test")
        backend.fails = true
        let report = try manager.end(started.session.id)
        XCTAssertFalse(report.brightness.allSatisfy(\.ok))
        XCTAssertEqual(brightness.snapshotValues()[first], 0.6)
        backend.fails = false
        XCTAssertTrue(brightness.restoreAutomatic().allSatisfy(\.ok))
        XCTAssertEqual(backend.values[first], 0.6)
    }

    func testUnpluggedOwnedRecoveryRemainsUntilReconnect() throws {
        let started = try manager.begin(label: "job", client: "test")
        panels = [panels[1]]
        _ = try manager.end(started.session.id)
        XCTAssertEqual(brightness.snapshotValues()[first], 0.6)
        panels.append(panel(first, index: 0))
        _ = brightness.restoreAutomatic()
        XCTAssertEqual(backend.values[first], 0.6)
    }

    func testTransportChangeCannotApplyOrAutoRestoreSnapshot() throws {
        let started = try manager.begin(label: "job", client: "test")
        let changed = OwnershipBackend(backend.values, transport: .displayServices)
        let fresh = service(StateStore(url: dir.appendingPathComponent("state.json")), using: changed)
        let restarted = makeManager(fresh, StateStore(url: dir.appendingPathComponent("state.json")))
        let report = try restarted.end(started.session.id)
        XCTAssertFalse(report.brightness.allSatisfy(\.ok))
        XCTAssertTrue(changed.writes.isEmpty)
        XCTAssertEqual(fresh.snapshotValues()[first], 0.6)
    }

    func testLegacyRecoveryIsExplicitOnlyAndLegacySessionsCannotWrite() throws {
        store.mutate {
            $0.brightnessSnapshots[first] = 0.55
            $0.brightnessSnapshotTransports = [first: .ddc]
            $0.sessions = [AgentSession(id: "old", label: "old", client: "test", phase: .running,
                selector: "all", expiresAt: Date().addingTimeInterval(60))]
        }
        let skipped = try manager.transition("old", to: .waiting)
        XCTAssertTrue(skipped.brightness.allSatisfy { $0.skippedReason == "unclaimed_display" })
        XCTAssertEqual(brightness.restoreAutomatic().first?.skippedReason, "recovery_not_owned")
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertThrowsError(try manager.begin(label: "new", client: "test"))
        XCTAssertTrue(brightness.restoreAll(ramp: .instant).allSatisfy(\.ok))
        XCTAssertEqual(backend.values[first], 0.55)
    }

    func testRunningOlderDaemonRefusesManualAndAgentWritesBeforeTouchingHardware() throws {
        let descriptor = DaemonDescriptor(pid: Int32(getpid()), host: "127.0.0.1", port: 1,
            version: "1.0.0", requiresToken: true)
        try JSONCoding.encoder.encode(descriptor).write(to: dir.appendingPathComponent("daemon.json"))
        let result = brightness.apply(.absolute(0.5), to: panels[0])
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.error?.contains("must be restarted") == true)
        XCTAssertThrowsError(try manager.begin(label: "job", client: "test"))
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertNil(store.load().brightnessRevisions)
    }

    func testCorruptStateCannotAuthorizeWrites() throws {
        let bytes = Data("broken state".utf8)
        try bytes.write(to: dir.appendingPathComponent("state.json"))
        XCTAssertFalse(brightness.apply(.absolute(0.5), to: panels[0]).ok)
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("state.json")), bytes)
    }

    func testDirectManualUndoSurvivesRestartAndShutdownDoesNotApplyIt() throws {
        XCTAssertTrue(brightness.apply(.absolute(0.4), to: panels[0]).snapshotTaken)
        XCTAssertFalse(brightness.apply(.absolute(0.5), to: panels[0]).snapshotTaken)
        let fresh = service(StateStore(url: dir.appendingPathComponent("state.json")))
        XCTAssertEqual(fresh.restoreAutomatic().first?.skippedReason, "recovery_not_owned")
        XCTAssertEqual(backend.values[first], 0.5)
        XCTAssertTrue(fresh.restoreAll(ramp: .instant).allSatisfy(\.ok))
        XCTAssertEqual(backend.values[first], 0.6)
    }

    func testProfileTakesManualControlAndDryRunDoesNot() throws {
        let started = try manager.begin(label: "job", client: "test")
        let profiles = DisplayProfileStore(url: dir.appendingPathComponent("profiles.json"))
        let profileService = DisplayProfileService(brightness: brightness, store: profiles)
        _ = try profileService.save("用户预设", selector: .all)
        let before = try store.readChecked()
        _ = try profileService.apply("用户预设", dryRun: true)
        XCTAssertEqual(try store.readChecked(), before)
        XCTAssertTrue(try profileService.apply("用户预设").ok)
        _ = try manager.end(started.session.id)
        XCTAssertEqual(backend.values[first], 0.3)
        XCTAssertEqual(backend.values[second], 0.3)
    }

    func testAgentClaimsConfiguredPhaseTargetsAndNeverClaimsNewlyConnectedPanel() throws {
        panels = [panels[0]]
        let started = try manager.begin(label: "job", client: "test")
        panels.append(panel(second, index: 1))
        let report = try manager.transition(started.session.id, to: .waiting)
        XCTAssertEqual(report.brightness.first { $0.displayUUID == second }?.skippedReason, "unclaimed_display")
        XCTAssertEqual(backend.values[second], 0.8)
    }

    func testConfiguredPhaseTargetIsClaimedAndDefaultEndRestoresBothTargets() throws {
        let phases: [String: PhaseProfile] = [
            "starting": PhaseProfile(brightness: "30%", rampMs: 0, keepAwake: []),
            "waiting": PhaseProfile(brightness: "40%", selector: "uuid:" + second, rampMs: 0, keepAwake: []),
            "succeeded": PhaseProfile(brightness: "restore", rampMs: 0, keepAwake: [])
        ]
        manager.updateConfig(VibeConfig(defaultSelector: "uuid:" + first, defaultRampMs: 0, phases: phases))
        let started = try manager.begin(label: "job", client: "test")
        _ = try manager.transition(started.session.id, to: .waiting)
        XCTAssertEqual(backend.values[second], 0.4)
        _ = try manager.end(started.session.id)
        XCTAssertEqual(backend.values[first], 0.6)
        XCTAssertEqual(backend.values[second], 0.8)
    }

    func testProfileRollbackKeepsManualPriority() throws {
        let profiles = DisplayProfileStore(url: dir.appendingPathComponent("profiles.json"))
        let profileService = DisplayProfileService(brightness: brightness, store: profiles)
        _ = try profileService.save("work", selector: .all)
        let started = try manager.begin(label: "job", client: "test")
        backend.failWhen = { display, value in display.uuid == self.second && value == 0.8 }
        let failed = try profileService.apply("work")
        XCTAssertFalse(failed.ok)
        XCTAssertTrue(failed.rollback.allSatisfy(\.ok))
        _ = try manager.end(started.session.id)
        XCTAssertEqual(backend.values[first], 0.3)
        XCTAssertEqual(backend.values[second], 0.3)
    }

    func testCancelledQueuedWriteCannotClaimAndReleasesItsFileDescriptor() async throws {
        let held = try await brightness.coordinator.acquire()
        let task = Task { try await self.brightness.coordinator.acquire() }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled operation acquired control") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(try store.readChecked().brightnessRevisions)
        held.release()
        let fresh = try await brightness.coordinator.acquire()
        fresh.release()
    }

    func testBrightnessDisabledAndExcludedPanelsNeverAcquireRecovery() throws {
        let disabled = Dictionary(uniqueKeysWithValues: AgentPhase.allCases.map { ($0.rawValue, PhaseProfile()) })
        manager.updateConfig(VibeConfig(defaultSelector: "external", phases: disabled))
        let idle = try manager.begin(label: "no brightness", client: "test")
        XCTAssertEqual(idle.session.brightnessRevisions, [:])
        XCTAssertTrue(brightness.snapshotValues().isEmpty)
        _ = try manager.end(idle.session.id)
        XCTAssertTrue(backend.writes.isEmpty)
        var cfg = manager.currentConfig()
        cfg.phases = VibeConfig.defaultPhases
        cfg.defaultSelector = "all"
        cfg.displays = ["panel0": DisplayOverride(exclude: true), "panel1": DisplayOverride(exclude: true)]
        manager.updateConfig(cfg)
        let excluded = try manager.begin(label: "excluded", client: "test")
        XCTAssertEqual(excluded.session.brightnessRevisions, [:])
        XCTAssertTrue(brightness.snapshotValues().isEmpty)
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testAnotherProcessHoldingLockPreventsManualClaimUntilReleased() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); print('locked',flush=True); sys.stdin.readline()", store.brightnessLockURL.path]
        let output = Pipe(), input = Pipe()
        child.standardOutput = output
        child.standardInput = input
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        // The child signals only after flock succeeds, without timing guesses.
        let ready = output.fileHandleForReading.availableData
        XCTAssertEqual(String(data: ready, encoding: .utf8), "locked\n")
        let started = expectation(description: "queued operation started")
        let acquired = expectation(description: "acquired after release")
        let task = Task {
            started.fulfill()
            let token = try await brightness.coordinator.acquire()
            defer { token.release() }
            acquired.fulfill()
        }
        await fulfillment(of: [started], timeout: 1)
        // Lock contention must not write a manual revision before acquisition.
        XCTAssertNil(try store.readChecked().brightnessRevisions)
        try input.fileHandleForWriting.write(contentsOf: Data("release\n".utf8))
        await fulfillment(of: [acquired], timeout: 2)
        try await task.value
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
    }
}
