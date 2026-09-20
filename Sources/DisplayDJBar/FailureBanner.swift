import SwiftUI

/// One failure, phrased for the user, with the action it offers.
///
/// Shared by the topology row and by every card so a display-specific error is drawn in the
/// same shape as a global one — and, more importantly, so it can be drawn *next to the
/// display it is about* instead of in one anonymous strip at the bottom.
///
/// Moved out of `DisplayBarView.swift` when that file reached the 400-line limit. Migrating a
/// whole unit rather than compressing the comments follows the precedent set by the
/// `+Polling` / `+Write` / `+Recovery` / `+Prune` / `+StatusItem` splits: this view has two
/// consumers and no dependency on the card's private state, so it stands on its own.
struct FailureBanner: View {
  let failure: BrightnessFailure
  @ObservedObject var controller: DisplayBarController

  var body: some View {
    HStack(alignment: .top, spacing: 5) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 9))
        .padding(.top, 1)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(failure.summary)
          .font(.system(size: 10, weight: .semibold))
        Text(failure.suggestion)
          .font(.system(size: 10))
          .foregroundColor(.orange.opacity(0.85))
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)

      if let title = controller.recoveryActionTitle(for: failure) {
        Button(title) {
          Task { await controller.recover(from: failure) }
        }
        .buttonStyle(.link)
        .font(.system(size: 10, weight: .medium))
        .disabled(controller.showsActivitySpinner)
        .accessibilityLabel(BrightnessAccessibility.recoveryLabel(title))
      }
    }
    .foregroundColor(.orange)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(.orange.opacity(0.10))
    )
    .help(failure.technicalDetail ?? failure.summary)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(BrightnessAccessibility.errorLabel(failure.spokenDescription))
  }
}
