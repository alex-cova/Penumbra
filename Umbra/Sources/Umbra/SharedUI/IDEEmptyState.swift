import SwiftUI

/// What a panel shows when it has nothing to list: an optional glyph (or a spinner while it is
/// still looking), a title, and a line of explanation, centred in the space it is given.
struct IDEEmptyState: View {
    var symbol: String?
    var title: String?
    var message: String?
    var isLoading = false

    var body: some View {
        VStack(spacing: IDEAppearance.Spacing.sm) {
            if isLoading {
                ProgressView().controlSize(.small)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .accessibilityHidden(true)
            }
            if let title {
                Text(title)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(message == nil ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.foreground)
            }
            if let message {
                Text(message)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
