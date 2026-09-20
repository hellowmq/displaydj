import DisplayDJCore

/// Starting the watcher that releases a disable when a display is unplugged.
///
/// Its own file because the controller is already at the length limit, and
/// because "which watchers this app runs" reads better as a list than as one
/// more block inside `setup`.
extension DisplayBarController {
  /// Releases a disable when the display behind it is unplugged or plugged back
  /// in, so a disabled display can never stay dark with no visible reason.
  func startConnectionAutoRelease() {
    guard
      let runner = DisplayConnectionAutoReleaseRunner.make(onChange: { [weak self] in
        Task { @MainActor [weak self] in await self?.scanAndRefresh() }
      })
    else { return }

    runner.start()
    connectionAutoRelease = runner
  }
}
