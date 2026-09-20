import Testing

@testable import DisplayDJBar

/// Whether the popover may offer to stop output to a display at all.
///
/// Asked before the button is pressed, not after: the window server refuses the
/// same cases, but by then the user has already made the gesture and all they
/// get is an error. Every case below is knowable from numbers the UI already
/// holds, which is why this rule is stated as a pure function and tested without
/// a window server.
@Suite("Whether a display can be disconnected from the menu bar")
struct DisplayConnectionAvailabilityTests {
  @Test func availableWhenMoreThanOneDisplayIsOnline() {
    let state = DisplayConnectionAvailabilityResolver.resolve(
      isSupported: true,
      onlineCount: 2,
      isMirrored: false
    )

    #expect(state == .available)
    #expect(state.canDisconnect)
    // An enabled control must not carry an explanation for being disabled.
    #expect(state.guidance == nil)
  }

  @Test func theLastOnlineDisplayIsNeverOffered() {
    let state = DisplayConnectionAvailabilityResolver.resolve(
      isSupported: true,
      onlineCount: 1,
      isMirrored: false
    )

    #expect(state == .lastOnlineDisplay)
    #expect(!state.canDisconnect)
    #expect(state.guidance != nil)
  }

  @Test func aMirroredDisplayIsRefusedBeforeItIsCounted() {
    // Mirrored and also the only display left: the mirror set is the thing the
    // user has to change first, so that is the answer they get.
    let state = DisplayConnectionAvailabilityResolver.resolve(
      isSupported: true,
      onlineCount: 1,
      isMirrored: true
    )

    #expect(state == .mirroredDisplay)
    #expect(!state.canDisconnect)
    #expect(state.guidance != nil)
  }

  @Test func aSystemWithoutTheEntryPointOutranksEveryOtherAnswer() {
    let state = DisplayConnectionAvailabilityResolver.resolve(
      isSupported: false,
      onlineCount: 3,
      isMirrored: false
    )

    #expect(state == .unsupported)
    #expect(!state.canDisconnect)
    #expect(state.guidance != nil)
  }

  /// A laptop with one external monitor attached: the filtered card list holds
  /// one display, but two are online in total, so the request is safe.
  @Test func builtInDisplayCountsTowardsWhatIsLeftToLookAt() {
    let state = DisplayConnectionAvailabilityResolver.resolve(
      isSupported: true,
      onlineCount: 2,
      isMirrored: false
    )

    #expect(state.canDisconnect)
  }
}
