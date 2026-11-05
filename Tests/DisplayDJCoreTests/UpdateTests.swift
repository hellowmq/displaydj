import Foundation
import Testing
@testable import DisplayDJCore

@Suite("Built-in Update & Version Stream Tests")
struct UpdateTests {

  @Test func semanticVersionParsingAndFormatting() {
    let v1 = SemanticVersion.parse("1.2.0")
    #expect(v1 != nil)
    #expect(v1?.major == 1)
    #expect(v1?.minor == 2)
    #expect(v1?.patch == 0)
    #expect(v1?.prerelease == nil)
    #expect(v1?.description == "1.2.0")

    let vTag = SemanticVersion.parse("v1.2.3")
    #expect(vTag?.major == 1)
    #expect(vTag?.minor == 2)
    #expect(vTag?.patch == 3)

    let liteTag = SemanticVersion.parse("lite-v0.3.0")
    #expect(liteTag?.major == 0)
    #expect(liteTag?.minor == 3)
    #expect(liteTag?.patch == 0)

    let pre = SemanticVersion.parse("1.2.0-preview.2")
    #expect(pre?.prerelease == "preview.2")
    #expect(pre?.description == "1.2.0-preview.2")

    let invalid = SemanticVersion.parse("invalid-version")
    #expect(invalid == nil)
  }

  @Test func semanticVersionComparison() {
    let v110 = SemanticVersion(major: 1, minor: 1, patch: 0)
    let v120 = SemanticVersion(major: 1, minor: 2, patch: 0)
    let v121 = SemanticVersion(major: 1, minor: 2, patch: 1)
    let v200 = SemanticVersion(major: 2, minor: 0, patch: 0)
    let v120Beta = SemanticVersion(major: 1, minor: 2, patch: 0, prerelease: "beta.1")

    #expect(v110 < v120)
    #expect(v120 < v121)
    #expect(v121 < v200)
    #expect(v120Beta < v120)
    #expect(v110 < v120Beta)
    #expect(v120 == v120)
  }

  @Test func dualProductLineTagAndArchiveFiltering() {
    // Full product line
    #expect(ProductLine.full.matchesTag("v1.1.0"))
    #expect(ProductLine.full.matchesTag("v1.2.0"))
    #expect(!ProductLine.full.matchesTag("lite-v0.2.0"))
    #expect(ProductLine.full.versionString(from: "v1.2.0") == "1.2.0")
    #expect(ProductLine.full.matchesArchive(assetName: "displaydj-1.2.0-macos-arm64.zip", arch: "arm64"))
    #expect(!ProductLine.full.matchesArchive(assetName: "displaydj-lite-0.3.0-macos-arm64.zip", arch: "arm64"))
    #expect(!ProductLine.full.matchesArchive(assetName: "displaydj-1.2.0-macos-arm64.dmg", arch: "arm64"))

    // Lite product line
    #expect(ProductLine.lite.matchesTag("lite-v0.2.0"))
    #expect(ProductLine.lite.matchesTag("lite-v0.3.0"))
    #expect(!ProductLine.lite.matchesTag("v1.2.0"))
    #expect(ProductLine.lite.versionString(from: "lite-v0.3.0") == "0.3.0")
    #expect(ProductLine.lite.matchesArchive(assetName: "displaydj-lite-0.3.0-macos-arm64.zip", arch: "arm64"))
    #expect(!ProductLine.lite.matchesArchive(assetName: "displaydj-1.2.0-macos-arm64.zip", arch: "arm64"))
  }

  @Test func releaseEvaluationDebugVsReleaseGrades() {
    let checker = GitHubUpdateChecker(arch: "arm64")

    let fullAssetZip = GitHubAssetSummary(
      name: "displaydj-1.2.0-macos-arm64.zip",
      size: 5000000,
      downloadURL: URL(string: "https://example.com/displaydj-1.2.0.zip")!
    )
    let fullAssetSha = GitHubAssetSummary(
      name: "displaydj-1.2.0-macos-arm64.zip.sha256",
      size: 98,
      downloadURL: URL(string: "https://example.com/displaydj-1.2.0.zip.sha256")!
    )

    let mockReleases: [GitHubReleaseSummary] = [
      GitHubReleaseSummary(
        tagName: "v1.2.0",
        name: "DisplayDJ 1.2.0",
        body: "New features and updater",
        htmlUrl: URL(string: "https://github.com/hellowmq/displaydj/releases/tag/v1.2.0")!,
        publishedAt: Date(),
        isPrerelease: false,
        assets: [fullAssetZip, fullAssetSha]
      ),
      GitHubReleaseSummary(
        tagName: "v1.1.0",
        name: "DisplayDJ 1.1.0",
        body: "Previous version",
        htmlUrl: URL(string: "https://github.com/hellowmq/displaydj/releases/tag/v1.1.0")!,
        publishedAt: Date().addingTimeInterval(-86400),
        isPrerelease: false,
        assets: []
      ),
      GitHubReleaseSummary(
        tagName: "lite-v0.3.0",
        name: "DisplayDJ Lite 0.3.0",
        body: "Lite updater support",
        htmlUrl: URL(string: "https://github.com/hellowmq/displaydj/releases/tag/lite-v0.3.0")!,
        publishedAt: Date(),
        isPrerelease: true,
        assets: [
          GitHubAssetSummary(
            name: "displaydj-lite-0.3.0-macos-arm64.zip",
            size: 2000000,
            downloadURL: URL(string: "https://example.com/lite-0.3.0.zip")!
          )
        ]
      )
    ]

    // 1. Current is Debug v1.2.0, while remote latest release is v1.1.0 -> developmentAhead
    let olderReleasesOnly = Array(mockReleases.dropFirst())
    let devAheadResult = checker.evaluateReleases(
      olderReleasesOnly,
      product: .full,
      currentVersion: SemanticVersion(major: 1, minor: 2, patch: 0),
      channel: .debug
    )
    if case .developmentAhead(let cur, let latest) = devAheadResult {
      #expect(cur == SemanticVersion(major: 1, minor: 2, patch: 0))
      #expect(latest == SemanticVersion(major: 1, minor: 1, patch: 0))
    } else {
      Issue.record("Expected developmentAhead result for debug build ahead of official release, got \(devAheadResult)")
    }

    // 2. Current is Debug v1.2.0, and official release v1.2.0 is published -> updateAvailable with isDebugReplacingRelease = true
    let debugMatchesReleaseResult = checker.evaluateReleases(
      mockReleases,
      product: .full,
      currentVersion: SemanticVersion(major: 1, minor: 2, patch: 0),
      channel: .debug
    )
    if case .updateAvailable(let cur, let newVer, _, let isDebugReplacingRelease) = debugMatchesReleaseResult {
      #expect(cur == SemanticVersion(major: 1, minor: 2, patch: 0))
      #expect(newVer == SemanticVersion(major: 1, minor: 2, patch: 0))
      #expect(isDebugReplacingRelease == true)
    } else {
      Issue.record("Expected updateAvailable with isDebugReplacingRelease for matching debug build")
    }

    // 3. Current is Release v1.2.0, remote latest is v1.2.0 -> upToDate
    let releaseUpToDateResult = checker.evaluateReleases(
      mockReleases,
      product: .full,
      currentVersion: SemanticVersion(major: 1, minor: 2, patch: 0),
      channel: .release
    )
    #expect(releaseUpToDateResult == .upToDate(current: SemanticVersion(major: 1, minor: 2, patch: 0), channel: .release))

    // 4. Current is Release v1.1.0, remote latest is v1.2.0 -> updateAvailable
    let updateAvailResult = checker.evaluateReleases(
      mockReleases,
      product: .full,
      currentVersion: SemanticVersion(major: 1, minor: 1, patch: 0),
      channel: .release
    )
    if case .updateAvailable(let cur, let newVer, let release, let isDebugReplacingRelease) = updateAvailResult {
      #expect(cur == SemanticVersion(major: 1, minor: 1, patch: 0))
      #expect(newVer == SemanticVersion(major: 1, minor: 2, patch: 0))
      #expect(release.tagName == "v1.2.0")
      #expect(isDebugReplacingRelease == false)

      let assets = release.findPackageAssets(for: .full, arch: "arm64")
      #expect(assets?.zip.name == "displaydj-1.2.0-macos-arm64.zip")
      #expect(assets?.sha256?.name == "displaydj-1.2.0-macos-arm64.zip.sha256")
    } else {
      Issue.record("Expected updateAvailable for older release")
    }

    // 5. Lite product line evaluation
    let liteResult = checker.evaluateReleases(
      mockReleases,
      product: .lite,
      currentVersion: SemanticVersion(major: 0, minor: 2, patch: 0),
      channel: .release
    )
    if case .updateAvailable(_, let newVer, let release, _) = liteResult {
      #expect(newVer == SemanticVersion(major: 0, minor: 3, patch: 0))
      #expect(release.tagName == "lite-v0.3.0")
    } else {
      Issue.record("Expected updateAvailable for Lite")
    }
  }

  @Test func liveGitHubCheckEvaluatesRealRemoteReleases() async {
    let checker = GitHubUpdateChecker()
    let result = await checker.checkForUpdates(
      product: .full,
      currentVersion: SemanticVersion(major: 1, minor: 2, patch: 0),
      channel: .debug
    )
    switch result {
    case .developmentAhead(let cur, let latest):
      #expect(cur == SemanticVersion(major: 1, minor: 2, patch: 0))
      #expect(latest >= SemanticVersion(major: 1, minor: 1, patch: 0))
    case .updateAvailable(let cur, let newVer, _, _):
      #expect(cur == SemanticVersion(major: 1, minor: 2, patch: 0))
      #expect(newVer >= SemanticVersion(major: 1, minor: 1, patch: 0))
    case .checkFailed(let message):
      print("Live network check failed (offline or rate limited):", message)
    default:
      Issue.record("Unexpected result against real GitHub: \(result)")
    }
  }
}

private final class UpdateFixtureProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let url = request.url!
    let status = url.path == "/missing" ? 404 : 200
    let body: String
    switch url.path {
    case "/archive": body = "abc"
    case "/malformed": body = "not-a-hash"
    case "/mismatch": body = String(repeating: "0", count: 64)
    default: body = "missing"
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
                                                          httpVersion: nil, headerFields: nil)!,
                        cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@Test(arguments: ["missing", "malformed", "mismatch"])
func invalidChecksumStopsPackageVerification(path: String) async throws {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [UpdateFixtureProtocol.self]
  let verifier = LocalUpdatePackageVerifier(session: URLSession(configuration: configuration))
  do {
    _ = try await verifier.downloadAndVerify(assetURL: URL(string: "https://fixture.test/archive")!,
                                              checksumURL: URL(string: "https://fixture.test/\(path)")!,
                                              expectedBundleID: "test.app", onProgress: { _, _ in })
    Issue.record("Invalid checksum unexpectedly accepted")
  } catch {
    #expect(error.localizedDescription.contains("SHA256"))
  }
}
