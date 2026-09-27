import Testing

@testable import DisplayDJBar

@Suite("Opt-in brightness synchronization")
struct BrightnessSyncPlanTests {
  @Test func keepsEachDisplayOffsetAndClamps() {
    let plan = BrightnessSyncPlan.intents(
      sourceID: "built-in", target: 62,
      orderedIDs: ["built-in", "hp", "other"],
      current: ["built-in": 50, "hp": 56, "other": 95]
    )
    #expect(plan == [
      BrightnessIntent(value: 62, displayStableID: "built-in"),
      BrightnessIntent(value: 68, displayStableID: "hp"),
      BrightnessIntent(value: 100, displayStableID: "other"),
    ])
  }

  @Test func missingFollowerBaselineRejectsTheWholePlan() {
    #expect(BrightnessSyncPlan.intents(
      sourceID: "built-in", target: 52,
      orderedIDs: ["built-in", "hp"], current: ["built-in": 50]
    ) == nil)
  }

  @Test func repeatedOrUnknownIdentitiesCannotSelectAnotherPanel() {
    #expect(BrightnessSyncPlan.intents(
      sourceID: "unknown", target: 60,
      orderedIDs: ["built-in", "hp"], current: ["built-in": 50, "hp": 56]
    ) == nil)
    #expect(BrightnessSyncPlan.intents(
      sourceID: "hp", target: 60,
      orderedIDs: ["hp", "hp"], current: ["hp": 56]
    ) == nil)
  }
}
