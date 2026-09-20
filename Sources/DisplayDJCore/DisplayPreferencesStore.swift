import Foundation

/// Per-display presentation choices the user can set: a custom name (alias) for
/// each monitor, and an explicit card order that overrides the physical layout.
///
/// Both are keyed by stable display identity, never by array position or runtime
/// ID, so a preference survives replugs and reboots instead of sliding onto a
/// different monitor the next time the topology is enumerated.
public struct DisplayPreferences: Codable, Equatable, Sendable {
  /// Custom names keyed by stable ID. An empty string is treated as "no alias"
  /// and is never stored, so the map only ever holds names the user meant.
  public var aliases: [String: String]
  /// Explicit card order as a list of stable IDs. `nil` means "follow the
  /// physical layout"; a non-empty array pins the order and any display not
  /// listed is appended after it, sorted by physical position.
  public var manualOrder: [String]?

  public init(aliases: [String: String] = [:], manualOrder: [String]? = nil) {
    self.aliases = aliases
    self.manualOrder = manualOrder
  }

  public static let empty = DisplayPreferences()
}

/// Reads and writes the user's display presentation choices.
public protocol DisplayPreferencesStoring: Sendable {
  func loadPreferences() throws -> DisplayPreferences
  func savePreferences(_ preferences: DisplayPreferences) throws
}

/// The production store: one JSON file under Application Support, next to the
/// other DisplayDJ ledgers.
public final class FileDisplayPreferencesStore: DisplayPreferencesStoring {
  private let fileURL: URL
  private let fileManager: FileManager

  public init(
    fileURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.fileManager = fileManager

    if let fileURL {
      self.fileURL = fileURL
    } else {
      let base = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
      self.fileURL =
        (base ?? fileManager.temporaryDirectory)
        .appendingPathComponent("DisplayDJ", isDirectory: true)
        .appendingPathComponent("display-preferences.json", isDirectory: false)
    }
  }

  public func loadPreferences() throws -> DisplayPreferences {
    guard let data = fileManager.contents(atPath: fileURL.path) else {
      return .empty
    }

    guard !data.isEmpty else {
      return .empty
    }

    do {
      return try JSONDecoder().decode(DisplayPreferences.self, from: data)
    } catch {
      throw DisplayDJError(
        code: .internalFailure,
        message: "The saved display preferences could not be read.",
        operation: .read,
        details: [
          "phase": "preferences-load",
          "path": fileURL.path,
        ]
      )
    }
  }

  public func savePreferences(_ preferences: DisplayPreferences) throws {
    let directory = fileURL.deletingLastPathComponent()

    do {
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let data = try JSONEncoder().encode(preferences)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      throw DisplayDJError(
        code: .internalFailure,
        message: "The display preferences could not be saved.",
        operation: .write,
        details: [
          "phase": "preferences-save",
          "path": fileURL.path,
        ]
      )
    }
  }
}

/// An in-memory store used by tests and by callers that opt out of persistence.
public final class InMemoryDisplayPreferencesStore: DisplayPreferencesStoring {
  private let lock = NSLock()
  private var preferences: DisplayPreferences

  public init(preferences: DisplayPreferences = .empty) {
    self.preferences = preferences
  }

  public func loadPreferences() throws -> DisplayPreferences {
    lock.lock()
    defer { lock.unlock() }
    return preferences
  }

  public func savePreferences(_ newPreferences: DisplayPreferences) throws {
    lock.lock()
    defer { lock.unlock() }
    preferences = newPreferences
  }
}

/// A store that discards everything.
public struct NoOpDisplayPreferencesStore: DisplayPreferencesStoring {
  public init() {}

  public func loadPreferences() throws -> DisplayPreferences {
    .empty
  }

  public func savePreferences(_ preferences: DisplayPreferences) throws {}
}

extension FileDisplayPreferencesStore: @unchecked Sendable {}
extension InMemoryDisplayPreferencesStore: @unchecked Sendable {}
