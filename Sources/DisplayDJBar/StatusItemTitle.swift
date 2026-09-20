/// What the menu bar item shows.
///
/// Split out as a plain value for the same reason `ReadPass` and `RefreshScope` were: the
/// decision can then be asserted without a running `NSStatusItem`, which no test can create.
///
/// The status item used to render the selected display's brightness as a number next to the
/// sun icon. That single figure is a poor menu-bar citizen: it goes stale because polling is
/// deliberately stopped whenever the popover is closed — which is the state the item lives in
/// almost always — and it is meaningless the moment more than one display is attached, because
/// it cannot say which display it belongs to. Both problems are sidestepped by drawing the sun
/// glyph alone. VoiceOver still gets a label that names the app and the display count, so the
/// item is never unidentified and never announces a value that may belong to the wrong screen.
enum StatusItemTitle {

  /// How the status item should be drawn.
  ///
  /// The fields move together — a blank title with the icon still offset for text would leave a
  /// visible gap next to the sun glyph — so they are returned as one value instead of being
  /// set from separate branches at the call site.
  struct Presentation: Equatable {
    /// Text drawn next to the icon. Always empty: the menu bar shows the sun glyph only, never
    /// a brightness number (see the type comment for why).
    let title: String
    /// What assistive technology is told the item is and is showing.
    ///
    /// Part of this value rather than resolved beside it, for the reason `SliderTrack`
    /// established with its third consumer: the drawn face and the spoken one are one fact,
    /// and two parallel spellings of it is how one comes to be missing. Here the spoken half
    /// was missing outright — an `NSButton` derives its label from its title, so a non-empty
    /// title silently replaced the icon's accessibility description with a bare `56`. With the
    /// title now always empty, the label has to carry the whole identification itself.
    let accessibilityLabel: String
    /// Whether the icon has to make room for text. Always false now that the title is empty.
    var showsNumber: Bool { !title.isEmpty }
  }

  /// Resolves the status item's appearance from how many displays are attached.
  ///
  /// The menu bar carries no brightness number — for one display it is redundant with the
  /// popover and goes stale when that popover is closed; for two or more it is actively
  /// misleading because it cannot name its display. The icon alone is unambiguous. The spoken
  /// label keeps a display count so the item is never unidentified, and never announces a
  /// single value that may belong to the wrong screen.
  static func presentation(displaysCount: Int) -> Presentation {
    Presentation(
      title: "",
      accessibilityLabel: BrightnessAccessibility.statusItemLabel(displaysCount: displaysCount)
    )
  }
}
