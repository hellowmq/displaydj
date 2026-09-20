import Testing

@testable import DisplayDJBar

// MARK: - The gate the popover state actually governs

@Test("A card refresh is refused while the popover is closed")
func popoverContentReadIsGatedByVisibility() {
  #expect(ReadTrigger.popoverContent.allowsRead(popoverIsVisible: true))
  #expect(ReadTrigger.popoverContent.allowsRead(popoverIsVisible: false) == false)
}

@Test("A user request is read whether or not the popover is open")
func userRequestIsNeverGatedByVisibility() {
  // The regression this asserts against: hotkeys are usable with the popover closed, and
  // routing their read through the polling gate refused it in exactly that state — so the
  // shortcut the user opted into did nothing at all.
  #expect(ReadTrigger.userRequest.allowsRead(popoverIsVisible: false))
  #expect(ReadTrigger.userRequest.allowsRead(popoverIsVisible: true))
}

@Test("Visibility is the only thing that separates the two triggers")
func triggersDifferOnlyWhenPopoverIsClosed() {
  // With the popover open both must read, so a test that only ever opens it cannot tell the
  // two apart — which is why the defect survived: the popover is open in every manual check.
  #expect(
    ReadTrigger.popoverContent.allowsRead(popoverIsVisible: true)
      == ReadTrigger.userRequest.allowsRead(popoverIsVisible: true)
  )
  #expect(
    ReadTrigger.popoverContent.allowsRead(popoverIsVisible: false)
      != ReadTrigger.userRequest.allowsRead(popoverIsVisible: false)
  )
}

@Test("The default trigger keeps the polling restriction in force")
func defaultTriggerStillForbidsBackgroundPolling() {
  // `refreshDisplay` defaults to `.popoverContent`, so every existing caller keeps the
  // behaviour the polling rules require: no unattended DDC traffic once the popover closes.
  // Only the paths that deliberately opt into `.userRequest` are exempt.
  let routine = ReadTrigger.popoverContent
  #expect(routine.allowsRead(popoverIsVisible: false) == false)
}

@Test("Neither trigger invents a third state")
func triggersAreExhaustive() {
  // A trigger that read on neither setting would be dead weight, and one that read on both
  // would make the gate meaningless. Each must be distinguishable by its answers alone.
  let all: [ReadTrigger] = [.popoverContent, .userRequest]
  let answers = all.map { trigger in
    [trigger.allowsRead(popoverIsVisible: true), trigger.allowsRead(popoverIsVisible: false)]
  }
  #expect(Set(answers.map(\.description)).count == all.count)
  #expect(answers.allSatisfy { $0.contains(true) })
}
