import SwiftUI

/// The page's notes as chips under the Browser toolbar: a number that matches the pin on the page, what the
/// note says, and its state. Click one to scroll to its element, right-click to edit or delete.
struct IDEAIBrowserNotesBar: View {
    let model: IDEAIBrowserModel
    /// Sends the open notes to the agent, with a short request.
    var ask: (() -> Void)?

    var body: some View {
        let items = model.annotations.items
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "pin.fill")
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    ForEach(items) { item in
                        IDEAIBrowserNoteChip(
                            item: item,
                            isOnThisPage: item.pageKey == model.currentPageKey,
                            isMissing: model.annotations.missing.contains(item.id),
                            reveal: { model.revealAnnotation(item.id) },
                            edit: { model.editingPin = IDEAIPinEdit(id: item.id, viewRect: .init(x: 40, y: 40, w: 20, h: 20)) },
                            delete: { model.deleteAnnotation(item.id) })
                    }
                }
            }
            Button("Clear") { model.annotations.clear() }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .help("Delete every note")
            if let ask {
                Button("Ask Agent", action: ask)
                    .controlSize(.small)
                    .disabled(model.annotations.userOpenItems.isEmpty)
                    .help("Send the open notes to the agent and ask it to make the changes")
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
        .background(IDEAppearance.ColorToken.card.opacity(IDEAppearance.Opacity.dimmed))
    }
}

private struct IDEAIBrowserNoteChip: View {
    let item: IDEAIAnnotation
    let isOnThisPage: Bool
    let isMissing: Bool
    let reveal: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    private var tint: Color {
        if item.status == .addressed { return IDEAppearance.ColorToken.gitAdded }
        return item.author == .agent ? Color.purple : Color.orange
    }

    private var state: String {
        switch item.status {
        case .open: isMissing ? "element not found" : (isOnThisPage ? "" : "on another page")
        case .sent: "sent"
        case .addressed: "addressed"
        }
    }

    var body: some View {
        Button(action: reveal) {
            HStack(spacing: 4) {
                Text("\(item.number)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(width: 16, height: 16)
                    .background(tint, in: Circle())
                Text(item.summary)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                    .frame(maxWidth: 180)
                if !state.isEmpty {
                    Text(state)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(isMissing ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(IDEAppearance.ColorToken.editor, in: Capsule())
            .opacity(item.status == .open && isOnThisPage ? 1 : 0.7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show on Page", action: reveal)
            Button("Edit Note…", action: edit)
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
        .help(item.reply.map { "Agent: \($0)" } ?? "\(item.element.shortName) — click to show it on the page")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Note \(item.number): \(item.summary)\(state.isEmpty ? "" : ", \(state)")")
        .accessibilityHint("Shows the element on the page")
    }
}

/// The note for one element, in a popover next to it. Typing happens here, in the app, so the page's own
/// keyboard shortcuts never see it.
struct IDEAIBrowserNoteEditor: View {
    let title: String
    @State var text: String
    let confirmTitle: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    var onDelete: (() -> Void)?

    init(
        title: String, text: String, confirmTitle: String, onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void, onDelete: (() -> Void)? = nil
    ) {
        self.title = title
        _text = State(initialValue: text)
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.onDelete = onDelete
    }

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Label(title, systemImage: "pin")
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            TextEditor(text: $text)
                .font(IDEAppearance.Typography.body)
                .scrollContentBackground(.hidden)
                .padding(IDEAppearance.Spacing.xs)
                .frame(width: 280, height: 84)
                .background(IDEAppearance.ColorToken.editor, in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                .focused($isFocused)
                .accessibilityLabel("Note")
            HStack {
                if let onDelete {
                    Button("Delete", role: .destructive, action: onDelete)
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { onConfirm(text) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            Text("Tell the agent what to change, or leave it empty to just point at this element.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(IDEAppearance.Spacing.sm)
        .onAppear { isFocused = true }
    }
}
