import Testing

@testable import DisplayDJBar

@Suite("Read activity ownership")
struct ReadActivityTests {

  // MARK: - Basic lifecycle

  @Test("A fresh lane is idle")
  func startsIdle() {
    let activity = ReadActivity()
    #expect(!activity.isReading)
  }

  @Test("Beginning a read marks the lane busy")
  func beginMarksBusy() {
    var activity = ReadActivity()
    _ = activity.begin()
    #expect(activity.isReading)
  }

  @Test("The read that owns the lane can release it")
  func ownerCanEnd() {
    var activity = ReadActivity()
    let token = activity.begin()
    activity.end(token)
    #expect(!activity.isReading)
  }

  // MARK: - Supersession

  /// The defect this guards. Cancellation is cooperative, so a superseded read keeps running
  /// until its next suspension point and unwinds *after* its replacement has started. With a
  /// bare boolean its cleanup cleared a flag that no longer described it, so the app reported
  /// an idle lane while a read was still on the hardware — and the polling timer's
  /// mutual-exclusion guard then let a fresh pass collide with it.
  @Test("A superseded read cannot release the lane its replacement now owns")
  func supersededReadCannotEndTheCurrentOne() {
    var activity = ReadActivity()
    let cancelled = activity.begin()
    let current = activity.begin()

    activity.end(cancelled)

    #expect(activity.isReading, "the replacement read is still in flight")

    activity.end(current)
    #expect(!activity.isReading)
  }

  @Test("Taking over an in-flight read keeps the lane busy throughout")
  func takeoverNeverReportsIdle() {
    var activity = ReadActivity()
    _ = activity.begin()
    _ = activity.begin()
    // No gap: the caller cancelled its predecessor and immediately became the owner, so
    // there is never an instant where the lane claims to be free.
    #expect(activity.isReading)
  }

  @Test("Tokens are never reused, so an old holder never matches a later read")
  func tokensAreUnique() {
    var activity = ReadActivity()
    let first = activity.begin()
    activity.end(first)
    let second = activity.begin()

    #expect(first != second)

    activity.end(first)
    #expect(activity.isReading, "an expired token must not release an unrelated later read")
  }

  @Test("Releasing an already-idle lane is harmless")
  func endingTwiceIsSafe() {
    var activity = ReadActivity()
    let token = activity.begin()
    activity.end(token)
    activity.end(token)
    #expect(!activity.isReading)
  }
}
