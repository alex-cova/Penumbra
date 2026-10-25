import SwiftUI

/// A unified diff, additions and removals tinted, in a box of bounded height so a large edit
/// doesn't push the buttons out of view.
struct IDEAgentDiffView: View {
    let diff: String
    /// The box's height cap; `nil` lets it grow to its content (the caller scrolls).
    var maxHeight: CGFloat? = 260
    /// Whether `---` / `+++` lines are a file header (the approval card's diff has one) and so not tinted.
    /// The Changes tab's diffs have none, and a removed line that starts with `--` is a removal.
    var hasFileHeader = true

    private struct Line: Identifiable {
        let id: Int
        let text: String
        let tint: Color?
    }

    private var lines: [Line] {
        diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, raw in
            let text = String(raw)
            let tint: Color? = if hasFileHeader, text.hasPrefix("+++") || text.hasPrefix("---") { nil }
            else if text.hasPrefix("+") { Color.green.opacity(IDEAppearance.Opacity.tintWash) }
            else if text.hasPrefix("-") { Color.red.opacity(IDEAppearance.Opacity.tintWash) }
            else { nil }
            return Line(id: index, text: text, tint: tint)
        }
    }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(line.text.hasPrefix("@@") ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.tint ?? .clear)
                }
            }
            .textSelection(.enabled)
            .padding(IDEAppearance.Spacing.xs)
        }
        .frame(maxHeight: maxHeight)
        .background(IDEAppearance.ColorToken.editor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
    }
}
