import SwiftUI

/// Accessibility vocabulary and keyboard semantics for the brightness controls.
///
/// The brightness slider is hand-drawn from a `ZStack` and a `DragGesture`, so assistive
/// technology sees nothing but decorative shapes unless the role, the current value and an
/// adjustable action are declared explicitly. Keeping the wording and the step arithmetic
/// here — rather than inline in the view — makes both testable without a running UI.
enum BrightnessAccessibility {
  /// Percentage points applied per keyboard arrow press or VoiceOver increment.
  static let step = 5

  static let lowerBound = 0
  static let upperBound = 100

  static let sliderLabel = "亮度"
  static let currentBrightnessLabel = "当前亮度"
  static let displayPickerLabel = "显示器"
  /// Spoken name of the action that makes a card's display the selected one.
  ///
  /// Selection used to live in a real `Picker`, which came with keyboard and VoiceOver
  /// support built in. When the popover became a column of cards, selecting moved onto the
  /// card itself as a tap gesture — and a tap gesture is reachable by a pointer and by
  /// nothing else. The card still *announces* that it is selectable, so assistive technology
  /// describes an affordance it is then given no way to use. Naming the action restores the
  /// half that was lost with the picker.
  static let selectDisplayActionLabel = "选择这台显示器"
  static let busyLabel = "正在与显示器通信"
  static let refreshLabel = "重新读取亮度"
  static let rescanLabel = "重新扫描显示器"
  /// Spoken label of the button that enters the card-reordering / alias-editing mode.
  static let editOrderLabel = "调整显示器顺序与别名"
  /// Spoken label of the button that leaves the reordering / alias-editing mode.
  static let doneEditingLabel = "完成调整"
  /// Spoken label of the button that forgets a manual order and returns to physical order.
  static let resetOrderLabel = "恢复为物理排列顺序"
  static let unknownValue = "未知"

  /// Spoken form of a brightness reading. `nil` means the hardware value is not known.
  static func valueDescription(for percent: Int?) -> String {
    guard let percent else { return unknownValue }
    return "\(clamp(percent))%"
  }

  /// What the slider tells assistive technology it can do — decided by the same value that
  /// decides whether it actually can.
  ///
  /// This used to be a constant promising "按左右方向键以 5% 为步进调节" unconditionally. The
  /// step *rule* had already been corrected to require a starting point (`SliderStep`), and the
  /// spoken value already said 未知 when there was none — but the hint went on describing an
  /// arrow-key affordance that would be refused. VoiceOver read the two out together, "亮度，
  /// 未知，按左右方向键以 5% 为步进调节", and the keys then did nothing at all, silently: there is
  /// no button to grey out on a hand-drawn track, so the sentence *was* the affordance.
  ///
  /// It also contradicted the other relative controls on the same card, which refuse in exactly
  /// this state. R2 removed the `±` buttons it used to name, and that does not weaken the rule —
  /// with the step row gone, the arrow keys and the spoken hint are the only relative affordance
  /// left on the slider, so the sentence agreeing with the rule matters more than it did.
  ///
  /// Taking the resolved `SliderStep` rather than a parallel `Bool` is the point. The
  /// explanation and the thing it explains cannot drift apart if there is only one decision
  /// between them.
  static func sliderHint(for stepState: SliderStep) -> String {
    switch stepState {
    case .apply:
      return "按左右方向键以 \(step)% 为步进调节"
    case .unavailable:
      // Says what is unavailable *and* what still works. A failed read must not read as a dead
      // control: naming an absolute position needs no baseline, and PRD 2.4 requires that path
      // to stay open — but on a track with no visible thumb it is not discoverable otherwise.
      return "当前无法用方向键调节，可直接点按轨道选择目标亮度"
    }
  }

  /// Spoken label of the hotkey opt-in switch.
  static let hotkeyToggleLabel = "亮度快捷键"

  /// What the hotkey switch tells assistive technology its state is — decided by the same
  /// value that decides whether the shortcut actually fires.
  ///
  /// This used to be `.accessibilityValue(hotkeyDisplayName)`, i.e. the constant "⌃⌘= / ⌃⌘-".
  /// On a `Toggle`, `accessibilityValue` *replaces* the on/off state VoiceOver would otherwise
  /// speak, so the switch announced the same sentence in every state and never said whether it
  /// was on. The combination it named is already spoken as part of the label beside it; the
  /// state was the part that existed nowhere.
  ///
  /// `awaitingTrust` is spoken rather than collapsed into "on" because the row already says in
  /// visible text that the shortcut will not fire until macOS grants trust. Announcing a plain
  /// "on" an inch above that line is the same contradiction round 39 removed from the slider:
  /// the control described an affordance that had been withdrawn.
  static func hotkeyToggleValue(for status: HotkeyStatus) -> String {
    switch status {
    case .off:
      return "已关闭"
    case .active:
      return "已开启，\(BrightnessHotkey.displayName)"
    case .awaitingTrust:
      return "已开启，但尚未获得辅助功能授权，快捷键在其他 App 中不会生效"
    }
  }

  static func clamp(_ value: Int) -> Int {
    min(upperBound, max(lowerBound, value))
  }

  /// Applies a relative change and keeps the result inside the representable range.
  static func adjusted(_ current: Int, by delta: Int) -> Int {
    clamp(current + delta)
  }

  /// Maps an arrow-key move command to a brightness delta.
  ///
  /// Right and up raise brightness, left and down lower it — the same orientation as the
  /// track itself. Unknown directions are ignored so the event stays with the system.
  static func delta(for direction: MoveCommandDirection) -> Int? {
    switch direction {
    case .left, .down:
      return -step
    case .right, .up:
      return step
    @unknown default:
      return nil
    }
  }

  /// Spoken name of the menu bar item itself.
  ///
  /// Kept separate from the value so the two can be composed in one place below. The status
  /// item is reached by walking the menu bar, where nothing around it supplies context: the
  /// neighbouring items are other apps.
  static let statusItemName = "DisplayDJ 显示器亮度"

  /// What the menu bar item tells assistive technology it is and what it is showing.
  ///
  /// The status item draws two things — a sun icon and a number — and until now it spoke
  /// neither of them correctly. `NSImage(systemSymbolName:accessibilityDescription:)` supplies
  /// "DisplayDJ" at setup, but an `NSButton` with a non-empty title takes its accessibility
  /// label from that title, so the description is displaced the moment a reading lands. The
  /// button then announced itself as a bare `56`: not the app's name, not a brightness, just a
  /// number sitting in the menu bar between other apps' icons.
  ///
  /// Both halves of the visible face are lost that way. The sun glyph is what tells a sighted
  /// user the number is a brightness — it is the stated reason `presentation` leaves the `%`
  /// off — and the tooltip "DisplayDJ — 显示器亮度控制" is how they learn which app it belongs
  /// to. Neither is spoken, so the one readout that is *always* on screen said the least.
  ///
  /// This is defect family ⑫E′ on the surface that can least afford it. The status item is the
  /// only brightness visible while the popover is closed, and polling is deliberately stopped
  /// in exactly that state, so nothing else was ever going to say it instead. Round 42 fixed
  /// Spoken label of the menu bar item.
  ///
  /// The menu bar shows the sun icon without a brightness number, so the label has to name the
  /// app and the display count itself: VoiceOver gets no on-screen number to lean on, and a
  /// single value would be misleading across displays. Composed from `statusItemName` so the
  /// menu bar cannot drift from the rest of the app about what the item is.
  static func statusItemLabel(displaysCount: Int) -> String {
    switch displaysCount {
    case 0:
      return "\(statusItemName)，未连接显示器"
    case 1:
      return "\(statusItemName)，1 台显示器"
    default:
      return "\(statusItemName)，\(displaysCount) 台显示器"
    }
  }

  /// Spoken label of the error banner, which is otherwise a bare icon plus a truncated line.
  static func errorLabel(_ message: String) -> String {
    "错误：\(message)"
  }

  /// What the menu bar icon becomes for the moment it is reporting a failed scroll.
  ///
  /// The wheel runs with the popover shut, so the icon is the whole of the feedback: a change
  /// of glyph is the only thing that distinguishes a write that failed from one that landed.
  /// It has to say so in words as well, because a triangle alone is not a sentence.
  static let scrollFailureImageName = "DisplayDJ 亮度调节失败"

  /// Spoken label of the button that carries out the recovery a failure offered.
  static func recoveryLabel(_ title: String) -> String {
    "\(title)，用于从上一个错误中恢复"
  }
}
