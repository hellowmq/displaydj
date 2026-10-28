import Foundation

enum KeyboardBrightnessSource { case shortcut, mediaKey }

struct KeyboardBrightnessStep {
  let stableID: String
  let delta: Int
  let revision: UUID
  let source: KeyboardBrightnessSource
}

extension DisplayBarController {
  /// Capture the stable identity before scheduling any asynchronous work. One worker
  /// coalesces presses received during a cold read or slow write, preserving clamp order.
  func enqueueKeyboardBrightness(by delta: Int, for stableID: String,
                                 source: KeyboardBrightnessSource = .shortcut) {
    guard displays.filter({ $0.stableID == stableID }).count == 1 else { return }
    let revision = keyboardRevisions[stableID] ?? UUID()
    keyboardRevisions[stableID] = revision
    keyboardSteps.append(.init(stableID: stableID, delta: delta, revision: revision, source: source))
    guard keyboardTask == nil else { return }
    keyboardTask = Task { @MainActor [weak self] in
      await self?.drainKeyboardSteps()
    }
  }

  func discardKeyboardSteps(for ids: Set<String>? = nil) {
    let ids = ids ?? Set(keyboardRevisions.keys)
    keyboardSteps.removeAll { ids.contains($0.stableID) }
    for id in ids { keyboardRevisions[id] = nil }
  }

  /// The two opt-ins remain independent even while a baseline read is in flight.
  /// A hardware write already submitted still finishes its verified transaction.
  func discardKeyboardSteps(from source: KeyboardBrightnessSource) {
    let affected = Set(keyboardSteps.filter { $0.source == source }.map(\.stableID))
    keyboardSteps.removeAll { $0.source == source }
    let remaining = Set(keyboardSteps.map(\.stableID))
    for id in affected.subtracting(remaining) {
      keyboardRevisions[id] = nil
      if let display = displays.first(where: { $0.stableID == id }) {
        brightnessHUD.hide(for: display.runtimeID)
      }
    }
  }

  private func drainKeyboardSteps() async {
    defer { keyboardTask = nil }
    while let first = keyboardSteps.first {
      let id = first.stableID
      if let writeTask { await writeTask.value }
      guard keyboardRevisions[id] == first.revision else { continue }
      guard !isPreparingBrightnessSync else {
        discardKeyboardSteps(for: [id])
        showKeyboardFeedback(for: id, state: .failed("正在准备多屏同步，请稍后再试"))
        continue
      }
      if isAwaitingTopology {
        await scanAndRefresh()
        guard keyboardRevisions[id] == first.revision,
          displays.filter({ $0.stableID == id }).count == 1 else {
          discardKeyboardSteps(for: [id])
          continue
        }
      }
      showKeyboardFeedback(for: id, state: .reading)
      do {
        // Polling stops with the popover closed, and other apps may have changed brightness.
        // Each batch therefore starts from an actual read, never an old menu-bar value.
        let baseline = try await brightnessAccess.read(stableID: id)
        guard keyboardRevisions[id] == first.revision else { continue }
        setBrightnessForDisplay(baseline, id: id)
        clearFailure(for: id)
        if isBrightnessSyncEnabled {
          // Followers can also have stale/missing readings while the menu is closed.
          // Read the whole group before planning relative offsets; never infer them.
          let followers = displays.compactMap(\.stableID).filter { $0 != id }
          for follower in followers {
            do {
              let value = try await brightnessAccess.read(stableID: follower)
              guard keyboardRevisions[id] == first.revision else { break }
              setBrightnessForDisplay(value, id: follower)
            } catch {
              guard keyboardRevisions[id] == first.revision else { break }
              setBrightnessForDisplay(nil, id: follower)
              showKeyboardFeedback(for: follower, state: .failed("无法读取亮度，同步已关闭"))
            }
          }
        }
        guard keyboardRevisions[id] == first.revision else { continue }
        var target = baseline
        var deltas: [Int] = []
        while let step = keyboardSteps.first, step.stableID == id, step.revision == first.revision {
          keyboardSteps.removeFirst()
          deltas.append(step.delta)
          target = BrightnessAccessibility.adjusted(target, by: step.delta)
        }
        setBrightnessForDisplay(baseline, id: id)
        // Even a press at 0/100 takes manual ownership from an old Agent session.
        await setBrightness(target, for: id, showKeyboardFeedback: true, relativeSteps: deltas)
      } catch {
        guard keyboardRevisions[id] == first.revision else { continue }
        discardKeyboardSteps(for: [id])
        setBrightnessForDisplay(nil, id: id)
        let failure = BrightnessFailurePresenter.failure(for: error, operation: .read(displayStableID: id))
        setFailure(failure, for: id)
        showKeyboardFeedback(for: id, state: .failed(failure.summary))
      }
    }
  }

  func showKeyboardFeedback(for stableID: String, state: BrightnessHUDContent.State) {
    guard let display = displays.first(where: { $0.stableID == stableID }) else { return }
    keyboardFeedbackPresenter(.init(runtimeID: display.runtimeID, name: alias(for: display), state: state))
  }
}
