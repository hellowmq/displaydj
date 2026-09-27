import SwiftUI

/// Explicit opt-in row for the brightness hotkeys.
///
/// The shortcut is off until the user flips this switch. That explicit opt-in may raise the
/// system-owned Accessibility prompt; no prompt is raised merely by launching the app.
struct HotkeySettingsRow: View {
  @ObservedObject var controller: DisplayBarController
  var compact = true

  /// The one resolution of "what state is the shortcut in", read by both the spoken value
  /// and the notice. Resolving it twice is how the switch came to announce a working
  /// shortcut directly above a line explaining that it would not work.
  private var status: HotkeyStatus {
    HotkeyStatus.resolve(
      hotkeysEnabled: controller.hotkeysEnabled,
      isTrusted: controller.hasAccessibilityPermission
    )
  }

  private var shortcutSequences: [[String]] {
    controller.hotkeyDisplayName.split(separator: "/").map { shortcut in
      shortcut.trimmingCharacters(in: .whitespaces).map(String.init)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 8 : 10) {
      if compact {
        Rectangle()
          .fill(.quaternary.opacity(0.5))
          .frame(height: 1)
          .padding(.vertical, 3)
          .accessibilityHidden(true)
      }

      HStack(spacing: compact ? 4 : 8) {
        HStack(spacing: compact ? 4 : 8) {
          Text("快捷键")
            .font(compact ? .system(size: 11) : .body)
          shortcutKeycaps
        }
        Spacer(minLength: 8)
        Toggle(
          "快捷键",
          isOn: Binding(
            get: { controller.hotkeysEnabled },
            set: { controller.setHotkeysEnabled($0) }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(compact ? .mini : .regular)
        .accessibilityLabel(BrightnessAccessibility.hotkeyToggleLabel)
        .accessibilityValue(BrightnessAccessibility.hotkeyToggleValue(for: status))
      }

      if controller.displays.count > 1 {
        HStack(spacing: 8) {
          Text("快捷键目标")
            .font(compact ? .system(size: 11) : .body)
          Spacer(minLength: 8)
          Picker(
            "快捷键目标",
            selection: Binding(
              get: { controller.hotkeyTarget },
              set: { controller.setHotkeyTarget($0) }
            )
          ) {
            ForEach(BrightnessHotkeyTarget.allCases, id: \.self) { target in
              Text(target.title).tag(target)
            }
          }
          .labelsHidden()
          .font(compact ? .system(size: 10) : .body)
          .controlSize(compact ? .mini : .regular)
          .frame(width: compact ? 150 : 220)
        }
      }

      if status.showsPermissionNotice {
        permissionNotice
      }
    }
  }

  private var shortcutKeycaps: some View {
    HStack(spacing: compact ? 3 : 5) {
      ForEach(shortcutSequences.indices, id: \.self) { shortcutIndex in
        if shortcutIndex > 0 {
          Text("/")
            .font(compact ? .system(size: 10) : .callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
        }
        HStack(spacing: 2) {
          ForEach(shortcutSequences[shortcutIndex].indices, id: \.self) { keyIndex in
            keycap(shortcutSequences[shortcutIndex][keyIndex])
          }
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(controller.hotkeyDisplayName)
  }

  private func keycap(_ key: String) -> some View {
    Text(key)
      .font(.system(size: compact ? 10 : 12, weight: .medium, design: .rounded))
      .foregroundStyle(.primary)
      .frame(width: compact ? 18 : 22, height: compact ? 18 : 22)
      .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
      .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary, lineWidth: 1))
      .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
  }

  private var permissionNotice: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top, spacing: compact ? 6 : 8) {
        Image(systemName: "lock.shield")
          .font(compact ? .system(size: 10) : .callout)
          .accessibilityHidden(true)
        Text("需授权「辅助功能」；授权后若未立即生效，请退出并重新打开 DisplayDJ。")
          .font(compact ? .system(size: 10) : .callout)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: compact ? 12 : 16) {
        Button("请求授权") {
          controller.requestAccessibilityPermission()
        }
        Button("打开系统设置") {
          controller.openAccessibilitySettings()
        }
      }
      .buttonStyle(.link)
      .font(compact ? .system(size: 10) : .callout)
      .padding(.leading, compact ? 16 : 20)
    }
    .foregroundColor(.secondary)
  }
}
