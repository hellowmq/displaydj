import Testing
@testable import DisplayDJBar

@Test func softwareDimmingValuesStayWithTheirDisplays() {
  var levels = SoftwareDimmingLevels()
  #expect(levels.value(for: "first") == nil)

  levels.set(72, for: "first")
  levels.set(91, for: "second")
  #expect(levels.value(for: "first") == 72)
  #expect(levels.value(for: "second") == 91)

  levels.invalidate("first")
  #expect(levels.value(for: "first") == nil)
  #expect(levels.value(for: "second") == 91)
}
