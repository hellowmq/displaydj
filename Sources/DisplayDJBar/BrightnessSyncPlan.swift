/// One user change, copied as the same percentage-point change to each other
/// physical display. A complete set of confirmed readings is required before
/// submitting any intent, so a missing DDC baseline cannot silently split a
/// synchronized gesture.
enum BrightnessSyncPlan {
  static func intents(
    sourceID: String,
    target: Int,
    orderedIDs: [String],
    current: [String: Int]
  ) -> [BrightnessIntent]? {
    guard orderedIDs.count > 1,
      Set(orderedIDs).count == orderedIDs.count,
      orderedIDs.contains(sourceID),
      let sourceValue = current[sourceID],
      orderedIDs.allSatisfy({ current[$0] != nil })
    else { return nil }

    let change = target - sourceValue
    return [BrightnessIntent(value: target, displayStableID: sourceID)]
      + orderedIDs.filter { $0 != sourceID }.map { id in
        BrightnessIntent(
          value: min(100, max(0, current[id]! + change)),
          displayStableID: id
        )
      }
  }
}
