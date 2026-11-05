import AppKit
import DisplayDJCore
import Foundation
import SwiftUI

@MainActor
public final class UpdateManager: ObservableObject {
  public let product: ProductLine
  public let currentVersion: SemanticVersion
  public let channel: BuildChannel

  @Published public private(set) var isChecking = false
  @Published public private(set) var isUpdating = false
  @Published public private(set) var updateProgress: Double = 0.0
  @Published public private(set) var statusMessage: String = ""
  @Published public private(set) var checkResult: UpdateCheckResult?
  @Published public private(set) var lastCheckDate: Date?

  private let checker: UpdateChecking
  private let verifier: UpdatePackageVerifying
  private var pendingSwap: (process: Process, staged: URL)?

  public init(
    product: ProductLine,
    currentVersion: String,
    channel: BuildChannel = BuildChannel.current,
    checker: UpdateChecking = GitHubUpdateChecker(),
    verifier: UpdatePackageVerifying = LocalUpdatePackageVerifier()
  ) {
    self.product = product
    self.currentVersion = SemanticVersion.parse(currentVersion) ?? SemanticVersion(major: 1, minor: 0, patch: 0)
    self.channel = channel
    self.checker = checker
    self.verifier = verifier
    NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate),
                                           name: NSApplication.willTerminateNotification, object: nil)

    // Load last check date from UserDefaults
    let key = "DisplayDJLastUpdateCheck_\(product.rawValue)"
    if let saved = UserDefaults.standard.object(forKey: key) as? Date {
      self.lastCheckDate = saved
    }
  }

  /// Checks for updates.
  /// If `isManual` is false, respects a 24-hour quiet interval.
  public func checkForUpdates(isManual: Bool = false) async {
    if !isManual, let last = lastCheckDate, Date().timeIntervalSince(last) < 86400 {
      // Cooldown active, skip automatic check
      return
    }

    guard !isChecking && !isUpdating else { return }
    isChecking = true
    if isManual { statusMessage = "正在检查更新…" }

    defer {
      isChecking = false
    }

    let result = await checker.checkForUpdates(
      product: product,
      currentVersion: currentVersion,
      channel: channel
    )

    self.checkResult = result
    let now = Date()
    self.lastCheckDate = now
    UserDefaults.standard.set(now, forKey: "DisplayDJLastUpdateCheck_\(product.rawValue)")

    switch result {
    case .upToDate:
      if isManual { statusMessage = "已是最新版本" }
    case .developmentAhead:
      if isManual { statusMessage = "开发版本已领先线上发布" }
    case .updateAvailable:
      statusMessage = ""
    case .checkFailed(let message):
      if isManual { statusMessage = message }
    }
  }

  public func applyUpdate() async {
    guard !isUpdating, case .updateAvailable(_, let newVersion, let release, _) = checkResult else { return }
    guard let (zipAsset, shaAsset) = release.findPackageAssets(for: product, arch: getSystemArchitecture()) else {
      statusMessage = "未找到适用于当前 Mac 架构的更新安装包"
      return
    }

    isUpdating = true
    updateProgress = 0.0
    statusMessage = "准备下载更新…"

    do {
      let verified = try await verifier.downloadAndVerify(
        assetURL: zipAsset.downloadURL,
        checksumURL: shaAsset?.downloadURL,
        expectedBundleID: product.bundleIdentifier
      ) { [weak self] progress, message in
        Task { @MainActor [weak self] in
          self?.updateProgress = progress
          self?.statusMessage = message
        }
      }

      guard SemanticVersion.parse(verified.version) == newVersion else {
        throw DisplayDJError(code: .internalFailure, message: "安装包版本与发布版本不一致", operation: .read)
      }
      statusMessage = "正在应用更新并准备重启…"
      try await performSwapAndRelaunch(with: verified)
    } catch {
      isUpdating = false
      statusMessage = "更新失败：\(error.localizedDescription)"
    }
  }

  public func cancelPendingUpdate() {
    guard let swap = pendingSwap else { return }
    pendingSwap = nil
    isUpdating = false
    do {
      try FileManager.default.removeItem(at: swap.staged)
      statusMessage = "已取消更新，应用保持原状"
    } catch {
      NSLog("无法清理已取消的更新：%@", error.localizedDescription)
      statusMessage = "已取消更新，应用保持原状；未能清理暂存包"
    }
  }

  @objc private func applicationWillTerminate() {
    guard let swap = pendingSwap else { return }
    do {
      try swap.process.run()
    } catch {
      NSLog("无法启动更新助手：%@", error.localizedDescription)
      cancelPendingUpdate()
    }
  }

  private func performSwapAndRelaunch(with package: VerifiedUpdatePackage) async throws {
    let mainBundle = Bundle.main
    let targetAppURL = mainBundle.bundleURL

    if targetAppURL.pathExtension == "app" {
      // Stage a complete copy beside the installed app before allowing it to quit.
      let fileManager = FileManager.default
      let parent = targetAppURL.deletingLastPathComponent()
      let token = UUID().uuidString
      let staged = parent.appendingPathComponent(".DisplayDJ-update-\(token).app")
      let backup = parent.appendingPathComponent(".DisplayDJ-backup-\(token).app")
      let scriptContent = """
      #!/bin/bash
      pid="$1"
      target="$2"
      staged="$3"
      backup="$4"
      while /bin/kill -0 "$pid" 2>/dev/null; do
        /bin/sleep 0.2
      done
      if /bin/mv "$target" "$backup"; then
        if /bin/mv "$staged" "$target"; then
          if ! /usr/bin/open -n "$target"; then
            if /bin/mv "$target" "$staged" && /bin/mv "$backup" "$target"; then
              /usr/bin/open -n "$target"
            fi
          fi
        else
          if /bin/mv "$backup" "$target"; then
            /usr/bin/open -n "$target"
          else
            /usr/bin/open -n "$backup"
          fi
        fi
      else
        /usr/bin/open -n "$target"
      fi
      """
      let scriptURL = package.temporaryDirectory.appendingPathComponent("swap_and_relaunch.sh")
      try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
      try fileManager.copyItem(at: package.extractedAppURL, to: staged)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/bash")
      process.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier),
                           targetAppURL.path, staged.path, backup.path]
      pendingSwap = (process, staged)
      NSApp.terminate(nil)

    } else {
      // Non-bundle / CLI execution: place the app in Downloads
      let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
      let destURL = downloads.appendingPathComponent(package.extractedAppURL.lastPathComponent)
      guard !FileManager.default.fileExists(atPath: destURL.path) else {
        throw DisplayDJError(code: .internalFailure, message: "下载文件夹已有同名应用，请先移走或重命名", operation: .read)
      }
      try FileManager.default.copyItem(at: package.extractedAppURL, to: destURL)
      NSWorkspace.shared.activateFileViewerSelecting([destURL])
      isUpdating = false
      statusMessage = "已下载并校验最新应用包至「下载」文件夹"
    }
  }
}
