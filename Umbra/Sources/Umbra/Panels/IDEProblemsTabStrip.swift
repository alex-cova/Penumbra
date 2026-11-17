import SwiftUI

/// File · Project Errors · one tab per Inspect Code run.
struct IDEProblemsTabStrip: View {
    let runs: IDEInspectionRunsStore

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            IDEProblemsStripButton("File", isSelected: runs.selection == .file) { runs.selection = .file }
            IDEProblemsStripButton("Project Errors", isSelected: runs.selection == .project) { runs.selection = .project }
            ForEach(runs.runs) { run in
                Button { runs.selection = .run(run.id) } label: {
                    HStack(spacing: IDEAppearance.Spacing.xs) {
                        if run.state == .running { ProgressView().controlSize(.mini) }
                        Text(run.title)
                            .font(IDEAppearance.Typography.tabLabel)
                            .lineLimit(1)
                            .foregroundStyle(runs.selection == .run(run.id) ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                        Button { runs.close(run.id) } label: { Image(systemName: "xmark").font(.system(size: IDEAppearance.IconSize.microGlyph, weight: .semibold)) }
                            .buttonStyle(.borderless)
                            .help("Close results")
                    }
                    .padding(.horizontal, IDEAppearance.Spacing.sm)
                    .padding(.vertical, IDEAppearance.Spacing.tight)
                    .background(runs.selection == .run(run.id) ? IDEAppearance.ColorToken.tabActive : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(run.title)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, IDEAppearance.Spacing.tight)
    }
}
