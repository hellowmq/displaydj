import Foundation
import Testing

@testable import DisplayDJCore

/// The user's aliases and manual card order are only useful if they outlive the
/// process — a pinned order that resets on every launch is no order at all.
@Suite("Display preferences persist and reload")
struct DisplayPreferencesStoreTests {
  private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("displaydj-prefs-\(UUID().uuidString).json")
  }

  @Test func fileRoundTripsAliasesAndOrder() throws {
    let store = FileDisplayPreferencesStore(fileURL: tempFile())
    let prefs = DisplayPreferences(aliases: ["s1": "右屏"], manualOrder: ["s1", "s2"])

    try store.savePreferences(prefs)
    let loaded = try store.loadPreferences()

    #expect(loaded == prefs)
    #expect(loaded.aliases["s1"] == "右屏")
    #expect(loaded.manualOrder == ["s1", "s2"])
  }

  @Test func missingFileReadsAsEmpty() throws {
    let store = FileDisplayPreferencesStore(fileURL: tempFile())

    let loaded = try store.loadPreferences()

    #expect(loaded == .empty)
  }

  @Test func inMemoryStoreRoundTrips() throws {
    let store = InMemoryDisplayPreferencesStore(
      preferences: DisplayPreferences(aliases: ["s1": "右屏"])
    )

    let loaded = try store.loadPreferences()

    #expect(loaded.aliases["s1"] == "右屏")
  }

  @Test func noOpStoreDiscardsWrites() throws {
    let store = NoOpDisplayPreferencesStore()

    try store.savePreferences(DisplayPreferences(aliases: ["s1": "右屏"]))
    let loaded = try store.loadPreferences()

    #expect(loaded == .empty)
  }
}
