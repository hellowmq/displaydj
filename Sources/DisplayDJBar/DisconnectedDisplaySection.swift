import DisplayDJCore
import SwiftUI

/// One thing that went wrong while connecting or disconnecting.
///
/// Drawn in the same shape as a brightness failure so the popover has one visual
/// language for "this did not work", but without a retry button: the way out of a
/// failed disconnect is to try the same act again from the control that caused
/// it, not to resend a value the way a brightness retry does.
struct ConnectionNoticeRow: View {
  let notice: DisplayConnectionNotice

  var body: some View {
    HStack(alignment: .top, spacing: 5) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 9))
        .padding(.top, 1)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(notice.summary)
          .font(.system(size: 10, weight: .semibold))
        Text(notice.suggestion)
          .font(.system(size: 10))
          .foregroundColor(.orange.opacity(0.85))
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundColor(.orange)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(.orange.opacity(0.10))
    )
    .help(notice.technicalDetail ?? notice.summary)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(BrightnessAccessibility.errorLabel(notice.spokenDescription))
  }
}

/// Displays this tool disconnected, and the way back for each.
///
/// A disconnected display has no card: it is absent from the topology, so the
/// list of live monitors cannot contain it. Without this section the popover
/// would simply stop mentioning a display the app itself switched off — the one
/// state in which "nothing to see here" is exactly the wrong thing to say.
struct DisconnectedDisplaySection: View {
  let records: [DisplayConnectionRecord]
  let notice: DisplayConnectionNotice?
  @ObservedObject var controller: DisplayBarController

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("已断开的显示器")
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.secondary)
        .accessibilityAddTraits(.isHeader)

      ForEach(records, id: \.runtimeID) { record in
        let key = DisplayConnectionList.key(for: record.runtimeID)

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 4) {
            Image(systemName: "display.slash")
              .font(.system(size: 9))
              .foregroundColor(.secondary)
              .accessibilityHidden(true)

            Text(record.name)
              .font(.system(size: 10))
              .lineLimit(1)
              .truncationMode(.tail)

            Spacer(minLength: 4)

            Button("重新连接") {
              Task { await controller.reconnect(record) }
            }
            .buttonStyle(.link)
            .font(.system(size: 10, weight: .medium))
            .disabled(controller.showsActivitySpinner)
            .accessibilityLabel("重新连接 \(record.name)")
          }

          if let notice, notice.id == key {
            ConnectionNoticeRow(notice: notice)
          }
        }
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 7)
        .fill(Color.primary.opacity(0.03))
    )
  }
}
