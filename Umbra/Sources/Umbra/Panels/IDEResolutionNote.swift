import SwiftUI

/// One quiet line above the problem list when the missing-class checks are waiting for indexing
/// (a clock, no spinner: it goes away when the index is published) or cannot run (with the action
/// that would let them).
struct IDEResolutionNote: View {
    let status: IDEResolutionStatus
    let onAction: (IDEResolutionStatus.Action) -> Void

    static func title(for action: IDEResolutionStatus.Action) -> String {
        switch action {
        case .syncProject: "Sync Project"
        case .chooseJDK: "Choose a JDK…"
        }
    }

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: isUnavailable ? "exclamationmark.circle" : "clock")
                .font(.system(size: IDEAppearance.IconSize.smallGlyph))
            Text(status.message ?? "")
                .font(IDEAppearance.Typography.caption)
                .lineLimit(2)
            Spacer(minLength: IDEAppearance.Spacing.sm)
            if case .unavailable(_, let action?) = status {
                Button(Self.title(for: action), action: { onAction(action) })
                    .buttonStyle(.link)
                    .font(IDEAppearance.Typography.caption)
            }
        }
        .foregroundStyle(IDEAppearance.ColorToken.muted)
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, IDEAppearance.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.message ?? "")
    }

    private var isUnavailable: Bool {
        if case .unavailable = status { return true }
        return false
    }
}
