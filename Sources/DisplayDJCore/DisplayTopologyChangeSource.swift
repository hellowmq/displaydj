import CoreGraphics
import Foundation

/// Reports displays arriving at and leaving the window server.
///
/// Separate from the code that reacts to those changes so the reaction can be
/// tested without a display being plugged in.
public protocol DisplayTopologyChangeSource: Sendable {
  func start(handler: @escaping @Sendable (DisplayTopologyChange) -> Void)
  func stop()
}

/// The production source: the public CoreGraphics reconfiguration callback.
///
/// Nothing here is private API. The callback is how macOS announces every
/// topology change, including the ones this tool causes itself.
public final class CGDisplayTopologyChangeSource: DisplayTopologyChangeSource {
  private let lock = NSLock()
  private var handler: (@Sendable (DisplayTopologyChange) -> Void)?

  public init() {}

  public func start(handler: @escaping @Sendable (DisplayTopologyChange) -> Void) {
    lock.lock()
    let needsRegistration = self.handler == nil
    self.handler = handler
    lock.unlock()

    guard needsRegistration else { return }

    CGDisplayRegisterReconfigurationCallback(
      reconfigurationCallback,
      Unmanaged.passUnretained(self).toOpaque()
    )
  }

  public func stop() {
    lock.lock()
    handler = nil
    lock.unlock()

    CGDisplayRemoveReconfigurationCallback(
      reconfigurationCallback,
      Unmanaged.passUnretained(self).toOpaque()
    )
  }

  fileprivate func emit(_ change: DisplayTopologyChange) {
    lock.lock()
    let handler = self.handler
    lock.unlock()
    handler?(change)
  }
}

extension CGDisplayTopologyChangeSource: @unchecked Sendable {}

/// A file-private C entry point. Being a function rather than a closure, it
/// captures nothing, so it can reach the source only through the context
/// pointer it is handed.
private func reconfigurationCallback(
  _ displayID: CGDirectDisplayID,
  _ flags: CGDisplayChangeSummaryFlags,
  _ context: UnsafeMutableRawPointer?
) {
  guard let context else { return }

  let source = Unmanaged<CGDisplayTopologyChangeSource>
    .fromOpaque(context)
    .takeUnretainedValue()

  guard let change = DisplayTopologyChangeDecoder.decode(runtimeID: displayID, flags: flags)
  else { return }

  source.emit(change)
}
