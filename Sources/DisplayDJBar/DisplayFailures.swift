/// Where failures live: one slot per display, plus one for the topology itself.
///
/// Every attached monitor has its own card on screen and fails on its own schedule, so a
/// single shared slot cannot represent the truth. When the polling loop failed on two
/// displays in the same pass, the second failure overwrote the first before it had ever been
/// drawn — and with it the retry button that was that display's only way out. Which failure
/// the user saw depended on enumeration order.
///
/// A scan failure belongs to no single display, so it is kept apart rather than filed under
/// an arbitrary one.
struct DisplayFailures: Equatable {
  private var byDisplay: [String: BrightnessFailure] = [:]

  /// A failure of the topology as a whole, such as a failed enumeration.
  var topology: BrightnessFailure?

  /// The failure currently shown on one display's card.
  ///
  /// Addressed by stable ID rather than by "the selected display": any card can fail while
  /// another is selected, and a banner filed under the wrong display would offer its retry
  /// against a monitor the user never touched.
  subscript(stableID: String) -> BrightnessFailure? {
    get { byDisplay[stableID] }
    set { byDisplay[stableID] = newValue }
  }

  /// Forgets every failure. Used when the topology changed so completely that none of the
  /// recorded failures can still be attributed.
  mutating func clearAll() {
    byDisplay = [:]
    topology = nil
  }

  /// Drops failures for displays that are no longer attached, keeping every attached one.
  ///
  /// A detached display has no card left to show its banner on, but its neighbours' banners
  /// are still true and must survive the rescan.
  mutating func prune(keeping liveIDs: Set<String>) {
    byDisplay = byDisplay.filter { liveIDs.contains($0.key) }
  }
}
