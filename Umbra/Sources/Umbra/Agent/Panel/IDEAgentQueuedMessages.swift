import AppKit
import SwiftUI

/// Messages written while the agent works, waiting for its next step. The pencil edits one in a popover,
/// ✕ takes one back. A message the run takes while its editor is open closes the editor, and the edit goes
/// into the message field (or onto the pasteboard when the field has text) with a toast saying so.
struct IDEAgentQueuedMessages: View {
    let conversation: IDEAgentConversation
    let toast: (IDEAgentToast) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(conversation.queue) { message in
                IDEAgentQueuedMessageRow(conversation: conversation, message: message, toast: toast)
            }
            Text("Sent at the agent's next step")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .padding(IDEAppearance.Spacing.xs + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
    }
}

private struct IDEAgentQueuedMessageRow: View {
    let conversation: IDEAgentConversation
    let message: IDEAgentConversation.QueuedMessage
    let toast: (IDEAgentToast) -> Void

    @State private var isEditing = false
    @State private var text = ""

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "clock")
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph - 1))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text(message.text)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            rowButton("Edit queued message", systemImage: "pencil", help: "Change this message before it is sent") {
                text = message.text
                isEditing = true
            }
            .popover(isPresented: $isEditing, arrowEdge: .top) { editor }
            rowButton("Remove queued message", systemImage: "xmark", help: "Take this message back") {
                conversation.removeQueued(message.id)
            }
        }
        // The row goes when the run takes the message; `onDisappear` sees that, an open popover included.
        // (It also goes when the panel switches chats; a message still queued keeps its text then.)
        .onDisappear {
            guard isEditing else { return }
            if conversation.queue.contains(where: { $0.id == message.id }) { isEditing = false } else { delivered() }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text("Queued message")
                .font(IDEAppearance.Typography.sectionHeader)
            TextEditor(text: $text)
                .font(IDEAppearance.Typography.body)
                .frame(width: 320, height: 120)
                .scrollContentBackground(.hidden)
                .padding(IDEAppearance.Spacing.xs)
                .background(IDEAppearance.ColorToken.editor)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
            HStack {
                Text("An empty message is taken back.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer()
                Button("Cancel") { isEditing = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(IDEAppearance.Spacing.md)
    }

    private func save() {
        if !conversation.updateQueued(message.id, text: text) { delivered() }
        isEditing = false
    }

    /// The run took the message while the editor was open: keep what was typed.
    private func delivered() {
        let edited = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        guard !edited.isEmpty, edited != message.text else { return }
        if conversation.keepEditOfDeliveredMessage(edited) {
            toast(IDEAgentToast(title: "Already sent", detail: "Your edit was put in the message field."))
        } else {
            IDEAgentPathCopy.copy(edited)
            toast(IDEAgentToast(title: "Already sent", detail: "Your edit was copied to the clipboard."))
        }
    }

    private func rowButton(_ title: String, systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(IDEAppearance.Typography.caption)
            .bold()
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .help(help)
    }
}
