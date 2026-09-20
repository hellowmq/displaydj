import AppKit
import SwiftUI
import VibeDisplayCore

/// A read-only view of the same authenticated local service used by the CLI.
/// Starting the service is an explicit user action and does not install a login item.
struct AgentServiceView: View {
  @State private var summary = "正在检查服务…"
  @State private var running = false
  @State private var starting = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label("Agent 服务", systemImage: "terminal")
          .font(.system(size: 11, weight: .medium))
        Spacer()
        Circle().fill(running ? Color.green : Color.secondary).frame(width: 6, height: 6)
      }
      Text(summary).font(.system(size: 10)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if !running {
        Button(starting ? "正在启动…" : "启动本地服务") {
          Task { await startService() }
        }
        .font(.system(size: 10)).disabled(starting)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task {
      while !Task.isCancelled {
        await refresh()
        do { try await Task.sleep(for: .seconds(5)) } catch { break }
      }
    }
  }

  @MainActor
  private func refresh() async {
    guard let descriptor = DaemonDescriptor.loadIfAlive() else {
      running = false
      summary = "未运行 · 启动后可接收 CLI / HTTP 任务"
      return
    }
    // Never send a local bearer token to a descriptor pointing off-box.
    guard ["127.0.0.1", "localhost", "::1"].contains(descriptor.host),
          (1...65535).contains(descriptor.port) else {
      running = false
      summary = "服务地址不是有效的本机地址"
      return
    }
    let host = descriptor.host == "::1" ? "[::1]" : descriptor.host
    guard let url = URL(string: "http://\(host):\(descriptor.port)/v1/health") else { return }
    var request = URLRequest(url: url, timeoutInterval: 2)
    if let token = TokenStore.load() {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.userAuthenticationRequired)
      }
      let envelope = try JSONDecoder().decode(ServiceEnvelope.self, from: data)
      guard envelope.ok, let health = envelope.data else { throw URLError(.badServerResponse) }
      running = true
      summary = "\(health.activeSessions) 个任务 · \(health.activeLeases) 个保活租约 · v\(health.version)"
    } catch {
      running = false
      summary = "服务未响应，请运行 display-cli daemon status 检查"
    }
  }

  @MainActor
  private func startService() async {
    starting = true
    defer { starting = false }
    let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/display-cli")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      summary = "请使用打包后的 App，或在终端运行 display-cli serve --detach"
      return
    }
    do {
      let code = try await Task.detached {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--detach"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
      }.value
      guard code == 0 else {
        summary = "启动失败（\(code)），请运行 display-cli daemon logs 检查"
        return
      }
      await refresh()
    } catch {
      summary = "启动失败：\(error.localizedDescription)"
    }
  }
}

private struct ServiceEnvelope: Decodable {
  let ok: Bool
  let data: ServiceHealth?
}

private struct ServiceHealth: Decodable {
  let version: String
  let activeSessions: Int
  let activeLeases: Int
}
