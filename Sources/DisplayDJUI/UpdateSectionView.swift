import DisplayDJCore
import SwiftUI

public struct UpdateSectionView: View {
  @ObservedObject public var manager: UpdateManager
  public let compact: Bool

  public init(manager: UpdateManager, compact: Bool = false) {
    self.manager = manager
    self.compact = compact
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center) {
        HStack(spacing: 6) {
          Text(verbatim: "v\(manager.currentVersion.description)")
            .font(compact ? .system(size: 12, weight: .medium) : .subheadline)

          if manager.channel == .debug {
            Text("DEBUG")
              .font(.system(size: 9, weight: .bold))
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(Color.orange.opacity(0.18))
              .foregroundStyle(Color.orange)
              .clipShape(RoundedRectangle(cornerRadius: 3))
          }
        }

        Spacer()

        Button {
          Task { await manager.checkForUpdates(isManual: true) }
        } label: {
          HStack(spacing: 4) {
            if manager.isChecking {
              ProgressView().controlSize(.mini)
            }
            Text(manager.isChecking ? "检查中…" : "检查更新")
          }
        }
        .disabled(manager.isChecking || manager.isUpdating)
        .controlSize(compact ? .small : .regular)
      }

      if !manager.statusMessage.isEmpty {
        Text(manager.statusMessage)
          .font(compact ? .system(size: 11) : .caption)
          .foregroundStyle(statusColor)
      }

      if case .updateAvailable(_, let newVer, let release, _) = manager.checkResult {
        Divider()

        HStack(alignment: .center) {
          Text(verbatim: "v\(newVer.description)")
            .font(.system(size: compact ? 12 : 13, weight: .semibold))

          Spacer()

          Link("发布说明", destination: release.htmlUrl)
            .font(compact ? .system(size: 11) : .caption)

          if manager.isUpdating {
            ProgressView(value: manager.updateProgress, total: 1.0)
              .controlSize(.small)
              .frame(width: compact ? 60 : 80)
          } else {
            Button("更新") {
              Task { await manager.applyUpdate() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(compact ? .small : .regular)
          }
        }
      }
    }
  }

  private var statusColor: Color {
    if manager.statusMessage.contains("失败") || manager.statusMessage.contains("错误") {
      return .orange
    }
    return .secondary
  }
}
