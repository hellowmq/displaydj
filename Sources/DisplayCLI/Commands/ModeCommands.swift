import Foundation
import Darwin
import VibeDisplayCore

enum ModeCommands {
    static func run(_ args: Arguments) throws {
        let sub = args.positional(1) ?? "list"
        guard ["list", "set", "preview", "guarded-set"].contains(sub) else { throw VibeError(.invalidArgument, "use modes list | set <mode-id> | preview <mode-id> | guarded-set <mode-id>") }
        try args.validateSurface(options: ["display", "d", "selector"], flags: sub == "set" ? ["dry-run"] : [], maxPositionals: sub == "list" ? 2 : 3)
        let selector = args.string("display", "d", "selector") ?? (sub == "list" ? "all" : "")
        if sub == "list" {
            let reports: [DisplayModeReport]
            if let client = DaemonClient() {
                reports = try client.decode(ModesPayload.self, "GET", "/v1/modes?selector=\(selector.urlPathEncoded)").displays
            } else { reports = try DisplayModeService.shared.list(DisplaySelector(selector)) }
            Output.emit(ModesPayload(displays: reports)) {
                Table.render(headers: ["DISPLAY", "ID", "SIZE", "PIXELS", "HZ", "FLAGS"], rows: reports.flatMap { report in
                    report.modes.map { mode in
                        [report.slug, String(mode.id), "\(mode.width)x\(mode.height)", "\(mode.pixelWidth)x\(mode.pixelHeight)",
                         mode.refreshRate == 0 ? "unknown" : String(format: "%.2f", mode.refreshRate),
                         [mode.id == report.current.id ? "current" : "", mode.hiDPI ? "HiDPI" : "", mode.usable ? "" : "unusable"].filter { !$0.isEmpty }.joined(separator: ",")]
                    }
                })
            }
        } else {
            guard !selector.isEmpty, let raw = args.positional(2), let mode = Int32(raw), mode >= 0 else {
                throw VibeError(.invalidArgument, "modes set/preview requires a valid mode ID and explicit --display selector")
            }
            let report: DisplayModeChange
            if sub == "guarded-set" {
                do { try guardedSet(mode, selector: selector) }
                catch {
                    let failure = error as? VibeError ?? VibeError(.backendFailure, "\(error)")
                    let line = JSONCoding.string(VibeResponse<EmptyPayload>(error: failure), pretty: false) + "\n"
                    FileHandle.standardOutput.write(Data(line.utf8))
                    exit(failure.exitCode)
                }
                return
            } else if sub == "preview" {
                // Must run in this process: .forAppOnly reverts when it exits.
                report = try DisplayModeService.shared.preview(mode, selector: DisplaySelector(selector))
                Thread.sleep(forTimeInterval: 10)
            } else if let client = DaemonClient(timeout: 30) {
                report = try client.decode(DisplayModeChange.self, "POST", "/v1/modes",
                    body: ["selector": selector, "modeID": mode, "dryRun": args.has("dry-run")])
            } else { report = try DisplayModeService.shared.set(mode, selector: DisplaySelector(selector), dryRun: args.has("dry-run")) }
            Output.emit(report) { "\(sub == "preview" ? "10-second preview complete; session mode will restore on exit" : (report.dryRun ? "Preview" : "Verified")): \(report.displayUUID) mode \(report.previous.id) → \(report.requested.id)" }
        }
    }

    /// The GUI keeps stdin open while its confirmation alert is visible. This
    /// process owns the session change, so App exit closes stdin and restores.
    /// Only a matching display still in the requested mode is ever restored.
    private static func guardedSet(_ mode: Int32, selector: String) throws {
        guard selector.hasPrefix("uuid:"), UUID(uuidString: String(selector.dropFirst(5))) != nil else {
            throw VibeError(.invalidArgument, "guarded-set requires an explicit UUID selector")
        }
        signal(SIGPIPE, SIG_IGN)
        try Paths.ensureHome()
        let logURL = Paths.logDirectory.appendingPathComponent("mode-guard.jsonl")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw VibeError(.ioFailure, "cannot create mode guard log")
            }
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        _ = try logHandle.seekToEnd()
        Log.redirect(to: logHandle)
        Log.minimumLevel = .info
        Log.info("guarded mode change requested", ["display": selector, "mode": String(mode)])
        let service = DisplayModeService.shared
        let change = try service.set(mode, selector: DisplaySelector(selector))
        guard change.verified else { throw VibeError(.backendFailure, "mode change was not verified") }
        Log.info("guarded mode change verified", ["display": selector,
                                                "previous": String(change.previous.id), "requested": String(change.requested.id)])
        let handshake = JSONCoding.string(VibeResponse(data: change), pretty: false) + "\n"
        let sent = Data(handshake.utf8).withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(STDOUT_FILENO, base.advanced(by: offset), bytes.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        let decision = sent ? waitForDecision(seconds: 15) : .restore
        Log.info("guarded mode decision", ["display": selector, "decision": decision == .keep ? "keep" : "restore"])
        guard decision == .keep else {
            do {
                let reports = try service.list(DisplaySelector(selector))
                guard let current = reports.first,
                      current.displayUUID.caseInsensitiveCompare(change.displayUUID) == .orderedSame,
                      current.current.id == change.requested.id else {
                    // Another actor or topology change took ownership; never overwrite it.
                    Log.warn("guarded mode restore skipped after display or mode changed", ["display": selector])
                    return
                }
                let restored = try service.set(change.previous.id, selector: DisplaySelector(selector))
                guard restored.verified else { throw VibeError(.backendFailure, "guarded mode restoration readback failed") }
                Log.info("guarded mode restoration verified", ["display": selector, "mode": String(change.previous.id)])
            } catch {
                Log.error("guarded mode restoration failed: \(error)", ["display": selector])
                FileHandle.standardError.write(Data("guarded mode restoration failed: \(error)\n".utf8))
                exit(1)
            }
            return
        }
    }

    enum ModeDecision: Equatable { case keep, restore }

    static func waitForDecision(seconds: TimeInterval, inputFD: Int32 = STDIN_FILENO) -> ModeDecision {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var bytes = [UInt8](repeating: 0, count: 32)
        var received = Data()
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: inputFD, events: Int16(POLLIN | POLLHUP), revents: 0)
            let remaining = max(1, Int((deadline - ProcessInfo.processInfo.systemUptime) * 1000))
            let result = Darwin.poll(&descriptor, 1, Int32(remaining))
            if result == 0 { break }
            if result < 0 { if errno == EINTR { continue }; break }
            let count = bytes.withUnsafeMutableBytes { Darwin.read(inputFD, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            received.append(contentsOf: bytes.prefix(count))
            if received.count > 32 { break }
            if let lineEnd = received.firstIndex(of: 10) {
                return received.prefix(upTo: lineEnd) == Data("keep".utf8) ? .keep : .restore
            }
        }
        return .restore
    }
}

struct ModesPayload: Codable { let displays: [DisplayModeReport] }
