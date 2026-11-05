import AppKit
import DisplayDJCore
@testable import DisplayDJUI
import Foundation
import SwiftUI
import Testing

private struct MockChecker: UpdateChecking {
  let resultToReturn: UpdateCheckResult

  func checkForUpdates(
    product: ProductLine,
    currentVersion: SemanticVersion,
    channel: BuildChannel
  ) async -> UpdateCheckResult {
    resultToReturn
  }
}

@Suite("Update UI Visual Previews Generator")
@MainActor
struct UpdateVisualPreviewTests {

  private func saveViewAsPNG<V: View>(_ view: V, size: CGSize, fileURL: URL) throws {
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.appearance = NSAppearance(named: .aqua)
    hostingView.layoutSubtreeIfNeeded()

    guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
      Issue.record("Failed to create bitmapImageRep")
      return
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
      Issue.record("Failed to get PNG data")
      return
    }

    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try pngData.write(to: fileURL)
  }

  @Test func generateUpdateVisualSnapshots() async throws {
    let artifactDir = FileManager.default.temporaryDirectory.appendingPathComponent("DisplayDJ-update-previews-\(UUID().uuidString)")

    // 1. Snapshot: Full App - Development Ahead (Clean layout)
    let devAheadChecker = MockChecker(
      resultToReturn: .developmentAhead(
        current: SemanticVersion(major: 1, minor: 2, patch: 0),
        latestRelease: SemanticVersion(major: 1, minor: 1, patch: 0)
      )
    )
    let fullManagerDevAhead = UpdateManager(
      product: .full,
      currentVersion: "1.2.0",
      channel: .debug,
      checker: devAheadChecker
    )
    await fullManagerDevAhead.checkForUpdates(isManual: true)

    let fullViewDevAhead = GroupBox {
      UpdateSectionView(manager: fullManagerDevAhead, compact: false)
        .padding(.vertical, 4)
    } label: {
      Text("软件更新").font(.headline)
    }
    .frame(width: 540)
    .padding(20)

    try saveViewAsPNG(fullViewDevAhead, size: CGSize(width: 580, height: 110),
                      fileURL: artifactDir.appendingPathComponent("full-update-dev-ahead.png"))

    // 2. Snapshot: Full App - Update Available (Clean single row)
    let mockRelease = GitHubReleaseSummary(
      tagName: "v1.2.0",
      name: "DisplayDJ 1.2.0",
      body: nil,
      htmlUrl: URL(string: "https://github.com/hellowmq/displaydj/releases/tag/v1.2.0")!,
      publishedAt: Date(),
      isPrerelease: false,
      assets: []
    )
    let updateAvailChecker = MockChecker(
      resultToReturn: .updateAvailable(
        current: SemanticVersion(major: 1, minor: 2, patch: 0),
        newVersion: SemanticVersion(major: 1, minor: 2, patch: 0),
        release: mockRelease,
        isDebugReplacingRelease: true
      )
    )
    let fullManagerUpdateAvail = UpdateManager(
      product: .full,
      currentVersion: "1.2.0",
      channel: .debug,
      checker: updateAvailChecker
    )
    await fullManagerUpdateAvail.checkForUpdates(isManual: true)

    let fullViewUpdateAvail = GroupBox {
      UpdateSectionView(manager: fullManagerUpdateAvail, compact: false)
        .padding(.vertical, 4)
    } label: {
      Text("软件更新").font(.headline)
    }
    .frame(width: 540)
    .padding(20)

    try saveViewAsPNG(fullViewUpdateAvail, size: CGSize(width: 580, height: 140),
                      fileURL: artifactDir.appendingPathComponent("full-update-available.png"))

    // 3. Snapshot: Lite App - Help Popover (Compact, zero fluff)
    let liteChecker = MockChecker(
      resultToReturn: .developmentAhead(
        current: SemanticVersion(major: 0, minor: 3, patch: 0),
        latestRelease: SemanticVersion(major: 0, minor: 2, patch: 0)
      )
    )
    let liteManager = UpdateManager(
      product: .lite,
      currentVersion: "0.3.0",
      channel: .debug,
      checker: liteChecker
    )
    await liteManager.checkForUpdates(isManual: true)

    let liteHelpView = VStack(alignment: .leading, spacing: 10) {
      Text("DisplayDJ Lite").font(.headline)
      Text("版本 0.3.0").font(.caption).foregroundStyle(.secondary)
      Divider()
      Text("内建屏调节原生背光，支持的外屏通过 DDC 调节硬件亮度。不支持时会说明原因，不会自动改用软件调暗。")
        .font(.callout)
      Text("内建屏、镜像屏及最后一块在线屏幕受到保护。")
        .font(.callout)
      Divider()
      UpdateSectionView(manager: liteManager, compact: true)
    }
    .padding(18)
    .frame(width: 280)
    .background(Color(NSColor.windowBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .padding(16)

    try saveViewAsPNG(liteHelpView, size: CGSize(width: 312, height: 320),
                      fileURL: artifactDir.appendingPathComponent("lite-update-popover.png"))
  }
}

private struct WrongVersionVerifier: UpdatePackageVerifying {
  func downloadAndVerify(assetURL: URL, checksumURL: URL?, expectedBundleID: String,
                         onProgress: @Sendable @escaping (Double, String) -> Void) async throws -> VerifiedUpdatePackage {
    VerifiedUpdatePackage(extractedAppURL: URL(fileURLWithPath: "/tmp/example.app"),
                          temporaryDirectory: FileManager.default.temporaryDirectory,
                          bundleIdentifier: expectedBundleID, version: "1.0.0")
  }
}

@Test @MainActor func updateRejectsPackageWithWrongVersion() async {
  let zip = GitHubAssetSummary(name: "displaydj-1.2.0-macos-\(getSystemArchitecture()).zip", size: 1,
                               downloadURL: URL(string: "https://example.com/update.zip")!)
  let release = GitHubReleaseSummary(tagName: "v1.2.0", name: "1.2.0", body: nil,
                                     htmlUrl: URL(string: "https://example.com/release")!,
                                     publishedAt: nil, isPrerelease: false, assets: [zip])
  let manager = UpdateManager(product: .full, currentVersion: "1.1.0", channel: .release,
                              checker: MockChecker(resultToReturn: .updateAvailable(
                                current: SemanticVersion(major: 1, minor: 1, patch: 0),
                                newVersion: SemanticVersion(major: 1, minor: 2, patch: 0),
                                release: release, isDebugReplacingRelease: false)),
                              verifier: WrongVersionVerifier())
  await manager.checkForUpdates(isManual: true)
  await manager.applyUpdate()
  #expect(!manager.isUpdating)
  #expect(manager.statusMessage.contains("安装包版本与发布版本不一致"))
}
