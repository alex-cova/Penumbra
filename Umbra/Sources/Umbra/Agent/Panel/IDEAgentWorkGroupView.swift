import SwiftUI

/// A folded run of tool calls: one line with what it did; opened, the calls' own cards.
struct IDEAgentWorkGroupView: View {
    let group: IDEAgentWorkGroup
    @Binding var isExpanded: Bool
    /// The current find match, outlined when it is one of this group's calls.
    var highlightedID: UUID?

    private var summary: String { group.summary.text(isLive: group.isLive) }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Button {
                IDEAppearance.Motion.animate(IDEAppearance.Motion.standard) { isExpanded.toggle() }
            } label: {
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    IDEDisclosureChevron(isExpanded: isExpanded, size: IDEAppearance.IconSize.breadcrumbChevron)
                    Text(summary)
                        .font(IDEAppearance.Typography.caption)
                        .lineLimit(1)
                    if group.isLive {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide these steps" : "Show these steps")
            .accessibilityLabel(summary)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
                    ForEach(group.entries) { entry in
                        IDEAgentEntryView(entry: entry).id(entry.id)
                            .ideFindHighlight(entry.id == highlightedID)
                    }
                }
                .padding(.leading, IDEAppearance.Spacing.sm)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(IDEAppearance.ColorToken.border)
                        .frame(width: 1)
                        .padding(.leading, 3)
                }
                .ideTransition(.opacity)
            }
        }
    }
}

extension View {
    /// The outline around the transcript row that holds the current find match.
    func ideFindHighlight(_ isCurrent: Bool) -> some View {
        overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous)
                    .strokeBorder(IDEAppearance.ColorToken.accent, lineWidth: 1.5)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
    }
}
