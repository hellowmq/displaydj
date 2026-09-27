import Foundation

/// A display this tool disconnected and can therefore reconnect.
public struct DisplayConnectionRecord: Codable, Equatable, Hashable, Sendable {
  public let runtimeID: UInt32
  public let stableID: String?
  public let name: String
  public let disconnectedAt: Date

  public init(
    runtimeID: UInt32,
    stableID: String?,
    name: String,
    disconnectedAt: Date = Date()
  ) {
    self.runtimeID = runtimeID
    self.stableID = stableID
    self.name = name
    self.disconnectedAt = disconnectedAt
  }
}

/// Persists the identity of displays disconnected by this tool.
///
/// A disconnected display disappears from the online topology, so a stable ID
/// can no longer be resolved back to a runtime ID by discovery alone. The
/// record is what makes reconnecting by stable ID possible at all.
public protocol DisplayConnectionRecordStoring: Sendable {
  func loadRecords() throws -> [DisplayConnectionRecord]
  func saveRecords(_ records: [DisplayConnectionRecord]) throws
}

/// The production store: one JSON file under Application Support, or under
/// `DISPLAYDJ_HOME` when an isolated CLI session selects a separate home.
public final class FileDisplayConnectionRecordStore: DisplayConnectionRecordStoring {
  private let fileURL: URL
  private let fileManager: FileManager

  public init(
    fileURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.fileManager = fileManager
    self.fileURL = Self.recordURL(
      fileURL: fileURL,
      fileManager: fileManager,
      environment: ProcessInfo.processInfo.environment
    )
  }

  public init(
    fileURL: URL? = nil,
    fileManager: FileManager = .default,
    environment: [String: String]
  ) {
    self.fileManager = fileManager
    self.fileURL = Self.recordURL(
      fileURL: fileURL,
      fileManager: fileManager,
      environment: environment
    )
  }

  private static func recordURL(
    fileURL: URL?,
    fileManager: FileManager,
    environment: [String: String]
  ) -> URL {
    if let fileURL {
      return fileURL
    } else if let home = environment["DISPLAYDJ_HOME"], !home.isEmpty {
      return URL(
        fileURLWithPath: (home as NSString).expandingTildeInPath,
        isDirectory: true
      ).appendingPathComponent("disconnected-displays.json", isDirectory: false)
    } else {
      let base = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
      return
        (base ?? fileManager.temporaryDirectory)
        .appendingPathComponent("DisplayDJ", isDirectory: true)
        .appendingPathComponent("disconnected-displays.json", isDirectory: false)
    }
  }

  public func loadRecords() throws -> [DisplayConnectionRecord] {
    guard let data = fileManager.contents(atPath: fileURL.path) else {
      return []
    }

    guard !data.isEmpty else {
      return []
    }

    do {
      return try JSONDecoder().decode([DisplayConnectionRecord].self, from: data)
    } catch {
      throw DisplayDJError(
        code: .internalFailure,
        message: "The saved disconnected-display record could not be read.",
        operation: .read,
        details: [
          "phase": "record-load",
          "path": fileURL.path,
        ]
      )
    }
  }

  public func saveRecords(_ records: [DisplayConnectionRecord]) throws {
    let directory = fileURL.deletingLastPathComponent()

    do {
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let data = try JSONEncoder().encode(records)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      throw DisplayDJError(
        code: .internalFailure,
        message: "The disconnected-display record could not be saved.",
        operation: .write,
        details: [
          "phase": "record-save",
          "path": fileURL.path,
        ]
      )
    }
  }
}

/// An in-memory store used by tests and by callers that opt out of persistence.
public final class InMemoryDisplayConnectionRecordStore: DisplayConnectionRecordStoring {
  private let lock = NSLock()
  private var records: [DisplayConnectionRecord]

  public init(records: [DisplayConnectionRecord] = []) {
    self.records = records
  }

  public func loadRecords() throws -> [DisplayConnectionRecord] {
    lock.lock()
    defer { lock.unlock() }
    return records
  }

  public func saveRecords(_ newRecords: [DisplayConnectionRecord]) throws {
    lock.lock()
    defer { lock.unlock() }
    records = newRecords
  }
}

/// A store that discards everything.
public struct NoOpDisplayConnectionRecordStore: DisplayConnectionRecordStoring {
  public init() {}

  public func loadRecords() throws -> [DisplayConnectionRecord] {
    []
  }

  public func saveRecords(_ records: [DisplayConnectionRecord]) throws {}
}

// Declared in an extension so the primary declaration stays on one line.
extension FileDisplayConnectionRecordStore: @unchecked Sendable {}

extension InMemoryDisplayConnectionRecordStore: @unchecked Sendable {}
