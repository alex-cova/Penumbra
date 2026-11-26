import SwiftUI

/// Centered `project ⑂ branch` title; the branch opens the branch popup.
struct IDETitlebarProjectTitle: View {
    let title: String
    let branch: String?
    /// Commits the branch has that its upstream lacks (outgoing, ↑) and the reverse (incoming, ↓).
    var ahead = 0
    var behind = 0
    /// "Merging", "Rebasing"…: shown beside the branch while one is in progress.
    var operation: String?
    let showSourceControl: () -> Void

    @State private var isHoveringBranch = false
    @State private var showsBranches = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Text(title)
                .font(IDEAppearance.Typography.titlebarTitle)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)

            if let branch {
                Button { showsBranches.toggle() } label: {
                    HStack(spacing: IDEAppearance.Spacing.xs + 2) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: IDEAppearance.IconSize.toolbarGlyph, weight: .medium))
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                        Text(branch)
                            .font(IDEAppearance.Typography.titlebarTitle)
                            .foregroundStyle(isHoveringBranch ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.foreground.opacity(0.85))
                            .lineLimit(1)
                        if ahead > 0 || behind > 0 {
                            HStack(spacing: IDEAppearance.Spacing.xs) {
                                if ahead > 0 { syncCount("arrow.up", ahead, IDEAppearance.ColorToken.gitAdded) }
                                if behind > 0 { syncCount("arrow.down", behind, IDEAppearance.ColorToken.accent) }
                            }
                        }
                    }
                    .padding(.horizontal, IDEAppearance.Spacing.xs)
                    .padding(.vertical, IDEAppearance.Spacing.tight)
                    .background(isHoveringBranch ? IDEAppearance.ColorToken.controlHover : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHoveringBranch = $0 }
                .popover(isPresented: $showsBranches, arrowEdge: .bottom) {
                    IDEGitBranchPopup(isPresented: $showsBranches)
                }
                .help("Branches: switch, create, update and push" + (syncDescription.isEmpty ? "" : "\n" + syncDescription.dropFirst(2)))
                .accessibilityLabel("Git branch \(branch)\(syncDescription)")
                .accessibilityHint("Show branches")
                .focusable(false)
            }

            if let operation {
                Button(action: showSourceControl) {
                    Text(operation)
                        .font(IDEAppearance.Typography.caption.weight(.semibold))
                        .foregroundStyle(IDEAppearance.ColorToken.gitConflict)
                        .padding(.horizontal, IDEAppearance.Spacing.sm)
                        .padding(.vertical, IDEAppearance.Spacing.xxs)
                        .background(IDEAppearance.ColorToken.gitConflict.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("\(operation) is in progress: open Changes to continue or abort")
            }
        }
    }

    private var syncDescription: String {
        var parts: [String] = []
        if ahead > 0 { parts.append("\(ahead) outgoing commit\(ahead == 1 ? "" : "s") to push") }
        if behind > 0 { parts.append("\(behind) incoming commit\(behind == 1 ? "" : "s") to pull") }
        return parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")
    }

    private func syncCount(_ symbol: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol).font(.system(size: IDEAppearance.IconSize.toolbarGlyph - 2, weight: .bold))
            Text("\(count)").font(IDEAppearance.Typography.caption.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(color)
    }
}
