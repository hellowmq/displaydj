import Foundation

public enum ProductLine: String, Codable, Sendable, CaseIterable {
  case full = "full"
  case lite = "lite"

  public var displayName: String {
    switch self {
    case .full: return "DisplayDJ"
    case .lite: return "DisplayDJ Lite"
    }
  }

  public var bundleIdentifier: String {
    switch self {
    case .full: return "io.github.hellowmq.displaydj"
    case .lite: return "io.github.hellowmq.displaydj.lite"
    }
  }

  public var archivePrefix: String {
    switch self {
    case .full: return "displaydj"
    case .lite: return "displaydj-lite"
    }
  }

  /// Whether a GitHub release tag belongs to this product line.
  public func matchesTag(_ tag: String) -> Bool {
    switch self {
    case .full:
      return tag.hasPrefix("v") && !tag.hasPrefix("lite-")
    case .lite:
      return tag.hasPrefix("lite-v")
    }
  }

  /// Extracts the semantic version string from a release tag.
  public func versionString(from tag: String) -> String? {
    guard matchesTag(tag) else { return nil }
    switch self {
    case .full:
      return String(tag.dropFirst()) // drop "v"
    case .lite:
      return String(tag.dropFirst(6)) // drop "lite-v"
    }
  }

  /// Filters an asset name to see if it matches this product's archive for the specified architecture.
  public func matchesArchive(assetName: String, arch: String) -> Bool {
    guard assetName.hasSuffix(".zip") else { return false }
    switch self {
    case .full:
      guard assetName.hasPrefix("displaydj-") && !assetName.hasPrefix("displaydj-lite-") else { return false }
    case .lite:
      guard assetName.hasPrefix("displaydj-lite-") else { return false }
    }
    return assetName.contains("-\(arch).zip") || assetName.contains("macos-\(arch)")
  }
}

public enum BuildChannel: String, Codable, Sendable {
  case release
  case debug

  public var displayName: String {
    switch self {
    case .release: return "正式发布版"
    case .debug: return "开发测试版 (DEBUG)"
    }
  }

  public static var current: BuildChannel {
    #if DEBUG
    return .debug
    #else
    return .release
    #endif
  }
}

public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int
  public let prerelease: String?

  public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
    self.major = major
    self.minor = minor
    self.patch = patch
    self.prerelease = prerelease
  }

  public var description: String {
    if let prerelease, !prerelease.isEmpty {
      return "\(major).\(minor).\(patch)-\(prerelease)"
    }
    return "\(major).\(minor).\(patch)"
  }

  public static func parse(_ raw: String) -> SemanticVersion? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("lite-v") {
      text = String(text.dropFirst(6))
    } else if text.hasPrefix("v") {
      text = String(text.dropFirst())
    }

    let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
    let versionPart = parts.first ?? ""
    let prerelease = parts.count > 1 ? String(parts[1]) : nil

    let numbers = versionPart.split(separator: ".")
    guard numbers.count >= 2,
          let major = Int(numbers[0]),
          let minor = Int(numbers[1]) else {
      return nil
    }
    let patch = numbers.count > 2 ? (Int(numbers[2]) ?? 0) : 0
    return SemanticVersion(major: major, minor: minor, patch: patch, prerelease: prerelease)
  }

  public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    if lhs.major != rhs.major { return lhs.major < rhs.major }
    if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
    if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

    switch (lhs.prerelease, rhs.prerelease) {
    case (nil, nil):
      return false
    case (.some, nil):
      return true // 1.0.0-alpha < 1.0.0
    case (nil, .some):
      return false // 1.0.0 > 1.0.0-alpha
    case let (.some(lp), .some(rp)):
      return lp.localizedStandardCompare(rp) == .orderedAscending
    }
  }
}

public struct GitHubAssetSummary: Codable, Equatable, Sendable {
  public let name: String
  public let size: Int
  public let downloadURL: URL

  public init(name: String, size: Int, downloadURL: URL) {
    self.name = name
    self.size = size
    self.downloadURL = downloadURL
  }

  enum CodingKeys: String, CodingKey {
    case name
    case size
    case downloadURL = "browser_download_url"
  }
}

public struct GitHubReleaseSummary: Codable, Equatable, Sendable {
  public let tagName: String
  public let name: String
  public let body: String?
  public let htmlUrl: URL
  public let publishedAt: Date?
  public let isPrerelease: Bool
  public let assets: [GitHubAssetSummary]

  public init(
    tagName: String,
    name: String,
    body: String?,
    htmlUrl: URL,
    publishedAt: Date?,
    isPrerelease: Bool,
    assets: [GitHubAssetSummary]
  ) {
    self.tagName = tagName
    self.name = name
    self.body = body
    self.htmlUrl = htmlUrl
    self.publishedAt = publishedAt
    self.isPrerelease = isPrerelease
    self.assets = assets
  }

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case name
    case body
    case htmlUrl = "html_url"
    case publishedAt = "published_at"
    case isPrerelease = "prerelease"
    case assets
  }

  /// Finds matching zip archive asset and optional sha256 asset for this product and architecture.
  public func findPackageAssets(for product: ProductLine, arch: String) -> (zip: GitHubAssetSummary, sha256: GitHubAssetSummary?)? {
    guard let zipAsset = assets.first(where: { product.matchesArchive(assetName: $0.name, arch: arch) }) else {
      return nil
    }
    let shaAsset = assets.first(where: { $0.name == "\(zipAsset.name).sha256" })
    return (zipAsset, shaAsset)
  }
}

public enum UpdateCheckResult: Equatable, Sendable {
  case upToDate(current: SemanticVersion, channel: BuildChannel)
  case developmentAhead(current: SemanticVersion, latestRelease: SemanticVersion)
  case updateAvailable(current: SemanticVersion, newVersion: SemanticVersion, release: GitHubReleaseSummary, isDebugReplacingRelease: Bool)
  case checkFailed(message: String)
}
