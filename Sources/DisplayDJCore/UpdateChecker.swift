import Foundation

#if canImport(Darwin)
import Darwin
#endif

public func getSystemArchitecture() -> String {
  var sysinfo = utsname()
  uname(&sysinfo)
  let machine = withUnsafeBytes(of: &sysinfo.machine) { rawPtr -> String in
    guard let base = rawPtr.baseAddress else { return "arm64" }
    let ptr = base.assumingMemoryBound(to: CChar.self)
    return String(cString: ptr)
  }
  return machine.isEmpty ? "arm64" : machine
}

public protocol UpdateChecking: Sendable {
  func checkForUpdates(
    product: ProductLine,
    currentVersion: SemanticVersion,
    channel: BuildChannel
  ) async -> UpdateCheckResult
}

public final class GitHubUpdateChecker: UpdateChecking {
  public let endpointURL: URL
  public let session: URLSession
  public let arch: String

  public init(
    endpointURL: URL? = nil,
    session: URLSession = .shared,
    arch: String? = nil
  ) {
    if let endpointURL {
      self.endpointURL = endpointURL
    } else if let custom = ProcessInfo.processInfo.environment["DISPLAYDJ_UPDATE_URL"],
              let url = URL(string: custom) {
      self.endpointURL = url
    } else {
      self.endpointURL = URL(string: "https://api.github.com/repos/hellowmq/displaydj/releases")!
    }
    self.session = session
    self.arch = arch ?? getSystemArchitecture()
  }

  public func checkForUpdates(
    product: ProductLine,
    currentVersion: SemanticVersion,
    channel: BuildChannel
  ) async -> UpdateCheckResult {
    var request = URLRequest(url: endpointURL)
    request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
    request.setValue("DisplayDJ-Updater/\(currentVersion)", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 15

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .checkFailed(message: "无效的网络响应")
      }
      guard http.statusCode == 200 else {
        if http.statusCode == 403 {
          return .checkFailed(message: "GitHub API 请求频率受限，请稍后重试")
        }
        return .checkFailed(message: "检查更新失败 (HTTP \(http.statusCode))")
      }

      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let releases = try decoder.decode([GitHubReleaseSummary].self, from: data)

      return evaluateReleases(releases, product: product, currentVersion: currentVersion, channel: channel)
    } catch {
      return .checkFailed(message: "无法连接到更新服务器：\(error.localizedDescription)")
    }
  }

  public func evaluateReleases(
    _ releases: [GitHubReleaseSummary],
    product: ProductLine,
    currentVersion: SemanticVersion,
    channel: BuildChannel
  ) -> UpdateCheckResult {
    let candidates = releases.compactMap { release -> (release: GitHubReleaseSummary, version: SemanticVersion)? in
      guard let verStr = product.versionString(from: release.tagName),
            let ver = SemanticVersion.parse(verStr) else {
        return nil
      }
      return (release, ver)
    }

    guard let (highestRelease, highestVersion) = candidates.max(by: { $0.version < $1.version }) else {
      return .upToDate(current: currentVersion, channel: channel)
    }

    if highestVersion > currentVersion {
      return .updateAvailable(
        current: currentVersion,
        newVersion: highestVersion,
        release: highestRelease,
        isDebugReplacingRelease: false
      )
    } else if highestVersion == currentVersion {
      if channel == .debug {
        return .updateAvailable(
          current: currentVersion,
          newVersion: highestVersion,
          release: highestRelease,
          isDebugReplacingRelease: true
        )
      } else {
        return .upToDate(current: currentVersion, channel: channel)
      }
    } else {
      if channel == .debug {
        return .developmentAhead(current: currentVersion, latestRelease: highestVersion)
      } else {
        return .upToDate(current: currentVersion, channel: channel)
      }
    }
  }
}
