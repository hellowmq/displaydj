import Darwin
import DisplayDJCore
import Foundation

/// A child of this App, started and acknowledged before the first disconnect.
/// It survives the GUI's abrupt death, restores only Lite's exact saved targets,
/// then exits. No LaunchAgent, login item, or additional installed executable.
actor LiteRecoveryGuardian {
  private var process: Process?

  func ensureStarted() throws {
    if process?.isRunning == true { return }
    guard let executable = Bundle.main.executableURL else {
      throw LiteRefusal("无法启动退出恢复保护，未断开显示器。")
    }
    let ready = Pipe()
    let child = Process()
    child.executableURL = executable
    child.arguments = ["--recovery-guardian", String(getpid())]
    child.standardOutput = ready
    child.standardInput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try child.run()
    ready.fileHandleForWriting.closeFile()
    defer { ready.fileHandleForReading.closeFile() }
    var descriptor = pollfd(fd: ready.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
    guard poll(&descriptor, 1, 5_000) > 0,
          (try? ready.fileHandleForReading.read(upToCount: 6)) == Data("READY\n".utf8), child.isRunning else {
      if child.isRunning { child.terminate() }
      throw LiteRefusal("退出恢复保护尚未就绪，未断开显示器。请重试。")
    }
    process = child
  }

  @MainActor
  static func run(parentPID: pid_t) async -> Int32 {
    guard parentPID > 1, getppid() == parentPID else { return 2 }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let source = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .global())
      source.setRegistrationHandler {
        FileHandle.standardOutput.write(Data("READY\n".utf8))
      }
      source.setEventHandler {
        source.cancel()
        continuation.resume()
      }
      source.resume()
    }
    // Allow an in-flight WindowServer transaction from the parent to settle.
    try? await Task.sleep(for: .milliseconds(500))
    return await restoreAfterParentExit(access: LiteConnectionService.live()) ? 0 : 1
  }

  static func restoreAfterParentExit(access: any LiteConnectionAccess) async -> Bool {
    for attempt in 0..<3 {
      do {
        let snapshot = try await access.snapshot()
        for record in snapshot.pendingRecords {
          guard let id = LiteIdentity.stableID(record.stableID) else { return false }
          let result = try await access.change(.connected, stableID: id)
          guard result.wasVerified, result.observedState == .connected else { return false }
        }
        if try await access.snapshot().pendingRecords.isEmpty { return true }
      } catch {
        // Keep records after failure; a fresh retry revalidates identity first.
      }
      if attempt < 2 { try? await Task.sleep(for: .seconds(1)) }
    }
    return false
  }
}
