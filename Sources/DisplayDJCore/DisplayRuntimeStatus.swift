import CoreGraphics
import Foundation

/// What the window server currently says about one runtime display.
///
/// A protocol rather than direct CoreGraphics calls so that "the display came
/// back inactive" — the state a reconnect has to repair — can be tested
/// without hardware.
public protocol DisplayRuntimeStatusQuerying: Sendable {
  func isActive(runtimeID: UInt32) -> Bool
  func isMirrored(runtimeID: UInt32) -> Bool
}

public struct CoreGraphicsDisplayRuntimeStatus: DisplayRuntimeStatusQuerying {
  public init() {}

  /// Whether the display is drawing as part of the current configuration.
  ///
  /// A disabled display is present to the window server but inactive, which is
  /// exactly the signature a reconnect leaves behind when macOS restores a
  /// display it had been told to stop driving.
  public func isActive(runtimeID: UInt32) -> Bool {
    CGDisplayIsActive(runtimeID) != 0
  }

  /// Whether the display belongs to a mirror set.
  ///
  /// Enabling one member of a mirror set rewrites the mirror set rather than
  /// restoring a single screen, so mirrored displays are never touched.
  public func isMirrored(runtimeID: UInt32) -> Bool {
    CGDisplayIsInMirrorSet(runtimeID) != 0
      || CGDisplayMirrorsDisplay(runtimeID) != kCGNullDirectDisplay
  }
}
