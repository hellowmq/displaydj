import DisplayDJCore
import Foundation

/// The "disconnected" list the popover shows, derived from the saved records.
enum DisplayConnectionList {
  /// Records that still describe a display that is absent from the topology.
  ///
  /// Records outlive what they describe: a display can be disconnected, unplugged,
  /// and plugged back in, and runtime IDs are reassigned. A record left pointing at
  /// a number some other display has since inherited would offer a "reconnect"
  /// aimed at one monitor that drives another, so anything whose runtime ID is
  /// online again is dropped rather than shown.
  ///
  /// Oldest first, so the list does not reshuffle under the pointer between
  /// refreshes.
  static func resolve(
    records: [DisplayConnectionRecord],
    onlineRuntimeIDs: Set<UInt32>
  ) -> [DisplayConnectionRecord] {
    records
      .filter { !onlineRuntimeIDs.contains($0.runtimeID) }
      .sorted { $0.disconnectedAt < $1.disconnectedAt }
  }

  /// The key a disconnected display is filed under while it is away.
  ///
  /// Stated once because two places need it and they have to agree: the act of
  /// reconnecting files its outcome under this key, and the row that shows that
  /// outcome looks it up by the same one. A display with no stable ID has no
  /// other identity here, so the runtime key is the only thing both sides can
  /// name.
  static func key(for runtimeID: UInt32) -> String {
    DisplaySelection.runtimeKeyPrefix + String(runtimeID)
  }
}
