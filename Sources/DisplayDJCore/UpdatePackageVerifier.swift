import CryptoKit
import Foundation

public struct VerifiedUpdatePackage: Sendable {
  public let extractedAppURL: URL
  public let temporaryDirectory: URL
  public let bundleIdentifier: String
  public let version: String

  public init(extractedAppURL: URL, temporaryDirectory: URL, bundleIdentifier: String, version: String) {
    self.extractedAppURL = extractedAppURL
    self.temporaryDirectory = temporaryDirectory
    self.bundleIdentifier = bundleIdentifier
    self.version = version
  }
}

public protocol UpdatePackageVerifying: Sendable {
  func downloadAndVerify(
    assetURL: URL,
    checksumURL: URL?,
    expectedBundleID: String,
    onProgress: @Sendable @escaping (Double, String) -> Void
  ) async throws -> VerifiedUpdatePackage
}

public final class LocalUpdatePackageVerifier: UpdatePackageVerifying {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func downloadAndVerify(
    assetURL: URL,
    checksumURL: URL?,
    expectedBundleID: String,
    onProgress: @Sendable @escaping (Double, String) -> Void
  ) async throws -> VerifiedUpdatePackage {
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent("DisplayDJUpdate-\(UUID().uuidString)")
    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

    onProgress(0.1, "正在下载更新包…")
    let zipPath = tempDir.appendingPathComponent("update.zip")

    // Download archive
    let (downloadedURL, response) = try await session.download(from: assetURL)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw DisplayDJError(code: .internalFailure, message: "更新包下载失败", operation: .read)
    }
    try fileManager.moveItem(at: downloadedURL, to: zipPath)
    onProgress(0.5, "正在校验安装包…")

    guard let checksumURL else {
      throw DisplayDJError(code: .internalFailure, message: "更新包缺少 SHA256 校验文件", operation: .read)
    }
    let (checksumData, checksumResponse) = try await session.data(from: checksumURL)
    guard let http = checksumResponse as? HTTPURLResponse, (200...299).contains(http.statusCode),
          let checksumString = String(data: checksumData, encoding: .utf8),
          let expectedHex = checksumString.split(whereSeparator: { $0.isWhitespace }).first,
          expectedHex.count == 64,
          expectedHex.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
      throw DisplayDJError(code: .internalFailure, message: "SHA256 校验文件无效或下载失败", operation: .read)
    }
    let zipData = try Data(contentsOf: zipPath, options: .mappedIfSafe)
    let calculatedHex = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
    guard calculatedHex.caseInsensitiveCompare(String(expectedHex)) == .orderedSame else {
      throw DisplayDJError(code: .internalFailure, message: "SHA256 校验和不匹配", operation: .read)
    }

    onProgress(0.7, "正在解压安装包…")
    let extractDir = tempDir.appendingPathComponent("extracted")
    try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)

    let dittoProcess = Process()
    dittoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    dittoProcess.arguments = ["-x", "-k", zipPath.path, extractDir.path]
    try dittoProcess.run()
    dittoProcess.waitUntilExit()

    guard dittoProcess.terminationStatus == 0 else {
      throw DisplayDJError(
        code: .internalFailure,
        message: "解压更新包失败",
        operation: .read,
        details: ["status": "\(dittoProcess.terminationStatus)"]
      )
    }

    // Locate .app in extractDir
    let contents = try fileManager.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
    guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
      throw DisplayDJError(
        code: .internalFailure,
        message: "更新包中未找到有效的 macOS 应用程序 (.app)",
        operation: .read
      )
    }

    onProgress(0.85, "正在校验代码签名与完整性…")
    // Verify Bundle Identifier
    let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
    guard let plistData = try? Data(contentsOf: infoPlistURL),
          let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
          let bundleID = plist["CFBundleIdentifier"] as? String,
          let version = plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String else {
      throw DisplayDJError(
        code: .internalFailure,
        message: "应用程序配置 (Info.plist) 损坏或无法读取",
        operation: .read
      )
    }

    guard bundleID == expectedBundleID else {
      throw DisplayDJError(
        code: .internalFailure,
        message: "更新包 Identifier (\(bundleID)) 与当前应用 (\(expectedBundleID)) 不匹配",
        operation: .read
      )
    }

    // Verify codesign
    let codesignProcess = Process()
    codesignProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    codesignProcess.arguments = ["--verify", "--deep", "--strict", appURL.path]
    try codesignProcess.run()
    codesignProcess.waitUntilExit()

    guard codesignProcess.terminationStatus == 0 else {
      throw DisplayDJError(
        code: .internalFailure,
        message: "更新包代码签名校验未通过",
        operation: .read,
        details: ["status": "\(codesignProcess.terminationStatus)"]
      )
    }

    onProgress(1.0, "安装包校验通过")
    return VerifiedUpdatePackage(
      extractedAppURL: appURL,
      temporaryDirectory: tempDir,
      bundleIdentifier: bundleID,
      version: version
    )
  }
}
