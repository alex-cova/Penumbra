import EditorIntelligence
import JavaIntelligence
import SwiftUI

struct IDEProblemRowView: View {
    let row: ProblemRow
    var isSelected = false
    let onOpen: () -> Void
    let onFix: () -> Void
    var onQuickFixes: (() -> Void)?
    var rule: IDEInspectionRuleInfo?
    var onDisableRule: ((IDEInspectionRuleInfo) -> Void)?
    var onQuietRule: ((IDEInspectionRuleInfo) -> Void)?
    var onConfigureRule: ((IDEInspectionRuleInfo) -> Void)?

    @State private var isHovering = false

    /// An inspection's readable name; the tool's id for everything else.
    private var origin: String { IDEProblemsMarkdown.origin(of: row.diagnostic) }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: IDEAppearance.Spacing.sm) {
                Image(systemName: IDEProblemStyle.symbol(for: row.diagnostic.severity))
                    .font(.system(size: IDEAppearance.IconSize.rowGlyph))
                    .foregroundStyle(IDEProblemStyle.color(for: row.diagnostic.severity))
                    .frame(width: 14)
                Text(row.diagnostic.message)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Text(origin)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Text("\(row.diagnostic.range.start.line + 1):\(row.diagnostic.range.start.column + 1)")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .padding(.leading, IDEAppearance.Spacing.xl)
            .padding(.trailing, IDEAppearance.Spacing.md)
            .padding(.vertical, IDEAppearance.Spacing.tight)
            .background(isSelected ? IDEAppearance.ColorToken.selection : (isHovering ? IDEAppearance.ColorToken.controlHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .overlay(alignment: .trailing) {
            if isHovering {
                Button(action: onFix) {
                    Label("Fix with Agent", systemImage: "sparkles")
                        .font(IDEAppearance.Typography.caption)
                        .padding(.horizontal, IDEAppearance.Spacing.snug)
                        .padding(.vertical, IDEAppearance.Spacing.xxs)
                        .background(IDEAppearance.ColorToken.card, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .padding(.trailing, IDEAppearance.Spacing.md)
                .help("Ask the agent to fix this problem")
            }
        }
        .contextMenu {
            if let onQuickFixes { Button("Show Quick Fixes…", action: onQuickFixes) }
            Button("Fix with Agent", systemImage: "sparkles", action: onFix)
            if let rule {
                Divider()
                Button("Disable Inspection \u{201C}\(rule.title)\u{201D}") { onDisableRule?(rule) }
                // Swift has no "No highlighting" level yet.
                if rule.language == .java { Button("Turn Off Highlighting (Keep Fix)") { onQuietRule?(rule) } }
                Button("Edit Inspection Settings…") { onConfigureRule?(rule) }
            }
        }
        .accessibilityLabel("\(IDEProblemStyle.label(for: row.diagnostic.severity)) at line \(row.diagnostic.range.start.line + 1): \(row.diagnostic.message)")
    }
}
