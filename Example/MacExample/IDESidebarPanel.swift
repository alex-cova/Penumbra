import SwiftUI

struct IDESidebarPanel: View {
    var leadingInset: CGFloat = 0
    @EnvironmentObject private var workspace: IDEWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Files")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .padding(.leading, leadingInset + IDEAppearance.Spacing.lg)
                .padding(.trailing, IDEAppearance.Spacing.lg)
                .frame(height: IDEAppearance.Spacing.tabHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)

            if workspace.sidebarDocuments.isEmpty {
                VStack(spacing: IDEAppearance.Spacing.sm) {
                    Image(systemName: "doc.text")
                        .font(.title2)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                    Text("No Open Files")
                        .font(.subheadline)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(workspace.sidebarDocuments) { document in
                            IDESidebarRow(document: document) {
                                workspace.selectSidebarDocument(document.id)
                            }
                        }
                    }
                    .padding(.vertical, IDEAppearance.Spacing.xs)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IDEAppearance.ColorToken.sidebar)
        .focusable(false)
    }
}

private struct IDESidebarRow: View {
    let document: IDEDocumentRow
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: iconName(for: document.title))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 16)
            Text(document.title)
                .lineLimit(1)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            Spacer(minLength: 0)
            if document.isDirty {
                Circle()
                    .fill(IDEAppearance.ColorToken.accent)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Edited")
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, 6)
        .background {
            if document.isSelected {
                RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous)
                    .fill(IDEAppearance.ColorToken.selection)
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityAddTraits(.isButton)
        .focusable(false)
    }

    private func iconName(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "swift": "swift"
        case "js", "jsx", "ts", "tsx": "curlybraces"
        case "json": "curlybraces.square"
        case "md", "markdown": "text.book.closed"
        case "py": "chevron.left.forwardslash.chevron.right"
        default: "doc.text"
        }
    }
}

#Preview {
    IDESidebarPanel()
        .environmentObject({
            let workspace = IDEWorkspace()
            workspace.sidebarDocuments = [
                IDEDocumentRow(id: UUID(), title: "sample.js", languageIdentifier: "javascript", isDirty: true, isSelected: true),
                IDEDocumentRow(id: UUID(), title: "README.md", languageIdentifier: "markdown", isDirty: false, isSelected: false)
            ]
            return workspace
        }())
        .frame(width: 220, height: 420)
        .preferredColorScheme(.dark)
}
