import AppKit
import SwiftUI
import VibeDisplayCore

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

struct DisplayToolsView: View {
    @State private var displays: [DisplayModeReport] = []
    @State private var selectedDisplay = ""
    @State private var selectedMode: Int32 = -1
    @State private var profiles: [DisplayProfile] = []
    @State private var profileName = ""
    @State private var controls: [MonitorControlResult] = []
    @State private var busy = false
    @State private var notice = ""
    @State private var failed = false

    private var display: DisplayModeReport? { displays.first { $0.displayUUID == selectedDisplay } }
    private var selector: String { "uuid:\(selectedDisplay)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("显示设置与预设").font(.title2.bold())
                    Text("分辨率、显示器音量与亮度预设").foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("刷新") { perform { try await reload() } }.disabled(busy)
            }
            if !notice.isEmpty {
                Text(notice).font(.callout).foregroundStyle(failed ? Color.red : Color.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            TabView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Picker("显示器", selection: $selectedDisplay) {
                            ForEach(displays, id: \.displayUUID) { report in Text(report.slug).tag(report.displayUUID) }
                        }.onChange(of: selectedDisplay) { _ in
                            selectedMode = display?.current.id ?? -1
                            controls = []
                            notice = ""
                        }
                        if let display {
                            GroupBox("分辨率与刷新率") {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("当前：\(modeLabel(display.current))").font(.callout)
                                    Picker("切换至", selection: $selectedMode) {
                                        ForEach(display.modes.filter(\.usable)) { mode in Text(modeLabel(mode)).tag(mode.id) }
                                    }
                                    HStack {
                                        Text("仅列出 macOS 提供的模式").font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("应用模式") { perform {
                                            let result = try await DisplayToolsClient.request(DisplayModeChange.self,
                                                ["modes", "set", String(selectedMode), "--display", selector])
                                            try await reload()
                                            notice = result.verified ? "显示模式已回读确认" : "未确认显示模式"
                                        } }.disabled(selectedMode < 0 || selectedMode == display.current.id)
                                    }
                                }.padding(8)
                            }
                            GroupBox("显示器音量与对比度") {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("通过 DDC 控制外接显示器").font(.caption).foregroundStyle(.secondary)
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
                                            if let error = result.error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                        }
                                    }
                                }.padding(8)
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
        }.padding(24).frame(minWidth: 660, minHeight: 520)
        .task { perform { try await reload() } }
    }

    private func modeLabel(_ mode: DisplayModeInfo) -> String {
        "\(mode.width) × \(mode.height) · \(mode.refreshRate == 0 ? "刷新率未知" : String(format: "%.2f Hz", mode.refreshRate))\(mode.hiDPI ? " · HiDPI" : "")"
    }

    @MainActor private func reload() async throws {
        let modes = try await DisplayToolsClient.request(ToolsModesPayload.self, ["modes", "list"])
        displays = modes.displays
        if !displays.contains(where: { $0.displayUUID == selectedDisplay }) { selectedDisplay = displays.first?.displayUUID ?? "" }
        selectedMode = display?.current.id ?? -1
        profiles = try await DisplayToolsClient.request(ToolsProfilesPayload.self, ["profile", "list"]).profiles
    }

    @MainActor private func loadControls() async throws {
        var readings: [MonitorControlResult] = []
        for control in MonitorControl.allCases {
            readings += try await DisplayToolsClient.request(ToolsControlsPayload.self,
                [control.rawValue, "get", "--display", selector]).results
        }
        controls = readings
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

private struct ToolsModesPayload: Decodable, Sendable { let displays: [DisplayModeReport] }
private struct ToolsProfilesPayload: Decodable, Sendable { let profiles: [DisplayProfile] }
private struct ToolsControlsPayload: Decodable, Sendable { let results: [MonitorControlResult] }

extension DisplayBarController {
    func showDisplayTools() {
        popover?.performClose(nil)
        if toolsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: DisplayToolsView()))
            window.title = "DisplayDJ — 显示设置与预设"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 700, height: 560))
            window.center()
            toolsWindow = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        toolsWindow?.showWindow(nil)
        toolsWindow?.window?.makeKeyAndOrderFront(nil)
    }
}
