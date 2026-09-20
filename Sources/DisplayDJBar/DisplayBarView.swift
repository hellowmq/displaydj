import DisplayDJCore
import SwiftUI

// MARK: - Main View

struct DisplayBarView: View {
  @ObservedObject var controller: DisplayBarController
  /// Drives drag-to-reorder and alias editing. Off unless the user toggles it, so the
  /// cards behave as plain brightness controls the rest of the time. `EditMode` is iOS-
  /// only and unavailable on macOS, so the popover keeps its own boolean.
  @State private var isEditing = false
  /// How tall the stack of cards actually is, measured rather than assumed.
  ///
  /// The popover is sized from this view's ideal height, and the scroll view the cards live in
  /// has none of its own — so without a measurement the window's height stopped tracking its
  /// contents, and cards added after the popover appeared were clipped instead of counted.
  /// See `DisplayCardsViewport`.
  @State private var cardsContentHeight: CGFloat = 0

  // The preset list lives on `DisplayCard`, which is what draws the buttons. A second copy
  // sat here as well, left behind when the layout stopped being one shared control strip and
  // became one card per display; nothing read it. Two lists that must agree, only one of
  // which is rendered, is how the presets and their labels drift apart.

  var body: some View {
    VStack(spacing: 0) {
      topBar

      if controller.displays.isEmpty {
        emptyState
      } else {
        displayCards
      }

      // Displays this app switched off. Drawn after the live cards rather than
      // among them: they are not part of the topology, so they have no reading
      // and no slider, and putting them in the same list would hand them a card
      // that cannot do what every other card does.
      if !controller.disconnectedDisplays.isEmpty {
        DisconnectedDisplaySection(
          records: controller.disconnectedDisplays,
          notice: controller.connectionNotice,
          controller: controller
        )
        .padding(.top, 4)
      }

      // Topology-level failure only. Per-display failures are drawn on their own card, so
      // the user can tell which monitor is complaining and can act on several at once.
      if let failure = controller.failures.topology {
        FailureBanner(failure: failure, controller: controller)
          .padding(.top, 4)
      }

      Divider().padding(.vertical, 8)
      AgentServiceView()
      HotkeySettingsRow(controller: controller)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(width: 300)
  }

  // MARK: - Top Bar

  private var topBar: some View {
    HStack(spacing: 6) {
      Text("DisplayDJ")
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.secondary)
        .accessibilityHidden(true)

      Spacer()

      if controller.showsActivitySpinner {
        ProgressView()
          .scaleEffect(0.55)
          .frame(width: 12, height: 12)
          .accessibilityLabel(BrightnessAccessibility.busyLabel)
      }

      Button {
        Task { await controller.scanAndRefresh() }
      } label: {
        Image(systemName: "arrow.triangle.2.circlepath")
          .font(.system(size: 10, weight: .medium))
      }
      .buttonStyle(.plain)
      .foregroundColor(.secondary)
      .disabled(controller.showsActivitySpinner)
      .accessibilityLabel(BrightnessAccessibility.refreshLabel)

      if controller.displays.count > 1 {
        Button {
          withAnimation { isEditing.toggle() }
        } label: {
          Image(
            systemName: isEditing
              ? "checkmark.circle.fill" : "arrow.up.arrow.down.circle"
          )
          .font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundColor(isEditing ? .accentColor : .secondary)
        .accessibilityLabel(
          isEditing
            ? BrightnessAccessibility.doneEditingLabel
            : BrightnessAccessibility.editOrderLabel
        )

        if isEditing {
          Button {
            controller.resetOrderToPhysical()
          } label: {
            Image(systemName: "arrow.counterclockwise")
              .font(.system(size: 10, weight: .medium))
          }
          .buttonStyle(.plain)
          .foregroundColor(.secondary)
          .accessibilityLabel(BrightnessAccessibility.resetOrderLabel)
        }
      }
    }
    // The popover window clips its content to a ~16pt corner radius. The toolbar's
    // trailing icon sits only ~10pt below the top edge and ~12pt from the right edge,
    // so its top-right corner lands inside that arc and gets chopped — while the
    // leading label, being transparent glyphs, hides the same clip and reads as
    // "inconsistent". Pushing the whole bar down clears the radius on both corners
    // symmetrically. 10pt here on top of the VStack's 10pt gives 20pt of clearance.
    .padding(.vertical, 10)
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "display.trianglebadge.exclamationmark")
        .font(.title2)
        .foregroundColor(.secondary)
        .accessibilityHidden(true)
      Text("未检测到可控制的显示器")
        .font(.subheadline)
        .foregroundColor(.secondary)
      Button {
        Task { await controller.scanAndRefresh() }
      } label: {
        Label("重新扫描", systemImage: "arrow.clockwise")
          .font(.caption)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(BrightnessAccessibility.rescanLabel)
    }
    .padding(.vertical, 32)
  }

  // MARK: - Display Cards

  private var displayCards: some View {
    ScrollView {
      VStack(spacing: 6) {
        ForEach(controller.displays, id: \.selectionKey) { display in
          DisplayCard(
            display: display,
            controller: controller,
            isEditing: isEditing
          )
          .reordering(when: isEditing, display: display, controller: controller)
        }
      }
      .measuringHeight(into: $cardsContentHeight)
    }
    // A definite height, not `maxHeight`: `maxHeight` let the scroll view accept any height the
    // window happened to have, so a popover sized while the topology was still unknown stayed
    // that size and hid the cards that arrived next.
    .frame(height: DisplayCardsViewport.height(contentHeight: cardsContentHeight))
  }
}

// MARK: - Failure Banner
//
// `FailureBanner` lives in FailureBanner.swift. It is drawn both by the topology row above
// and by every card below, so it is not private to either.

// MARK: - Display Card

/// One display's brightness controls. Each card manages its own local
/// slider state so dragging one never disturbs another.
private struct DisplayCard: View {
  let display: DisplayDescriptor
  @ObservedObject var controller: DisplayBarController
  /// Whether the popover is in reorder/alias-editing mode. Passed in (not read from the
  /// environment) because `EditMode` is unavailable on macOS.
  let isEditing: Bool

  @State private var sliderValue: Double = 50
  @State private var isDragging = false

  private var stableID: String { display.stableID ?? "" }
  /// The name shown on the card: the user's alias when set, else the system name.
  private var shownName: String { controller.alias(for: display) }
  /// A two-way binding to this display's alias, writing through the controller.
  private var aliasBinding: Binding<String> {
    Binding(
      get: { shownName },
      set: { controller.setAlias($0, forStableID: stableID) }
    )
  }
  /// Key this card's banner is filed under.
  ///
  /// Not `stableID`: a display that has none is exactly the display with something to report,
  /// and every such card would collapse onto the same empty key. `selectionKey` is the stable
  /// ID when there is one and a namespaced runtime key when there is not, so each card keeps
  /// its own slot either way.
  private var failureKey: String { display.selectionKey }
  private var canControl: Bool { controller.canControl(stableID) }
  /// A `±` step has nothing to add to until a reading exists, so the buttons say so
  /// instead of looking available and quietly doing nothing.
  private var canAdjustRelatively: Bool { controller.canAdjustRelatively(stableID) }
  private var displayedBrightness: Int? {
    controller.displayedBrightness(for: stableID)
  }

  private var isSelected: Bool {
    controller.selectedDisplayKey == display.selectionKey
  }

  private var showsScrollTargetBadge: Bool {
    isSelected && ScrollTargetBadge.shows(displayCount: controller.displays.count)
  }

  var body: some View {
    VStack(spacing: 4) {
      // Header: name + readout
      HStack(spacing: 4) {
        Text(shownName)
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(.primary)
          .lineLimit(1)
          .truncationMode(.tail)

        if showsScrollTargetBadge {
          // Selection now has a consequence, so it gets words instead of a dot: this is the
          // card the menu bar wheel will move. Withheld on a single display, where naming
          // the target would only name the obvious.
          Text(ScrollTargetBadge.title(hotkeysEnabled: controller.hotkeysEnabled))
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            .accessibilityLabel(ScrollTargetBadge.accessibilityLabel)
        } else if isSelected {
          Circle()
            .fill(Color.accentColor)
            .frame(width: 4, height: 4)
            .accessibilityHidden(true)
        }

        Spacer()

        BrightnessReadout(value: isDragging ? Int(sliderValue.rounded()) : displayedBrightness)

        DisplayConnectionButton(display: display, controller: controller)
      }

      // Alias editor: shown only while rearranging, so the card stays a brightness
      // control the rest of the time. Writing an empty string clears the alias.
      if isEditing {
        TextField("别名（可选）", text: aliasBinding)
          .font(.system(size: 11))
          .textFieldStyle(.plain)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(
            RoundedRectangle(cornerRadius: 5)
              .fill(Color.primary.opacity(0.05))
          )
          .accessibilityLabel("显示器别名")
      }

      // Slider, full width. It used to be pinned to 248pt to leave room beside it for the step
      // buttons and the presets on the row below; with that row gone there is nothing to share
      // the width with, and a track that spans the card states the one thing this card is for.
      BrightnessSlider(
        value: $sliderValue,
        isEnabled: canControl,
        // A relative step needs a starting point, and `sliderValue` is a `@State` that defaults
        // to 50 — so without this the slider's keyboard path stepped from a number no read ever
        // produced. After R2 this is also the only relative path left on the card.
        hasReading: canAdjustRelatively,
        isDragging: $isDragging,
        onDragChanged: { intValue in
          Task { await controller.setBrightness(intValue, for: stableID) }
        },
        onCommit: { intValue in
          Task { await controller.setBrightness(intValue, for: stableID) }
        }
      )
      .disabled(!canControl || isEditing)

      // This display's own failure, drawn on this display's card. A single shared strip at
      // the bottom could not say which monitor it was about, and could only ever show one.
      if let failure = controller.failure(for: failureKey) {
        FailureBanner(failure: failure, controller: controller)
          .padding(.top, 2)
      }

      // The outcome of disconnecting *this* display, filed under this card's key.
      // A connection notice aimed elsewhere belongs to a different display — the
      // one that is no longer online and is drawn in its own section below.
      if let notice = controller.connectionNotice, notice.id == failureKey {
        ConnectionNoticeRow(notice: notice)
          .padding(.top, 2)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 7)
        .fill(isSelected ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.03))
        .overlay(
          RoundedRectangle(cornerRadius: 7)
            .strokeBorder(isSelected ? Color.accentColor.opacity(0.2) : Color.clear, lineWidth: 1)
        )
    )
    .contentShape(Rectangle())
    .onTapGesture {
      // While reordering, a tap must not also select the card — the row is being dragged.
      if !isEditing {
        selectThisDisplay()
      }
    }
    // Both occasions go through `SliderSync`, and the appearing one exists at all because
    // `onChange` alone could not cover it. `onChange` reports differences, so it says nothing
    // about the value a card is *born* holding — and the reading routinely predates the card:
    // the popover is `.transient`, so every reopen builds fresh `@State` at 50 while
    // `brightnessByID` survives, and a hotkey pressed before the popover was ever opened fills
    // the reading in first. The slider then drew 50 beside a readout showing the real value,
    // and stepped from50 too, with no way to heal unless the hardware happened to change.
    .onAppear {
      applySync(reading: displayedBrightness, occasion: .cardAppeared)
    }
    .onChange(of: displayedBrightness) { newValue in
      applySync(reading: newValue, occasion: .readingChanged)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(shownName) 亮度控制")
    .accessibilityValue(BrightnessAccessibility.valueDescription(for: displayedBrightness))
    // The card is also the display selector, so its selected state has to be spoken;
    // the accent dot that conveys it visually is hidden from VoiceOver.
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    .accessibilityHint(BrightnessAccessibility.displayPickerLabel)
    // Announcing `.isSelected` without offering a way to *become* selected describes an
    // affordance that only a mouse can reach. The tap gesture above is pointer-only, so
    // without this the card told VoiceOver it was selectable and then gave it nothing to
    // activate. Both entry points resolve through `SelectDisplayAction`, so they cannot
    // drift apart the way the gesture drifted from the key selection is actually stored by.
    .accessibilityAction(named: BrightnessAccessibility.selectDisplayActionLabel) {
      selectThisDisplay()
    }
  }

  /// The single way this card's slider adopts a reading.
  ///
  /// Shared by the appearing card and by a reading that lands later, on purpose: they are one
  /// question — should the slider take this number? — and the animation is the only thing that
  /// legitimately differs between them. Splitting them is how the card came to have a rule for
  /// staying in step and none for starting in step.
  private func applySync(reading: Int?, occasion: SliderSync.Occasion) {
    guard
      case .adopt(let value, let animated) = SliderSync.resolve(
        reading: reading,
        isDragging: isDragging,
        occasion: occasion
      )
    else { return }
    guard animated else {
      sliderValue = value
      return
    }
    withAnimation(.easeOut(duration: 0.2)) {
      sliderValue = value
    }
  }

  /// The single way this card becomes the selected display.
  ///
  /// Shared by the pointer and by assistive technology on purpose: when the gesture resolved
  /// its own key it used `stableID`, while selection is stored under `selectionKey`, so a
  /// display without a stable identity could be selected by the app and never by the user.
  private func selectThisDisplay() {
    guard
      case .select(let key) = SelectDisplayAction.resolve(
        selectionKey: display.selectionKey,
        currentSelection: controller.selectedDisplayKey
      )
    else { return }
    controller.selectDisplay(key: key)
  }
}
