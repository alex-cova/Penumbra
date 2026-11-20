import GitIntelligence
import SwiftUI

struct IDEUnsyncedRow: View {
    let name: String
    let tint: Color
    /// Nil for a branch without an upstream: there is nothing to count against.
    let count: Int?
    let countHint: String
    let directionIcon: String
    let commits: [GitCommit]
    @Binding var isExpanded: Bool
    let buttonTitle: String
    var compactButtonTitle: String?
    let buttonHelp: String
    let isButtonEnabled: Bool
    let action: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var canExpand: Bool { !commits.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xxs) {
            if let compactButtonTitle {
                ViewThatFits(in: .horizontal) {
                    controls(buttonTitle: buttonTitle)
                    controls(buttonTitle: compactButtonTitle)
                }
            } else {
                controls(buttonTitle: buttonTitle)
            }

            if isExpanded && canExpand {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(commits) { commit in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(commit.subject)
                                    .font(IDEAppearance.Typography.tabLabel)
                                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                                    .lineLimit(1)
                                Text("\(commit.shortHash)  \(commit.author) · \(Self.relativeFormatter.localizedString(for: commit.date, relativeTo: .now))")
                                    .font(IDEAppearance.Typography.caption)
                                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, IDEAppearance.Spacing.tight)
                            .padding(.leading, IDEAppearance.Spacing.lg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func controls(buttonTitle: String) -> some View {
        HStack(spacing: IDEAppearance.Spacing.snug) {
            branchDisclosure

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .disabled(!isButtonEnabled)
                .help(buttonHelp)
                .accessibilityLabel(self.buttonTitle)
        }
    }

    private var branchDisclosure: some View {
        Group {
            if canExpand {
                Button(action: toggleCommits) { branchLabel }
                    .buttonStyle(.plain)
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            } else {
                branchLabel
            }
        }
        .help(count.map { "\(name), \($0) \(countHint)" } ?? "\(name), no upstream")
    }

    private var branchLabel: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if canExpand {
                IDEDisclosureChevron(isExpanded: isExpanded)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            Text(name)
                .font(IDEAppearance.Typography.tabLabel)
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let count {
                HStack(spacing: IDEAppearance.Spacing.xxs) {
                    Image(systemName: directionIcon)
                        .font(.system(size: IDEAppearance.IconSize.microGlyph, weight: .medium))
                    Text(count, format: .number)
                        .font(IDEAppearance.Typography.caption.monospacedDigit())
                }
                .fixedSize()
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            } else {
                Text("No upstream")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: IDEAppearance.Spacing.xl, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count.map { "\(name), \($0) \(countHint)" } ?? "\(name), no upstream")
    }

    private func toggleCommits() {
        IDEAppearance.Motion.animate(IDEAppearance.Motion.quick) { isExpanded.toggle() }
    }
}
