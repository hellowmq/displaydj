import Testing

@testable import DisplayDJBar

// The menu bar item: the sun icon, and nothing else.
//
// The status item used to draw the selected display's brightness as a number. That figure is a
// poor menu-bar citizen: it goes stale because polling stops when the popover is closed (the
// state the item lives in almost always), and it is meaningless with more than one display
// attached, because it cannot name its display. Both are avoided by drawing the icon alone.
// VoiceOver still gets a label that names the app and the display count, so the item is never
// unidentified and never announces a value that may belong to the wrong screen.

// MARK: - Presentation

@Test("The menu bar title is always empty — icon only, no number")
func statusItemTitleIsAlwaysEmpty() {
  for count in [0, 1, 2, 5] {
    let presentation = StatusItemTitle.presentation(displaysCount: count)
    #expect(presentation.title.isEmpty)
    #expect(presentation.showsNumber == false)
  }
}

@Test("The icon never has to make room for text")
func statusItemLayoutIsIconOnly() {
  #expect(StatusItemTitle.presentation(displaysCount: 1).showsNumber == false)
  #expect(StatusItemTitle.presentation(displaysCount: 2).showsNumber == false)
}

// MARK: - What the item says

@Test("The label names the app for any display count")
func statusItemLabelNamesTheApp() {
  for count in [0, 1, 2] {
    let label = StatusItemTitle.presentation(displaysCount: count).accessibilityLabel
    #expect(label.contains(BrightnessAccessibility.statusItemName))
  }
}

@Test("The label reports the display count rather than a single brightness")
func statusItemLabelReportsCount() {
  #expect(StatusItemTitle.presentation(displaysCount: 0).accessibilityLabel.contains("未连接显示器"))
  #expect(StatusItemTitle.presentation(displaysCount: 1).accessibilityLabel.contains("1 台显示器"))
  #expect(StatusItemTitle.presentation(displaysCount: 2).accessibilityLabel.contains("2 台显示器"))
}

@Test("The label is never empty, whatever the count")
func statusItemLabelIsNeverEmpty() {
  for count in [0, 1, 2, 10] {
    let label = StatusItemTitle.presentation(displaysCount: count).accessibilityLabel
    #expect(label.trimmingCharacters(in: .whitespaces).isEmpty == false)
  }
}

@Test("The label never announces a single brightness value")
func statusItemLabelCarriesNoSingleValue() {
  // Guarding the regression in the other direction: with no number on screen, VoiceOver must
  // not invent one either — a single figure would be ambiguous across displays.
  let label = StatusItemTitle.presentation(displaysCount: 2).accessibilityLabel
  #expect(label.contains("%") == false)
}
