import SwiftUI

/// What a panel shows when it has nothing to list: an optional glyph (or a spinner while it is
/// still looking), a title, and a line of explanation, centred in the space it is given.
struct IDEEmptyState: View {
    var symbol: String?
    var title: String?
    var message: String?
    var isLoading = false
    /// Optional primary action (e.g. "Open Folder…", "Clear Search"); nil keeps the plain state.
    var actionTitle: String?
    var action: (() -> Void)?
    /// Shown as a Cancel button beside the spinner while loading.
    var onCancel: (() -> Void)?

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
            if isLoading, let onCancel {
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
            } else if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: action == nil && onCancel == nil ? .combine : .contain)
    }
}
