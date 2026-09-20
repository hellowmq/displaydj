import Foundation
import Testing
@testable import DisplayDJCore

struct HardwareProcessLockTests {
  actor Counter {
    var active = 0
    var peak = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
  }

  @Test func independentFileDescriptorsSerializeOperations() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let counter = Counter()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask {
          try await HardwareProcessLock.withLock(path: path) {
            await counter.enter()
            try await Task.sleep(for: .milliseconds(5))
            await counter.leave()
          }
        }
      }
      try await group.waitForAll()
    }
    #expect(await counter.peak == 1)
    #expect(await counter.active == 0)
  }

  @Test func thrownOperationReleasesLock() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    struct Failure: Error {}
    do {
      let _: Int = try await HardwareProcessLock.withLock(path: path) { throw Failure() }
      Issue.record("Expected error")
    } catch is Failure {}
    let result = try await HardwareProcessLock.withLock(path: path) { 7 }
    #expect(result == 7)
  }
}
