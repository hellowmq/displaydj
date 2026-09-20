import SwiftUI

/// Explicit opt-in row for the brightness hotkeys.
///
/// The shortcut is off until the user flips this switch, and the accessibility trust it
/// needs is stated instead of being requested behind the user's back.
struct HotkeySettingsRow: View {
  @ObservedObject var controller: DisplayBarController

  /// The one resolution of "what state is the shortcut in", read by both the spoken value
  /// and the notice. Resolving it twice is how the switch came to announce a working
  /// shortcut directly above a line explaining that it would not work.
  private var status: HotkeyStatus {
    HotkeyStatus.resolve(
      hotkeysEnabled: controller.hotkeysEnabled,
      isTrusted: controller.hasAccessibilityPermission
    )
  }

  var body: some View {
    VStack(spacing: 4) {
      Rectangle()
        .fill(.quaternary.opacity(0.5))
        .frame(height: 1)
        .padding(.vertical, 3)
        .accessibilityHidden(true)

      Toggle(
        isOn: Binding(
          get: { controller.hotkeysEnabled },
          set: { controller.setHotkeysEnabled($0) }
        )
      ) {
        HStack(spacing: 4) {
          Text("快捷键")
            .font(.system(size: 11))
          Text(controller.hotkeyDisplayName)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.secondary)
        }
      }
      .toggleStyle(.switch)
      .controlSize(.mini)
      .accessibilityLabel(BrightnessAccessibility.hotkeyToggleLabel)
      .accessibilityValue(BrightnessAccessibility.hotkeyToggleValue(for: status))

      if status.showsPermissionNotice {
        permissionNotice
      }
    }
  }

  private var permissionNotice: some View {
    HStack(spacing: 4) {
      Image(systemName: "lock.shield")
        .font(.system(size: 9))
        .accessibilityHidden(true)
      Text("需在「隐私与安全性 › 辅助功能」中授权后，快捷键才会在其他 App 中生效")
        .font(.system(size: 9))
        .fixedSize(horizontal: false, vertical: true)
      Button("前往设置") {
        controller.openAccessibilitySettings()
      }
      .buttonStyle(.link)
      .font(.system(size: 9))
    }
    .foregroundColor(.secondary)
  }
}
