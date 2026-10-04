/// Whether global keyboard interception needs installation under the current trust.
enum HotkeyObserverAction: Equatable {
  case keepExisting
  case reinstallGlobalObserver
}

enum HotkeyObservers {
  /// `installedWithTrust` means an active tap is installed under valid permission.
  /// The caller removes taps when trust falls; this rule handles installation and repair.
  static func action(
    hotkeysEnabled: Bool,
    installedWithTrust: Bool,
    isTrustedNow: Bool
  ) -> HotkeyObserverAction {
    guard hotkeysEnabled, isTrustedNow, !installedWithTrust else { return .keepExisting }
    return .reinstallGlobalObserver
  }
}
