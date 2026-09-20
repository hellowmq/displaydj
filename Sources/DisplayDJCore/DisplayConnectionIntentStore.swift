import Foundation

/// Persists the moments this tool announced a display change on purpose.
///
/// The ledger only earns its keep across process boundaries: the menu bar app
/// and a one-shot CLI invocation are separate processes, and a disable applied
/// by one emits a topology event the other receives. Held in memory alone, the
/// watcher in the app has no way to know that the removal it just saw was this
/// tool's own doing, so it reads it as a physical unplug and deletes the record
/// that the CLI had only just written — leaving the display dark with the one
/// thing that could bring it back already gone.
public protocol DisplayConnectionIntentStoring: Sendable {
  func loadIntents() throws -> [UInt32: Date]
  func saveIntents(_ intents: [UInt32: Date]) throws
}

/// The production store: one JSON file next to the disconnect records.
///
/// Runtime IDs are written as strings because JSON object keys are strings and
/// `UInt32` would otherwise arrive as a number the decoder cannot key a
/// dictionary by without a lossy round trip.
public final class FileDisplayConnectionIntentStore: DisplayConnectionIntentStoring {
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
        .appendingPathComponent("connection-intents.json", isDirectory: false)
    }
  }

  public func loadIntents() throws -> [UInt32: Date] {
    guard let data = fileManager.contents(atPath: fileURL.path) else {
      return [:]
    }

    guard !data.isEmpty else {
      return [:]
    }

    do {
      let payload = try JSONDecoder().decode(Payload.self, from: data)
      var intents: [UInt32: Date] = [:]
      for (key, moment) in payload.intents {
        guard let runtimeID = UInt32(key) else { continue }
        intents[runtimeID] = Date(timeIntervalSince1970: moment)
      }
      return intents
    } catch {
      throw DisplayDJError(
        code: .internalFailure,
        message: "The saved display-change intent could not be read.",
        operation: .read,
        details: [
          "phase": "intent-load",
          "path": fileURL.path,
        ]
      )
    }
  }

  public func saveIntents(_ intents: [UInt32: Date]) throws {
    var encoded: [String: Double] = [:]
    for (runtimeID, moment) in intents {
      encoded[String(runtimeID)] = moment.timeIntervalSince1970
    }

    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let data = try JSONEncoder().encode(Payload(intents: encoded))
      try data.write(to: fileURL, options: .atomic)
    } catch {
      throw DisplayDJError(
        code: .internalFailure,
        message: "The display-change intent could not be saved.",
        operation: .write,
        details: [
          "phase": "intent-save",
          "path": fileURL.path,
        ]
      )
    }
  }

  private struct Payload: Codable {
    let intents: [String: Double]
  }
}

/// An in-memory store for tests and for callers that opt out of sharing.
public final class InMemoryDisplayConnectionIntentStore: DisplayConnectionIntentStoring {
  private let lock = NSLock()
  private var intents: [UInt32: Date]

  public init(intents: [UInt32: Date] = [:]) {
    self.intents = intents
  }

  public func loadIntents() throws -> [UInt32: Date] {
    lock.lock()
    defer { lock.unlock() }
    return intents
  }

  public func saveIntents(_ newIntents: [UInt32: Date]) throws {
    lock.lock()
    defer { lock.unlock() }
    intents = newIntents
  }
}

extension FileDisplayConnectionIntentStore: @unchecked Sendable {}

extension InMemoryDisplayConnectionIntentStore: @unchecked Sendable {}
