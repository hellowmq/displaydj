import Testing

@testable import DisplayDJBar

// Keeping the keyboard observers in step with a permission that changes after they are made.
//
// A global key observer is granted its privileges when it is created. One created without
// accessibility trust is a valid, retained object that silently never fires, and it does not
// start firing when trust arrives later — nothing about the existing observer changes.
//
// The app already re-reads the trust on every popover open, precisely because the user may have
// changed it in System Settings meanwhile. That re-read drove the on-screen notice and nothing
// else, so granting trust *removed the explanation* while leaving the shortcut just as dead.

// MARK: - The defect

@Test("Trust granted after the observer was made forces it to be re-created")
func trustGrantedAfterInstallReinstallsTheObserver() {
  // The regression, stated as the state it happens in: opted in, installed while untrusted,
  // trusted now. Before the fix this case returned "nothing to do" and the shortcut stayed
  // dead for the rest of the process's life.
  let action = HotkeyObservers.action(
    hotkeysEnabled: true,
    installedWithTrust: false,
    isTrustedNow: true
  )
  #expect(action == .reinstallGlobalObserver)
}

// MARK: - Guards against over-correction

@Test("An observer already created under trust is left alone")
func trustedObserverIsNotChurned() {
  // Not over-corrected into "reinstall on every trust read". `refreshAccessibilityPermission`
  // runs on every popover open, so tearing down a working observer each time would drop key
  // events for the gap and make the repair itself the new defect.
  let action = HotkeyObservers.action(
    hotkeysEnabled: true,
    installedWithTrust: true,
    isTrustedNow: true
  )
  #expect(action == .keepExisting)
}

@Test("Trust rising never installs an observer the user did not opt into")
func trustDoesNotImplyConsent() {
  // PRD 1.2: nothing observes the keyboard until the user turns it on. Trust becoming
  // available is the system saying the app *may* listen, never that the user asked it to —
  // and with the hotkeys off there is no observer in existence to repair anyway.
  for installedWithTrust in [true, false] {
    for isTrustedNow in [true, false] {
      let action = HotkeyObservers.action(
        hotkeysEnabled: false,
        installedWithTrust: installedWithTrust,
        isTrustedNow: isTrustedNow
      )
      #expect(action == .keepExisting)
    }
  }
}

@Test("Trust that has been revoked does not trigger a pointless re-install")
func revokedTrustDoesNotReinstall() {
  // A replacement created without trust would be just as dead as the one it replaced, so
  // reinstalling here buys nothing and only drops events during the swap. The caller records
  // the fall instead, which is what lets a later grant read as a rise.
  let action = HotkeyObservers.action(
    hotkeysEnabled: true,
    installedWithTrust: true,
    isTrustedNow: false
  )
  #expect(action == .keepExisting)
}

@Test("Untrusted throughout leaves the observer as it is")
func untrustedThroughoutIsLeftAlone() {
  // The state the user sits in before granting anything. There is nothing to repair yet, and
  // the popover's permission notice is what accounts for the shortcut in the meantime.
  let action = HotkeyObservers.action(
    hotkeysEnabled: true,
    installedWithTrust: false,
    isTrustedNow: false
  )
  #expect(action == .keepExisting)
}

// MARK: - The rule as a whole

@Test("The full truth table, so re-widening or narrowing the rule fails here")
func actionIsStatedAsAnExhaustiveTable() {
  // Written out in full because both failure directions are silent: too narrow leaves a dead
  // observer that looks alive, too wide churns a live one. Neither shows up in a build.
  struct Case {
    let hotkeysEnabled: Bool
    let installedWithTrust: Bool
    let isTrustedNow: Bool
    let expected: HotkeyObserverAction
  }
  let cases = [
    Case(
      hotkeysEnabled: false, installedWithTrust: false, isTrustedNow: false,
      expected: .keepExisting),
    Case(
      hotkeysEnabled: false, installedWithTrust: false, isTrustedNow: true,
      expected: .keepExisting),
    Case(
      hotkeysEnabled: false, installedWithTrust: true, isTrustedNow: false,
      expected: .keepExisting),
    Case(
      hotkeysEnabled: false, installedWithTrust: true, isTrustedNow: true,
      expected: .keepExisting),
    Case(
      hotkeysEnabled: true, installedWithTrust: false, isTrustedNow: false,
      expected: .keepExisting),
    Case(
      hotkeysEnabled: true, installedWithTrust: false, isTrustedNow: true,
      expected: .reinstallGlobalObserver),
    Case(
      hotkeysEnabled: true, installedWithTrust: true, isTrustedNow: false,
      expected: .keepExisting),
    Case(
      hotkeysEnabled: true, installedWithTrust: true, isTrustedNow: true,
      expected: .keepExisting),
  ]
  for testCase in cases {
    let action = HotkeyObservers.action(
      hotkeysEnabled: testCase.hotkeysEnabled,
      installedWithTrust: testCase.installedWithTrust,
      isTrustedNow: testCase.isTrustedNow
    )
    #expect(action == testCase.expected)
  }
}

@Test("Re-installation is the only state in which the rule asks for an observer to change")
func reinstallIsReachableFromExactlyOneState() {
  // Pins the claim the fix rests on: exactly one of the eight states is a repair. If a future
  // change makes a second state reinstall, that is a churn bug and it fails here rather than
  // being discovered as dropped keystrokes.
  var reinstallCount = 0
  for hotkeysEnabled in [true, false] {
    for installedWithTrust in [true, false] {
      for isTrustedNow in [true, false] {
        let action = HotkeyObservers.action(
          hotkeysEnabled: hotkeysEnabled,
          installedWithTrust: installedWithTrust,
          isTrustedNow: isTrustedNow
        )
        if action == .reinstallGlobalObserver { reinstallCount += 1 }
      }
    }
  }
  #expect(reinstallCount == 1)
}
