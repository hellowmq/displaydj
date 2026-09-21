import SwiftUI

/// The hand-drawn brightness track.
///
/// Because it is a `ZStack` plus a `DragGesture` rather than a real `Slider`, it has to
/// declare its own accessibility role, value and adjustable action, and it has to accept
/// keyboard focus and arrow keys itself. Without that it is a pile of decorative shapes
/// to VoiceOver and unreachable to anyone not using a pointer.
struct BrightnessSlider: View {
  @Binding var value: Double
  let isEnabled: Bool
  /// Whether `value` reflects a brightness the hardware actually reported.
  ///
  /// The bound `Double` cannot say this on its own: it is `@State` in the owning card, it
  /// has a fallback before the first reading and is only synced from a real reading.
  /// The card disables this slider while the value is unknown; this flag also prevents
  /// the track or keyboard path from treating the fallback as a measured brightness.
  let hasReading: Bool
  @Binding var isDragging: Bool
  /// Fires continuously during a drag so the hardware can start converging before
  /// the finger lifts — MonitorControl-style real-time following.
  var onDragChanged: ((Int) -> Void)?
  let onCommit: (Int) -> Void

  @State private var dragValue: Double = 0
  @FocusState private var isFocused: Bool

  // The geometry lives in `BrightnessSliderMetrics`. It is the part of this view that R2
  // changed, and it is the part with acceptance criteria, so it is named, documented and
  // tested rather than left as literals in the body.
  private typealias Metrics = BrightnessSliderMetrics

  /// What the control currently represents — for drawing *and* for stepping.
  ///
  /// One value answers both because they are one question. Resolving them separately is how
  /// the track came to paint a half-filled bar and a mid-way thumb on a display whose read had
  /// failed, while the readout beside it showed `--`, VoiceOver said未知 and the `±` buttons
  /// were disabled: the geometry read the raw `Double`, which had a fallback and is only ever
  /// synced from readings that exist, so the absence of a reading left the last drawn position
  /// standing rather than clearing it.
  private var trackState: SliderTrack {
    SliderTrack.resolve(
      isDragging: isDragging,
      dragValue: dragValue,
      value: value,
      hasReading: hasReading
    )
  }

  /// The value a discrete step may start from, or `nil` when nothing is known to step from.
  private var steppableValue: Int? {
    trackState.steppableValue
  }

  /// Whether a discrete step may be applied, and from what.
  ///
  /// Resolved once and read by both the action that performs the step and the hint that
  /// describes it. Two separate resolutions is how the control came to refuse arrow keys while
  /// still telling VoiceOver to press them.
  private var stepState: SliderStep {
    SliderStep.resolve(isEnabled: isEnabled, currentValue: steppableValue)
  }

  var body: some View {
    // One view, not a column. The `0%`/`100%` endpoints that sat under the bar were the last
    // thing this control drew besides the bar itself, and they were the reason the slider read
    // as an instrument with a scale rather than as something to grab: they cost visual weight
    // on every card, permanent and unread, to say two numbers the card's own readout says
    // anyway and that the ends of the bar say by being the ends of the bar.
    track
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(BrightnessAccessibility.sliderLabel)
      .accessibilityValue(BrightnessAccessibility.valueDescription(for: steppableValue))
      .accessibilityHint(BrightnessAccessibility.sliderHint(for: stepState))
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment:
          adjust(by: BrightnessAccessibility.step)
        case .decrement:
          adjust(by: -BrightnessAccessibility.step)
        @unknown default:
          break
        }
      }
      .focusable(isEnabled)
      .focused($isFocused)
      .onMoveCommand { direction in
        guard let delta = BrightnessAccessibility.delta(for: direction) else { return }
        adjust(by: delta)
      }
  }

  // MARK: - Track

  private var track: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(.quaternary)
          .frame(height: Metrics.trackHeight)

        // Flat, and the one place the brightness fill adopts the product brand.
        //
        // It was a three-stop `LinearGradient` — near-black, amber, yellow — painted across the
        // *fill* rather than across the track. Because the gradient was anchored to the shape it
        // filled, its dark end was always at x = 0 whatever the brightness was: at 6% the whole
        // fill was a near-black sliver that read as a smudge on the track, and at 100% the left
        // third of a full bar still read as empty. The colour therefore said nothing about the
        // value at all — only the length did — and it said something false about the first
        // fifth of the range. At 5pt that was a detail on a hairline; R2 made this bar the
        // card's primary control, where it is the first thing anyone sees.
        Capsule()
          .fill(DisplayDJBrandColor.spectralCyan)
          .frame(width: trackFillWidth(in: geometry.size.width), height: Metrics.trackHeight)
          .animation(.interactiveSpring(response: 0.15), value: trackState.fillRatio)

        thumb(in: geometry.size.width)
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { gesture in
            guard isEnabled else { return }
            if !isDragging {
              isDragging = true
              dragValue = value
              NSHapticFeedbackManager.defaultPerformer.perform(
                .levelChange, performanceTime: .now
              )
            }
            // Keep the bound value in step with the finger, not just at the end of the
            // gesture. The slider itself renders from `dragValue` while dragging, but the
            // binding is also read live by the owning card for its header, and the card
            // cannot see `dragValue` — it is private to this view. Publishing only on
            // release left that header frozen at the value the drag began from while the
            // track under it followed the pointer, and the card's own re-sync is suppressed
            // for the duration of a drag, so nothing corrected it until the finger lifted.
            let tracked = SliderDrag.track(atX: gesture.location.x, width: geometry.size.width)
            dragValue = tracked.value
            value = tracked.value
            onDragChanged?(tracked.published)
          }
          .onEnded { _ in
            guard isDragging else { return }
            // Publish the result *before* leaving drag mode. Every rendered property falls
            // back to `value` the moment `isDragging` clears, so a binding still holding the
            // pre-drag number would snap the fill and the thumb back to where the gesture
            // started while the readout kept the released value. It would also not heal: the
            // card re-syncs the slider only when the displayed brightness changes, and the
            // continuous drag callback has already published this value.
            let settled = SliderDrag.settle(dragValue: dragValue)
            dragValue = settled.value
            value = settled.value
            isDragging = false
            onCommit(settled.committed)
          }
      )
    }
    .frame(height: Metrics.hitHeight)
    .overlay(alignment: .center) { focusRing }
    .onChange(of: value) { newValue in
      if !isDragging { dragValue = newValue }
    }
  }

  /// The thumb, drawn only when there is a position for it to claim.
  ///
  /// Withheld rather than parked at an end when no reading exists. The thumb is the control's
  /// assertion of *where the value is*, and on a display whose read failed there is no such
  /// place — putting it at 0 would state a brightness as confidently as putting it at 50 did.
  /// The card disables the slider until it has a reading. Repeated read failures offer a
  /// separate retry action on the card.
  ///
  /// A drag bubble used to hang off this circle, showing the live value in a dark capsule. It
  /// was removed for two reasons, the second stronger than the first. It duplicated the card
  /// header, which renders the same number from the same binding for exactly as long as
  /// `isDragging` holds — so the control already said it, once, where the eye is. And it never
  /// actually read as a number: `.overlay` proposes the *thumb's* width, 22pt, so the `Text`
  /// was laid out with about 10pt of usable room after its own padding and truncated to `…`
  /// every single time. What reached the screen was a small dark capsule containing three
  /// dots, floating up over the header line — which is how it was reported.
  @ViewBuilder
  private func thumb(in width: CGFloat) -> some View {
    if trackState.showsThumb {
      Circle()
        .fill(.white)
        .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
        .overlay {
          Circle().strokeBorder(.black.opacity(0.06), lineWidth: 1)
        }
        .frame(width: Metrics.thumbSize, height: Metrics.thumbSize)
        .offset(x: thumbOffset(in: width))
        .shadow(color: .black.opacity(isDragging ? 0.22 : 0.08), radius: isDragging ? 4 : 2)
        .animation(.interactiveSpring(response: 0.15), value: trackState.fillRatio)
    }
  }

  /// Keyboard focus has to be visible, otherwise arrow-key control is undiscoverable.
  @ViewBuilder
  private var focusRing: some View {
    if isFocused {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(DisplayDJBrandColor.spectralCyan.opacity(0.85), lineWidth: 2)
        .frame(height: Metrics.focusRingHeight)
    }
  }

  // MARK: - Value math

  /// Applies a discrete change from the keyboard or from VoiceOver and commits it.
  ///
  /// The starting point is resolved rather than assumed. The bound `Double` always holds *a*
  /// number, because it begins at 50 and is only synced from readings that exist — so on a
  /// display whose read failed, stepping from it wrote a value derived from the placeholder.
  /// The card's `±` buttons used to refuse in that state via `canAdjustRelatively`, and the
  /// slider took only `canControl` and so kept stepping; R2 removed those buttons, and this
  /// control is now the *only* relative path on a card, which makes the rule that much more
  /// load-bearing. The arrow keys still step, and the wheel and the hotkey still step from the
  /// same resolved starting point.
  ///
  /// It steps from `trackState`, the same value the fill and the thumb are drawn from, so the
  /// number an arrow key adds to is by construction the number the user can see — and it reads
  /// `stepState`, the same value the spoken hint is phrased from, so the control cannot refuse
  /// a step it has just invited.
  private func adjust(by delta: Int) {
    guard case .apply(let current) = stepState else { return }
    let next = BrightnessAccessibility.adjusted(current, by: delta)
    guard next != current else { return }
    value = Double(next)
    dragValue = Double(next)
    onCommit(next)
  }

  private func trackFillWidth(in width: CGFloat) -> CGFloat {
    max(0, width * CGFloat(trackState.fillRatio))
  }

  private func thumbOffset(in width: CGFloat) -> CGFloat {
    max(
      0,
      min(
        width - Metrics.thumbSize,
        width * CGFloat(trackState.fillRatio) - Metrics.thumbSize / 2))
  }
}
