import Foundation
import VibeDisplayCore

/// The resident process.
///
/// Three responsibilities, in priority order:
///
/// 1. **Hold state that cannot survive process exit** — gamma tables and
///    `IOPMAssertion`s both die with their owner, so anything using them needs
///    a daemon. This is the reason `serve` exists at all.
/// 2. **Serve the loopback HTTP API** for agents that prefer a socket to a
///    subprocess.
/// 3. **Run the reaper** so a crashed agent's session expires and the user's
///    brightness comes back on its own.
///
/// Shutdown is the interesting part: on SIGINT/SIGTERM the daemon restores
/// every display and drops every assertion *before* exiting. `kill -9` skips
/// that, which is why snapshots are also persisted to disk — see
/// `display-cli restore`.
public final class DaemonService {
    private let config: VibeConfig
    private let brightness: BrightnessService
    private let keepAwake: KeepAwakeRegistry
    private let sessions: AgentSessionManager
    private let startedAt = Date()

    private var server: HTTPServer?
    private var reaper: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private let shutdownOnce = NSLock()
    private var didShutdown = false

    public init(config: VibeConfig,
                brightness: BrightnessService = .shared,
                keepAwake: KeepAwakeRegistry = .shared,
                sessions: AgentSessionManager = .shared) {
        self.config = config
        self.brightness = brightness
        self.keepAwake = keepAwake
        self.sessions = sessions
    }

    /// Blocks forever. Returns only on a clean shutdown signal.
    public func run(foreground: Bool) throws {
        if let existing = DaemonDescriptor.loadIfAlive() {
            throw VibeError(.daemonAlreadyRunning,
                            "daemon already running on \(existing.baseURL) (pid \(existing.pid))",
                            hint: "stop it with `display-cli daemon stop`")
        }
        try Paths.ensureHome()

        let token: String? = config.daemon.requireToken ? try TokenStore.loadOrCreate() : nil
        // Enumeration-order overrides cannot safely identify a physical display.
        guard !config.displays.values.contains(where: { $0.ddcServiceIndex != nil }) else {
            throw VibeError(.configInvalid, "ddcServiceIndex is no longer supported",
                            hint: "remove slot overrides; the shared engine matches display identity")
        }

        let router = APIRouter.make(brightness: brightness,
                                    keepAwake: keepAwake,
                                    sessions: sessions,
                                    startedAt: startedAt)

        let server = HTTPServer(host: config.daemon.host,
                                port: config.daemon.port,
                                token: token) { request in
            router.handle(request)
        }
        try server.start()
        self.server = server

        let descriptor = DaemonDescriptor(pid: ProcessInfo.processInfo.processIdentifier,
                                          host: config.daemon.host,
                                          port: server.boundPort,
                                          version: VibeVersion.current,
                                          startedAt: startedAt,
                                          requiresToken: token != nil)
        try descriptor.write()

        installSignalHandlers()
        startReaper()

        Log.info("display-cli daemon listening",
                 ["url": descriptor.baseURL,
                  "token": token == nil ? "disabled" : "required",
                  "pid": "\(descriptor.pid)"])
        if foreground {
            Log.info("press Ctrl-C to stop and restore all displays")
        }

        dispatchMain()
    }

    // MARK: - Reaper

    private func startReaper() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.displaydj.reaper", qos: .utility))
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let reaped = self.sessions.reap()
            if !reaped.isEmpty {
                Log.warn("reaper ended \(reaped.count) stale session(s)")
            }
            self.keepAwake.runMaintenance()
        }
        timer.resume()
        reaper = timer
    }

    // MARK: - Shutdown

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            // Ignore the default disposition so the dispatch source can see it.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.global(qos: .utility))
            source.setEventHandler { [weak self] in
                Log.info("signal \(sig) received; shutting down")
                self?.shutdown(exitCode: 0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    public func shutdown(exitCode: Int32) {
        shutdownOnce.lock()
        if didShutdown {
            shutdownOnce.unlock()
            return
        }
        didShutdown = true
        shutdownOnce.unlock()

        reaper?.cancel()
        server?.stop()

        // Order matters: end sessions (which restores per-session brightness),
        // then force-restore anything left, then drop assertions.
        _ = sessions.endAll(outcome: .idle, endedBy: "daemon-shutdown")
        _ = brightness.restoreAll(ramp: .instant)
        keepAwake.releaseEverything()
        DaemonDescriptor.remove()

        Log.info("daemon stopped; displays restored")
        exit(exitCode)
    }

}
