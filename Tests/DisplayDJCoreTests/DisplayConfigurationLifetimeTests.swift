import CoreGraphics
import Testing
@testable import DisplayDJCore

@Suite("Display configuration lifetime, with no WindowServer calls")
struct DisplayConfigurationLifetimeTests {
  @Test func liteDisableIsApplicationScopedAndReconnectClearsSessionBaseline() throws {
    var options: [CGConfigureOption] = []
    var changes: [Bool] = []
    let transaction = CGSConnectionTransaction(disconnectionLifetime: .application,
      begin: { $0 = OpaquePointer(bitPattern: 1); return .success },
      configure: { _, id, enabled in
        #expect(id == 42)
        changes.append(enabled)
        return 0
      }, complete: { _, option in options.append(option); return .success })
    try transaction.setEnabled(false, forRuntimeID: 42)
    try transaction.setEnabled(true, forRuntimeID: 42)
    #expect(changes == [false, true])
    #expect(options == [.forAppOnly, .forSession])
  }

  @Test func fullCLIStillKeepsChangesForTheLoginSession() throws {
    var options: [CGConfigureOption] = []
    let transaction = CGSConnectionTransaction(disconnectionLifetime: .loginSession,
      begin: { $0 = OpaquePointer(bitPattern: 1); return .success },
      configure: { _, _, _ in 0 },
      complete: { _, option in options.append(option); return .success })
    try transaction.setEnabled(false, forRuntimeID: 42)
    try transaction.setEnabled(true, forRuntimeID: 42)
    #expect(options == [.forSession, .forSession])
  }

  @Test func failedPrivateCallStillCompletesItsApplicationScopedTransaction() {
    var completed = false
    let transaction = CGSConnectionTransaction(disconnectionLifetime: .application,
      begin: { $0 = OpaquePointer(bitPattern: 1); return .success },
      configure: { _, _, _ in -1 }, complete: { _, option in
        completed = true
        #expect(option == .forAppOnly)
        return .success
      })
    #expect(throws: DisplayDJError.self) { try transaction.setEnabled(false, forRuntimeID: 42) }
    #expect(completed)
  }

  @Test func beginFailureDoesNotTouchARealOrFakeDisplay() {
    let transaction = CGSConnectionTransaction(disconnectionLifetime: .application,
      begin: { _ in .failure },
      configure: { _, _, _ in Issue.record("Unexpected configure"); return 0 },
      complete: { _, _ in Issue.record("Unexpected completion"); return .success })
    #expect(throws: DisplayDJError.self) { try transaction.setEnabled(false, forRuntimeID: 42) }
  }
}
