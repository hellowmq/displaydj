import Foundation
import Testing

@testable import DisplayDJCore

/// A declared display change has to survive the process boundary.
///
/// The menu bar app and a one-shot CLI invocation are separate processes, and a
/// disable applied by either emits a topology event the other receives. When the
/// ledger was held in memory alone, the app's watcher saw the removal the CLI
/// caused, found no intent of its own, and deleted the record the CLI had just
/// written — leaving the display dark with the only thing that could bring it
/// back already gone.
@Suite("A declared display change survives the process boundary")
struct DisplayConnectionIntentLedgerTests {
  /// A clock the test moves by hand. A class rather than a captured `var`
  /// because the ledger's `now` closure is `@Sendable`.
  private final class Clock: @unchecked Sendable {
    var now = Date()
  }

  private func temporaryStore(
    name: String = UUID().uuidString
  ) -> FileDisplayConnectionIntentStore {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("displaydj-intent-\(name)", isDirectory: false)
    return FileDisplayConnectionIntentStore(fileURL: url)
  }

  @Test func intentNotedByTheCLIIsVisibleToTheMenuBarWatcher() {
    let store = temporaryStore()
    let cli = DisplayConnectionIntentLedger(store: store)
    let menuBar = DisplayConnectionIntentLedger(store: store)

    cli.noteIntent(runtimeID: 7)

    #expect(menuBar.isSuppressed(runtimeID: 7))
  }

  @Test func intentNotedByTheMenuBarIsVisibleToTheCLI() {
    let store = temporaryStore()
    let menuBar = DisplayConnectionIntentLedger(store: store)
    let cli = DisplayConnectionIntentLedger(store: store)

    menuBar.noteIntent(runtimeID: 11)

    #expect(cli.isSuppressed(runtimeID: 11))
  }

  /// A ledger with no store is still process-local, which is what the unit tests
  /// of the release rules rely on: they must not see each other's intents.
  @Test func inMemoryLedgerStaysInsideItsOwnProcess() {
    let cli = DisplayConnectionIntentLedger()
    let menuBar = DisplayConnectionIntentLedger()

    cli.noteIntent(runtimeID: 7)

    #expect(cli.isSuppressed(runtimeID: 7))
    #expect(!menuBar.isSuppressed(runtimeID: 7))
  }

  @Test func suppressionEndsWhenTheGraceWindowCloses() {
    let store = temporaryStore()
    let clock = Clock()
    let writer = DisplayConnectionIntentLedger(
      store: store,
      graceInterval: 3,
      now: { clock.now }
    )
    let watcher = DisplayConnectionIntentLedger(
      store: store,
      graceInterval: 3,
      now: { clock.now }
    )

    writer.noteIntent(runtimeID: 7)
    #expect(watcher.isSuppressed(runtimeID: 7))

    // Still inside the window: an event that arrives late is still this tool's.
    clock.now = clock.now.addingTimeInterval(2)
    #expect(watcher.isSuppressed(runtimeID: 7))

    clock.now = clock.now.addingTimeInterval(2)
    #expect(!watcher.isSuppressed(runtimeID: 7))
  }

  /// Two processes acting on two different displays must not withdraw each
  /// other's intent, which a blind overwrite of the file would do.
  @Test func notingOneDisplayKeepsAnotherOnesIntent() {
    let store = temporaryStore()
    let cli = DisplayConnectionIntentLedger(store: store)
    let menuBar = DisplayConnectionIntentLedger(store: store)

    cli.noteIntent(runtimeID: 7)
    menuBar.noteIntent(runtimeID: 9)

    #expect(cli.isSuppressed(runtimeID: 7))
    #expect(cli.isSuppressed(runtimeID: 9))
  }

  /// Expired entries are dropped on write, so the file cannot grow without bound
  /// and a stale intent cannot suppress a genuine unplug forever.
  @Test func savingAnIntentDiscardsExpiredOnes() throws {
    let store = temporaryStore()
    let clock = Clock()
    let ledger = DisplayConnectionIntentLedger(
      store: store,
      graceInterval: 3,
      now: { clock.now }
    )

    ledger.noteIntent(runtimeID: 7)
    clock.now = clock.now.addingTimeInterval(10)
    ledger.noteIntent(runtimeID: 9)

    let saved = try store.loadIntents()
    #expect(saved[7] == nil)
    #expect(saved[9] != nil)
  }

  /// An unreadable file must not be mistaken for "no intent declared": it says
  /// nothing, so nothing is suppressed and the watcher keeps guarding.
  @Test func unreadableStoreSuppressesNothingAndDoesNotThrow() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("displaydj-intent-broken-\(UUID().uuidString)", isDirectory: false)
    try Data("not json".utf8).write(to: url)
    let ledger = DisplayConnectionIntentLedger(
      store: FileDisplayConnectionIntentStore(fileURL: url)
    )

    #expect(!ledger.isSuppressed(runtimeID: 7))

    // And it recovers on the next declared intent rather than staying broken.
    ledger.noteIntent(runtimeID: 7)
    #expect(ledger.isSuppressed(runtimeID: 7))
  }
}
