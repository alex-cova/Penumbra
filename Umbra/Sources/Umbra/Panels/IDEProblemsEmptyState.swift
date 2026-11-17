import SwiftUI

/// The Problems tab's empty state. "No problems" is a claim: it is made only when the
/// missing-class checks ran.
struct IDEProblemsEmptyState: View {
    let status: IDEResolutionStatus
    let isEmpty: Bool
    let onAction: (IDEResolutionStatus.Action) -> Void

    var body: some View {
        let (symbol, title): (String, String) = switch status {
        case .complete: ("checkmark.circle", isEmpty ? "No problems" : "No problems match the filter")
        case .pending: ("clock", "No problems found yet")
        case .unavailable: ("exclamationmark.circle", "Some checks did not run")
        }
        return VStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: symbol)
                .font(.system(size: IDEAppearance.IconSize.emptyStateGlyph))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text(title)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            if let detail = status.message {
                Text(detail)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if case .unavailable(_, let action?) = status {
                Button(IDEResolutionNote.title(for: action), action: { onAction(action) })
                    .controlSize(.small)
                    .padding(.top, IDEAppearance.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
