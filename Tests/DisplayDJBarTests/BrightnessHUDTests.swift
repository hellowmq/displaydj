import Testing
@testable import DisplayDJBar

@Test("Continuous adjustments retain the visible value during each fresh hardware read")
func hudRepeatDoesNotFlashReading() {
  var visible: BrightnessHUDContent?
  let states: [BrightnessHUDContent.State] = [.reading, .changing(55), .confirmed(54),
    .reading, .changing(59), .confirmed(58), .reading]
  var values: [Int?] = []
  var captions: [String] = []
  for state in states {
    visible = BrightnessHUDContent(runtimeID: 1, name: "Display", state: state)
      .presentation(after: visible)
    values.append(visible?.value)
    captions.append(visible!.caption)
  }
  #expect(values == [nil, 55, 54, 54, 59, 58, 58])
  #expect(Set(captions.dropFirst()) == ["硬件亮度"])
}

@Test("Errors replace the retained value and a retry without a value shows reading")
func hudErrorRemainsVisible() {
  let confirmed = BrightnessHUDContent(runtimeID: 1, name: "A", state: .confirmed(55))
  let failed = BrightnessHUDContent(runtimeID: 1, name: "A", state: .failed("读取失败"))
    .presentation(after: confirmed)
  #expect(failed.isFailure)
  #expect(failed.value == nil)
  #expect(failed.caption == "读取失败")
  let retry = BrightnessHUDContent(runtimeID: 1, name: "A", state: .reading)
    .presentation(after: failed)
  #expect(retry.state == .reading)
}

@Test("A fresh or different screen HUD cannot borrow an old display value")
func hudReadingWithoutVisibleBaseline() {
  let old = BrightnessHUDContent(runtimeID: 1, name: "A", state: .confirmed(80))
  let reading = BrightnessHUDContent(runtimeID: 2, name: "B", state: .reading)
  #expect(reading.presentation(after: old).state == .reading)
  #expect(reading.presentation(after: nil).state == .reading)
}
