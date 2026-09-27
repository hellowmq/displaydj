import AppKit
import Darwin
import OSLog
import SwiftUI
import VibeDisplayCore

private let softwareDimmingLogger = Logger(
    subsystem: "io.github.hellowmq.displaydj", category: "SoftwareDimming"
)

/// The GUI uses the bundled primary CLI, so daemon routing, validation and
/// failure handling stay identical to scripts. Each call is a separate process.
private enum DisplayToolsClient {
    static func request<T: Decodable & Sendable>(_ type: T.Type, _ arguments: [String]) async throws -> T {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/display-cli")
        let bytes = try await Task.detached {
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw VibeError(.ioFailure, "请通过 scripts/build-app.sh 生成并打开 App")
            }
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments + ["--json"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: deadline)
            defer { deadline.cancel() }
            // Drain before waiting: a large mode list can fill a pipe.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard !data.isEmpty else { throw VibeError(.backendFailure, "CLI 未返回结果或已超时，请检查 display-cli doctor") }
            return data
        }.value
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(VibeDecodedResponse<T>.self, from: bytes)
        guard response.ok, let data = response.data else {
            throw response.error ?? VibeError(.backendFailure, "CLI 未返回有效结果")
        }
        return data
    }
}

/// Owns a separate CLI process. Its stdin is the confirmation lease: closing
/// the window, quitting, or crashing the App closes the pipe and triggers the
/// child's guarded restoration without relying on a SwiftUI timer.
private final class ModeGuardSession: @unchecked Sendable {
    let process: Process
    private let input: Pipe

    init(process: Process, input: Pipe) {
        self.process = process; self.input = input
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func decide(_ command: String) {
        let bytes = Data((command + "\n").utf8)
        if process.isRunning {
            _ = bytes.withUnsafeBytes { buffer in
                Darwin.write(input.fileHandleForWriting.fileDescriptor, buffer.baseAddress, buffer.count)
            }
        }
        try? input.fileHandleForWriting.close()
    }
}

private enum ModeGuardClient {
    static func start(modeID: Int32, selector: String) async throws -> (DisplayModeChange, ModeGuardSession) {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/display-cli")
        return try await Task.detached {
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw VibeError(.ioFailure, "找不到内置 display-cli")
            }
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = ["modes", "guarded-set", String(modeID), "--display", selector, "--json"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            // Read one compact JSON handshake line. If decoding fails, close
            // stdin so a successful but unobserved change restores itself.
            do {
                var data = Data()
                let deadline = ProcessInfo.processInfo.systemUptime + 30
                while data.count < 16_384 {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else {
                        throw VibeError(.backendFailure, "显示模式切换未在 30 秒内返回；守护进程将尝试恢复")
                    }
                    var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor,
                                            events: Int16(POLLIN | POLLHUP), revents: 0)
                    let polled = Darwin.poll(&descriptor, 1, Int32(max(1, remaining * 1000)))
                    if polled < 0 && errno == EINTR { continue }
                    guard polled > 0 else {
                        throw VibeError(.backendFailure, "显示模式切换未返回；守护进程将尝试恢复")
                    }
                    guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else { break }
                    if byte == Data([10]) { break }
                    data.append(byte)
                }
                let response = try JSONDecoder().decode(VibeDecodedResponse<DisplayModeChange>.self, from: data)
                guard response.ok, let change = response.data, change.verified else {
                    throw response.error ?? VibeError(.backendFailure, "模式切换没有通过回读确认")
                }
                return (change, ModeGuardSession(process: process, input: input))
            } catch {
                try? input.fileHandleForWriting.close()
                try? output.fileHandleForReading.close()
                throw error
            }
        }.value
    }
}

struct DisplayToolsView: View {
    @ObservedObject var controller: DisplayBarController
    private struct PendingModeConfirmation: Identifiable {
        let id = UUID()
        let displayUUID: String
        let previousID: Int32
        let requestedID: Int32
    }

    @State private var displays: [DisplayModeReport] = []
    @State private var selectedDisplay = ""
    @State private var selectedMode: Int32 = -1
    @State private var profiles: [DisplayProfile] = []
    @State private var profileName = ""
    @State private var controls: [MonitorControlResult] = []
    @State private var softwareDimmingLevels = SoftwareDimmingLevels()
    @State private var confirmedSoftwareDimmingLevels = SoftwareDimmingLevels()
    @State private var softwareDimmingReadError = ""
    @State private var softwareDimmingNeedsService = false
    @State private var softwareDimmingHasIncompatibleService = false
    @State private var busy = false
    @State private var notice = ""
    @State private var failed = false
    @State private var pendingMode: PendingModeConfirmation?
    @State private var modeGuardSession: ModeGuardSession?
    @State private var modeAlertTimeoutTask: Task<Void, Never>?

    private var display: DisplayModeReport? { displays.first { $0.displayUUID == selectedDisplay } }
    private var selector: String { "uuid:\(selectedDisplay)" }
    private var softwareDimmingValue: Double? { softwareDimmingLevels.value(for: selectedDisplay) }
    private var softwareDimmingBinding: Binding<Double> {
        Binding(
            get: { softwareDimmingLevels.value(for: selectedDisplay) ?? 100 },
            set: { softwareDimmingLevels.set($0, for: selectedDisplay) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("显示设置与预设").font(.title2.weight(.semibold))
                    Text("调整显示模式、画面与亮度预设").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if busy || controller.isPreparingBrightnessSync { ProgressView().controlSize(.small) }
                Button("刷新") { perform { try await reload() } }.disabled(busy)
            }
            TabView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Picker("显示器", selection: $selectedDisplay) {
                            ForEach(displays, id: \.displayUUID) { report in Text(report.slug).tag(report.displayUUID) }
                        }.onChange(of: selectedDisplay) { _ in
                            if let target = controller.displays.first(where: {
                                $0.stableID?.lowercased() == "uuid:\(selectedDisplay.lowercased())"
                            }) {
                                controller.selectDisplay(key: target.selectionKey)
                            }
                            selectedMode = display?.current.id ?? -1
                            controls = []
                            notice = ""
                            softwareDimmingReadError = ""
                            softwareDimmingNeedsService = false
                            softwareDimmingHasIncompatibleService = false
                            let displayUUID = selectedDisplay
                            guard !displayUUID.isEmpty else { return }
                            softwareDimmingLevels.invalidate(displayUUID)
                            confirmedSoftwareDimmingLevels.invalidate(displayUUID)
                            perform { await refreshSoftwareDimming(for: displayUUID) }
                        }
                        if displays.count > 1 {
                            ToolsSection("多显示器亮度") {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("此处选中的显示器也是快捷键「选中的显示器」目标。")
                                        .font(.callout).foregroundStyle(.secondary)
                                    Toggle("同步调节硬件亮度", isOn: Binding(
                                        get: { controller.isBrightnessSyncEnabled },
                                        set: { enabled in Task { await controller.setBrightnessSyncEnabled(enabled) } }
                                    ))
                                    .disabled(controller.isPreparingBrightnessSync || controller.isWriting)
                                    Text("需要每屏都能读取硬件亮度。启用后，调整任一屏会让其他屏按相同百分点变化；软件调光仍按屏幕单独设置。")
                                        .font(.callout).foregroundStyle(.secondary)
                                    if let failure = controller.failures.topology {
                                        Text("\(failure.summary)：\(failure.suggestion)")
                                            .font(.callout).foregroundStyle(.red)
                                            .textSelection(.enabled)
                                        if let title = controller.recoveryActionTitle(for: failure) {
                                            Button(title) { Task { await controller.recover(from: failure) } }
                                        }
                                    }
                                    ForEach(controller.displays, id: \.selectionKey) { panel in
                                        if let id = panel.stableID, let failure = controller.failure(for: id) {
                                            Text("\(panel.name)：\(failure.summary)。\(failure.suggestion)")
                                                .font(.callout).foregroundStyle(.red)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }
                        ToolsSection("亮度快捷键") {
                            HotkeySettingsRow(controller: controller, compact: false)
                        }
                        if let display {
                            ToolsSection("分辨率与刷新率") {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("当前：\(modeLabel(display.current))")
                                    Picker("切换至", selection: $selectedMode) {
                                        ForEach(display.modes.filter(\.usable)) { mode in Text(modeLabel(mode)).tag(mode.id) }
                                    }
                                    HStack {
                                        Text("应用后需在 15 秒内确认，否则恢复原模式").font(.callout).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("应用并确认") { perform {
                                            let (result, session) = try await ModeGuardClient.start(modeID: selectedMode, selector: selector)
                                            let pending = PendingModeConfirmation(
                                                displayUUID: result.displayUUID,
                                                previousID: result.previous.id,
                                                requestedID: result.requested.id)
                                            modeGuardSession = session
                                            pendingMode = pending
                                            scheduleModeAlertTimeout(for: pending)
                                            notice = "新模式已应用；15 秒内确认，否则自动恢复"
                                        } }.disabled(selectedMode < 0 || selectedMode == display.current.id || !display.modes.contains(where: { $0.id == selectedMode && $0.usable }))
                                    }
                                }
                            }
                            ToolsSection("显示器音量与对比度") {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text("通过 DDC 分别检测控制项；有些显示器支持亮度、对比度，但不提供音量调节。")
                                            .font(.callout).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("读取控制项") { perform { try await loadControls() } }
                                    }
                                    ForEach(controls, id: \.control) { result in
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(result.control == .volume ? "音量" : "对比度")
                                                Spacer()
                                                Text(result.value.map { "\(Int(($0 * 100).rounded()))%" } ?? "不可读取")
                                                Button("−5%") { adjust(result.control, "-5%") }.disabled(!result.ok)
                                                Button("+5%") { adjust(result.control, "+5%") }.disabled(!result.ok)
                                            }
                                            if let error = result.error { Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                                        }
                                    }
                                }
                            }
                            ToolsSection("软件调光 · Gamma") {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("只改变画面颜色，不改变背光。打开窗口或切换显示器时自动读取；松开滑块即应用。不需要辅助功能权限。")
                                        .font(.callout).foregroundStyle(.secondary)
                                    if softwareDimmingNeedsService && !softwareDimmingHasIncompatibleService {
                                        Button("启用软件调光") { perform {
                                            let status = try await DisplayToolsClient.request(ToolsDaemonStartPayload.self,
                                                ["serve", "--detach"])
                                            guard status.running else {
                                                throw VibeError(.daemonUnavailable, "本地调光服务没有启动")
                                            }
                                            try await loadSoftwareDimming(for: selectedDisplay)
                                            notice = "软件调光已就绪，可单独设置每台显示器"
                                        } }
                                    }
                                    HStack {
                                        Slider(value: softwareDimmingBinding, in: 8...100, step: 1,
                                               onEditingChanged: { editing in
                                            if !editing { applySoftwareDimmingFromSlider() }
                                        })
                                            .accessibilityLabel("软件调光强度")
                                            .disabled(softwareDimmingValue == nil)
                                        Text(softwareDimmingValue.map { "\(Int($0.rounded()))%" } ?? "未读取")
                                            .monospacedDigit().frame(minWidth: 52)
                                    }
                                    if !softwareDimmingReadError.isEmpty {
                                        Text(softwareDimmingReadError)
                                            .font(.callout).foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    HStack {
                                        Button("关闭并恢复颜色") { perform {
                                            let targetUUID = selectedDisplay
                                            let response = try await DisplayToolsClient.request(ToolsApplyPayload.self,
                                                ["dimming", "off", "--display", "uuid:\(targetUUID)"])
                                            try Self.checkResults(response.results, expectedUUID: targetUUID)
                                            softwareDimmingLevels.set(100, for: targetUUID)
                                            confirmedSoftwareDimmingLevels.set(100, for: targetUUID)
                                            softwareDimmingLogger.info("software dimming restored displayIndex=\(displays.firstIndex(where: { $0.displayUUID == targetUUID }) ?? -1)")
                                            notice = "已恢复系统颜色"
                                        } }
                                    }
                                }
                            }
                        } else { Text("没有可用显示模式，请刷新或运行 display-cli doctor。").foregroundStyle(.secondary) }
                    }.padding(16)
                }.tabItem { Label("显示设置", systemImage: "display") }

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("保存所有在线显示器的亮度和控制方式；应用前先检查目标是否在线。").font(.callout).foregroundStyle(.secondary)
                        HStack {
                            TextField("预设名称（中文、英文、数字、- 或 _）", text: $profileName)
                            Button("保存当前亮度") { perform {
                                _ = try await DisplayToolsClient.request(DisplayProfile.self, ["profile", "save", profileName])
                                try await reload()
                                notice = "已保存亮度预设 \(profileName)"
                            } }.disabled(profileName.isEmpty)
                        }
                        if profiles.isEmpty { Text("还没有亮度预设").foregroundStyle(.secondary).padding(.vertical, 16) }
                        ForEach(profiles, id: \.name) { profile in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(profile.name).font(.headline)
                                        Spacer()
                                        Button("预演") { applyProfile(profile.name, dryRun: true) }
                                        Button("应用") { applyProfile(profile.name, dryRun: false) }
                                    }
                                    ForEach(profile.displays, id: \.displayUUID) { entry in
                                        Text("\(entry.name) · \(Int((entry.brightness * 100).rounded()))% · \(entry.transport == .gamma ? "软件调光" : "硬件亮度")")
                                            .font(.callout).foregroundStyle(.secondary)
                                    }
                                }.padding(8)
                            }
                        }
                    }.padding(16)
                }.tabItem { Label("亮度预设", systemImage: "slider.horizontal.3") }
            }.disabled(busy)
            Divider()
            ScrollView(.vertical) {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(failed ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 36)
            .accessibilityLabel("操作状态")
        }.padding(24).frame(minWidth: 660, minHeight: 520)
        .task { perform { try await reload() } }
        .onChange(of: controller.selectedStableID) { stableID in
            guard let stableID, let match = displays.first(where: {
                "uuid:\($0.displayUUID)".caseInsensitiveCompare(stableID) == .orderedSame
            }), selectedDisplay != match.displayUUID else { return }
            selectedDisplay = match.displayUUID
        }
        .alert("保留这个显示模式？", isPresented: Binding(
            get: { pendingMode != nil },
            set: { if !$0, pendingMode != nil { restorePendingMode() } }
        )) {
            Button("保留模式") { keepPendingMode() }
            Button("恢复原模式", role: .cancel) { restorePendingMode() }
        } message: {
            Text("请在 15 秒内确认。超时、关闭窗口或 App 退出时，独立守护进程会尝试恢复原来的分辨率。")
        }
        .onDisappear { if pendingMode != nil { restorePendingMode() } }
    }

    private func scheduleModeAlertTimeout(for pending: PendingModeConfirmation) {
        modeAlertTimeoutTask?.cancel()
        modeAlertTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, pendingMode?.id == pending.id else { return }
            restorePendingMode()
        }
    }

    private func keepPendingMode() {
        guard let pending = pendingMode, let session = modeGuardSession else { return }
        modeAlertTimeoutTask?.cancel()
        modeAlertTimeoutTask = nil
        session.decide("keep")
        modeGuardSession = nil
        pendingMode = nil
        notice = "正在确认显示模式…"
        perform {
            let status = await Task.detached { session.process.waitUntilExit(); return session.process.terminationStatus }.value
            let reports = try await DisplayToolsClient.request(ToolsModesPayload.self,
                ["modes", "list", "--display", "uuid:\(pending.displayUUID)"]).displays
            guard status == 0, reports.first?.current.id == pending.requestedID else {
                throw VibeError(.backendFailure, "模式未保留；请检查当前分辨率")
            }
            try await reload()
            notice = "已保留显示模式"
        }
    }

    private func restorePendingMode() {
        guard let pending = pendingMode, let session = modeGuardSession else { return }
        modeAlertTimeoutTask?.cancel()
        modeAlertTimeoutTask = nil
        session.decide("restore")
        modeGuardSession = nil
        pendingMode = nil
        perform {
            let status = await Task.detached { session.process.waitUntilExit(); return session.process.terminationStatus }.value
            guard status == 0 else { throw VibeError(.backendFailure, "自动恢复失败；请检查当前分辨率") }
            let reports = try await DisplayToolsClient.request(ToolsModesPayload.self,
                ["modes", "list", "--display", "uuid:\(pending.displayUUID)"]).displays
            guard reports.first?.current.id == pending.previousID else {
                throw VibeError(.backendFailure, "原模式未能回读确认；当前模式可能已被其他操作改变")
            }
            try await reload()
            notice = "已恢复原显示模式"
        }
    }

    private func modeLabel(_ mode: DisplayModeInfo) -> String {
        "\(mode.width) × \(mode.height) · \(mode.refreshRate == 0 ? "刷新率未知" : String(format: "%.2f Hz", mode.refreshRate))\(mode.hiDPI ? " · HiDPI" : "")"
    }

    @MainActor private func reload() async throws {
        let modes = try await DisplayToolsClient.request(ToolsModesPayload.self, ["modes", "list"])
        displays = modes.displays
        if !displays.contains(where: { $0.displayUUID == selectedDisplay }) {
            let selected = controller.selectedStableID?.replacingOccurrences(of: "uuid:", with: "")
            selectedDisplay = displays.first(where: { $0.displayUUID.lowercased() == selected?.lowercased() })?.displayUUID
                ?? displays.first?.displayUUID ?? ""
        }
        selectedMode = display?.current.id ?? -1
        profiles = try await DisplayToolsClient.request(ToolsProfilesPayload.self, ["profile", "list"]).profiles
        if !selectedDisplay.isEmpty {
            softwareDimmingLevels.invalidate(selectedDisplay)
            confirmedSoftwareDimmingLevels.invalidate(selectedDisplay)
            await refreshSoftwareDimming(for: selectedDisplay)
        }
    }

    @MainActor private func loadControls() async throws {
        var readings: [MonitorControlResult] = []
        for control in MonitorControl.allCases {
            readings += try await DisplayToolsClient.request(ToolsControlsPayload.self,
                [control.rawValue, "get", "--display", selector]).results
        }
        controls = readings
    }

    @MainActor private func loadSoftwareDimming(for displayUUID: String) async throws {
        let response = try await DisplayToolsClient.request(ToolsReadingsPayload.self,
            ["dimming", "get", "--display", "uuid:\(displayUUID)"])
        guard let reading = response.readings.first(where: { $0.displayUUID == displayUUID }) else {
            throw VibeError(.backendFailure, "这台显示器的软件调光状态未能回读确认")
        }
        softwareDimmingLevels.set(reading.value * 100, for: displayUUID)
        confirmedSoftwareDimmingLevels.set(reading.value * 100, for: displayUUID)
        if selectedDisplay == displayUUID {
            softwareDimmingReadError = ""
            softwareDimmingNeedsService = false
            softwareDimmingHasIncompatibleService = false
        }
    }

    @MainActor private func refreshSoftwareDimming(for displayUUID: String) async {
        softwareDimmingReadError = ""
        softwareDimmingNeedsService = false
        softwareDimmingHasIncompatibleService = false
        do { try await loadSoftwareDimming(for: displayUUID) }
        catch {
            guard selectedDisplay == displayUUID else { return }
            if let status = try? await DisplayToolsClient.request(ToolsDaemonStatusPayload.self,
                ["daemon", "status"]), let version = status.descriptor?.version,
                version != VibeVersion.current {
                softwareDimmingHasIncompatibleService = true
                softwareDimmingReadError = "运行中的服务版本是 \(version)，当前 App 是 \(VibeVersion.current)。请先确认没有未保存的临时显示状态，再运行 display-cli daemon restart。"
            } else {
                softwareDimmingNeedsService = (error as? VibeError)?.code == .daemonUnavailable
                softwareDimmingReadError = String(describing: error)
            }
        }
    }

    private static func checkResults(_ results: [BrightnessApplyResult], expectedUUID: String) throws {
        guard results.count == 1, results[0].displayUUID == expectedUUID else {
            throw VibeError(.backendFailure, "软件调光未返回目标显示器的确认结果")
        }
        if let error = results.first(where: { !$0.ok })?.error {
            throw VibeError(.backendFailure, error)
        }
        guard results[0].ok else {
            throw VibeError(.backendFailure, "软件调光未能回读确认")
        }
    }

    private func applySoftwareDimmingFromSlider() {
        guard let level = softwareDimmingValue, !selectedDisplay.isEmpty else { return }
        let targetUUID = selectedDisplay
        let target = Int(level.rounded())
        guard target != confirmedSoftwareDimmingLevels.value(for: targetUUID).map({ Int($0.rounded()) }) else { return }
        perform {
            do {
                let response = try await DisplayToolsClient.request(ToolsApplyPayload.self,
                    ["dimming", "set", "\(target)%", "--display", "uuid:\(targetUUID)"])
                try Self.checkResults(response.results, expectedUUID: targetUUID)
                try await loadSoftwareDimming(for: targetUUID)
                softwareDimmingLogger.info("software dimming verified displayIndex=\(displays.firstIndex(where: { $0.displayUUID == targetUUID }) ?? -1) requested=\(target)")
                notice = "软件调光已应用；背光亮度未改变"
            } catch {
                // The slider displayed an unconfirmed draft while it was being dragged.
                // Re-read the service instead of leaving that draft looking applied.
                softwareDimmingLevels.invalidate(targetUUID)
                confirmedSoftwareDimmingLevels.invalidate(targetUUID)
                await refreshSoftwareDimming(for: targetUUID)
                let code = (error as? VibeError)?.code.rawValue ?? "unknown"
                softwareDimmingLogger.error("software dimming failed displayIndex=\(displays.firstIndex(where: { $0.displayUUID == targetUUID }) ?? -1) code=\(code, privacy: .public)")
                throw error
            }
        }
    }

    private func adjust(_ control: MonitorControl, _ value: String) {
        perform {
            let response = try await DisplayToolsClient.request(ToolsControlsPayload.self,
                [control.rawValue, "set", value, "--display", selector])
            if let error = response.results.first(where: { !$0.ok })?.error { throw VibeError(.backendFailure, error) }
            try await loadControls()
            notice = "设置已回读确认"
        }
    }

    private func applyProfile(_ name: String, dryRun: Bool) {
        perform {
            let result = try await DisplayToolsClient.request(ProfileApplyReport.self,
                ["profile", "apply", name] + (dryRun ? ["--dry-run"] : []))
            guard result.ok else {
                let errors = (result.results + result.rollback).compactMap(\.error).joined(separator: "; ")
                throw VibeError(.backendFailure, "预设应用失败；已尝试恢复：\(errors)")
            }
            notice = dryRun ? result.plan.map { "\($0.name)：\(Int(($0.previous * 100).rounded()))% → \(Int(($0.requested * 100).rounded()))%" }.joined(separator: "\n") : "已应用 \(name)"
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; failed = false; notice = ""
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() }
            catch { failed = true; notice = String(describing: error) }
        }
    }
}

private struct ToolsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } label: {
            Text(title).font(.headline)
        }
    }
}

private struct ToolsModesPayload: Decodable, Sendable { let displays: [DisplayModeReport] }
private struct ToolsProfilesPayload: Decodable, Sendable { let profiles: [DisplayProfile] }
private struct ToolsControlsPayload: Decodable, Sendable { let results: [MonitorControlResult] }
private struct ToolsReadingsPayload: Decodable, Sendable { let readings: [BrightnessReading] }
private struct ToolsApplyPayload: Decodable, Sendable { let results: [BrightnessApplyResult] }
private struct ToolsDaemonStartPayload: Decodable, Sendable { let running: Bool }
private struct ToolsDaemonStatusPayload: Decodable, Sendable {
    struct Descriptor: Decodable, Sendable { let version: String }
    let descriptor: Descriptor?
}

extension DisplayBarController {
    func showDisplayTools() {
        popover?.performClose(nil)
        if toolsWindow == nil {
            let hostingController = NSHostingController(rootView: DisplayToolsView(controller: self))
            // A changing slider readout must not update the window's own content size.
            hostingController.sizingOptions = []
            let window = NSWindow(contentViewController: hostingController)
            window.title = "DisplayDJ — 显示设置与预设"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 700, height: 560))
            window.contentMinSize = NSSize(width: 660, height: 520)
            window.center()
            toolsWindow = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        toolsWindow?.showWindow(nil)
        toolsWindow?.window?.makeKeyAndOrderFront(nil)
    }
}
