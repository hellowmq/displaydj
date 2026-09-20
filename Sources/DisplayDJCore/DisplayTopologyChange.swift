import CoreGraphics
import Foundation

/// A physical display arriving at, or leaving, the window server.
///
/// "Physical" is the point: these are the events a cable produces. They are
/// deliberately indistinguishable, at the CoreGraphics level, from the events
/// this tool produces when it disables a display — which is why the identity of
/// the caller matters (see `DisplayConnectionIntentLedger`).
public struct DisplayTopologyChange: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    case added
    case removed
  }

  public let runtimeID: UInt32
  public let kind: Kind

  public init(runtimeID: UInt32, kind: Kind) {
    self.runtimeID = runtimeID
    self.kind = kind
  }
}

/// Reduces raw reconfiguration flags to the single change they describe.
///
/// A reconfiguration arrives twice per change — once announced, once completed —
/// and carries many flags that say nothing about a display arriving or leaving.
/// Acting on the announcement, or on a mode change, would release a disable that
/// nothing had physically disturbed.
public enum DisplayTopologyChangeDecoder {
  /// - Returns: `nil` when the flags describe no arrival or departure, or
  ///   describe both at once. An ambiguous change is never guessed at.
  public static func decode(
    runtimeID: UInt32,
    flags: CGDisplayChangeSummaryFlags
  ) -> DisplayTopologyChange? {
    guard !flags.contains(.beginConfigurationFlag) else { return nil }

    let wasAdded = flags.contains(.addFlag)
    let wasRemoved = flags.contains(.removeFlag)

    guard wasAdded != wasRemoved else { return nil }

    return DisplayTopologyChange(
      runtimeID: runtimeID,
      kind: wasAdded ? .added : .removed
    )
  }
}
