/// One user change, copied as the same percentage-point change to each other
/// physical display. A complete set of confirmed readings is required before
/// submitting any intent, so a missing DDC baseline cannot silently split a
/// synchronized gesture.
enum BrightnessSyncPlan {
  /// Coalescing a key burst must preserve each screen's saturation at every step.
  /// For example 98 + 5 - 5 ends at 95, not 98; applying only the net delta loses that.
  static func intents(sourceID: String, steps: [Int], orderedIDs: [String],
                      current: [String: Int]) -> [BrightnessIntent]? {
    var values = current
    var result: [BrightnessIntent]?
    for step in steps {
      guard let source = values[sourceID],
            let plan = intents(sourceID: sourceID, target: min(100, max(0, source + step)),
                               orderedIDs: orderedIDs, current: values) else { return nil }
      result = plan
      for intent in plan { values[intent.displayStableID] = intent.value }
    }
    return result
  }

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
