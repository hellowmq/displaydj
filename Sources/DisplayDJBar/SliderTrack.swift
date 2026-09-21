/// What the slider may draw, and what it may step from — one decision, not two.
///
/// Round 32 established that a relative step needs a starting point and that a non-optional
/// baseline is what makes "there is no reading" impossible to express: every caller has to
/// supply *some* number, so the drawn default stands in for the missing one. That correction
/// was applied to the step path (`SliderStep` takes an `Int?`) and to the spoken value, and it
/// stopped the keyboard from writing a fabricated 55 to a display that had never reported
/// anything.
///
/// The *geometry* was left reading the non-optional. `trackFillWidth` and `thumbOffset` both
/// computed from `isDragging ? dragValue : value`, a `Double` that starts at 50 and is only
/// ever synced *from a reading that exists* — the owning card's re-sync is
/// `guard !isDragging, let brightness = newValue`, so a `nil` reading is skipped and the last
/// drawn number simply stays. So on a display whose read failed the card said "no reading"
/// three times over — the readout showed `--`, VoiceOver said 未知, the `±` buttons were
/// disabled — while the largest element on it drew a half-filled track with the thumb parked
/// mid-way, asserting a specific brightness that nothing had measured.
///
/// That is worse than a cosmetic slip, because the fill is the reference the user's next
/// gesture is judged against: seeing the thumb at the middle, "nudge it up a bit" means
/// dragging from a position the display never reported. And it cannot heal — the re-sync
/// declines to act on `nil`, and a display whose read is failing keeps failing.
///
/// The rest of the app already refuses to invent a number in this state: `readoutDigits`
/// yields `--` rather than `0`, and `StatusItemTitle` yields an empty menu bar rather than a
/// `0` that would claim the panel is dark. The track was the one surface still fabricating.
///
/// Twenty-one rounds of sweeps missed it because the three surfaces an audit naturally samples
/// — readout, spoken value, `±` availability — are all correct, so the no-reading state reads
/// as handled. The geometry is expressed as arithmetic on a width rather than as a state read,
/// so it does not look like it is answering "is there a reading?" at all. It is.
///
/// Split out as a plain value for the same reason as `SliderStep`, `SliderDrag`, `ReadPass`,
/// `ReadTrigger`, `TargetedRead` and `HotkeyObservers`, and with one addition specific to this
/// pair: the drawing rule and the stepping rule are *the same rule*, so they are answered here
/// once and both consumers read the answer. Two parallel copies of "is there a number here
/// that means something?" is precisely how the geometry came to disagree with the step.
enum SliderTrack: Equatable {
  /// There is a meaningful position: draw it, and allow a step to start from it.
  case position(percent: Double)

  /// Nothing is known. Draw no position and refuse relative steps.
  ///
  /// Deliberately not named `none`: as `SliderTrack?` it would collide with `Optional.none`
  /// and silently swallow a branch in every `switch`, the same trap `RefreshScope.nothing`
  /// and `SliderStep.unavailable` are already named around.
  case unknown

  /// Resolves what the control currently represents.
  ///
  /// A drag yields the finger's position. The parent view disables gestures without a
  /// reading; outside a drag the bound number is only meaningful if it came from a read.
  static func resolve(
    isDragging: Bool,
    dragValue: Double,
    value: Double,
    hasReading: Bool
  ) -> SliderTrack {
    if isDragging { return .position(percent: dragValue) }
    guard hasReading else { return .unknown }
    return .position(percent: value)
  }

  /// The fraction of the track to fill, and the thumb's position along it.
  ///
  /// Zero when nothing is known — which draws an empty track rather than a track claiming a
  /// value. Zero here is the *absence* of a fill, not a brightness of 0%: the thumb is
  /// withheld in that state precisely so the empty track cannot be read as "0%".
  var fillRatio: Double {
    switch self {
    case .position(let percent): max(0, min(1, percent / 100))
    case .unknown: 0
    }
  }

  /// Whether the thumb has a position to sit at.
  ///
  /// Withheld when unknown. A thumb is a claim about where the value *is*, and parking it at
  /// either end would substitute one fabricated number for another. A failed read is
  /// recovered through the retry action once it has been confirmed.
  var showsThumb: Bool {
    switch self {
    case .position: true
    case .unknown: false
    }
  }

  /// The value a discrete step may start from, or `nil` when there is nothing to step from.
  ///
  /// Shared with the drawing above on purpose: what the user sees the control holding and what
  /// an arrow key adds to must be the same number, or the control is lying to one of them.
  var steppableValue: Int? {
    switch self {
    case .position(let percent): BrightnessAccessibility.clamp(Int(percent.rounded()))
    case .unknown: nil
    }
  }
}
