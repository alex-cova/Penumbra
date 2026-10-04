import SwiftUI

/// Markdown for the transcript: headings, lists, quotes, tables and fenced code, with inline styling.
/// A code block can be copied, put at the editor's caret, or opened in a new tab.
struct IDEAgentMarkdownView: View {
    let text: String
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let blocks = IDEAgentMarkdown.parse(text)
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs + 2) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: IDEAgentMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(IDEAgentFormat.markdown(text))
                .font(level <= 2 ? IDEAppearance.Typography.sectionHeader.weight(.bold) : IDEAppearance.Typography.body.weight(.semibold))
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .padding(.top, level <= 2 ? 4 : 2)
        case .paragraph(let text):
            Text(IDEAgentFormat.markdown(text))
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(minWidth: 14, alignment: .trailing)
                Text(IDEAgentFormat.markdown(text))
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .quote(let text):
            Text(IDEAgentFormat.markdown(text))
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .padding(.leading, IDEAppearance.Spacing.sm)
                .overlay(alignment: .leading) {
                    Rectangle().fill(IDEAppearance.ColorToken.border).frame(width: 2)
                }
        case .code(let language, let code):
            IDEAgentCodeBlock(language: language, code: code)
        case .rule:
            Divider().overlay(IDEAppearance.ColorToken.border)
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(IDEAgentMarkdown.alignedTable(rows))
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .padding(IDEAppearance.Spacing.xs)
            }
            .background(IDEAppearance.ColorToken.editor)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        }
    }
}

/// A fenced code block with its actions.
private struct IDEAgentCodeBlock: View {
    let language: String?
    let code: String
    @Environment(IDEWorkspace.self) private var workspace
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text(language ?? "")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer(minLength: 0)
                action(didCopy ? "checkmark" : "doc.on.doc", help: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        didCopy = false
                    }
                }
                action("text.insert", help: "Insert at the Caret") { _ = workspace.agentInsertAtCaret(code) }
                action("plus.rectangle.on.rectangle", help: "Open in a New Tab") {
                    workspace.agentOpenText(title: language.map { "Snippet (\($0))" } ?? "Snippet", text: code)
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.xs)
            .padding(.top, 2)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .padding(IDEAppearance.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(IDEAppearance.ColorToken.editor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
    }

    private func action(_ symbol: String, help: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph - 2))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
