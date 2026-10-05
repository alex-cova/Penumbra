import SwiftUI

/// The chat tabs above the transcript. It only appears with two or more chats; a single chat is just
/// the panel. Each tab shows what its chat is doing: a spinner while it runs, an orange dot when it is
/// waiting for you, a blue one when it answered while you were elsewhere.
struct IDEAgentTabsBar: View {
    let agent: IDEAgentController

    @State private var renaming: IDEAgentConversation?
    @State private var renameDraft = ""
    @State private var closing: IDEAgentConversation?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(agent.conversations) { conversation in
                    IDEAgentTabItem(
                        conversation: conversation,
                        isSelected: conversation.id == agent.selectedID,
                        onSelect: { agent.select(conversation.id) },
                        onClose: { requestClose(conversation) }
                    )
                    .contextMenu {
                        Button("Rename…") {
                            renameDraft = conversation.title
                            renaming = conversation
                        }
                        Button("Fork") { Task { await agent.fork(conversation.id) } }
                            .disabled(conversation.isEmpty || conversation.isRunning)
                        Divider()
                        Button("Close") { requestClose(conversation) }
                        Button("Close Others") { agent.closeOthers(keeping: conversation.id) }
                            .disabled(agent.conversations.count < 2)
                    }
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
        }
        .frame(height: IDEAppearance.Spacing.tabHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                if let renaming { agent.rename(renaming.id, to: renameDraft) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave it empty to use the first message.")
        }
        .confirmationDialog(
            "Stop “\(closing?.title ?? "")” and close it?",
            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Stop and Close", role: .destructive) {
                if let closing { agent.close(closing.id) }
                closing = nil
            }
            Button("Keep Running", role: .cancel) { closing = nil }
        } message: {
            Text("It is still working. Changes it already made stay, and can be reverted from the chat's history.")
        }
    }

    private func requestClose(_ conversation: IDEAgentConversation) {
        if conversation.isRunning { closing = conversation } else { agent.close(conversation.id) }
    }
}

private struct IDEAgentTabItem: View {
    let conversation: IDEAgentConversation
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        IDEChromeTabItem(
            title: conversation.title, isSelected: isSelected, accessibilityLabel: label, onSelect: onSelect
        ) {
            status
        } trailing: {
            IDEChromeTabCloseButton(side: 14, onClose: onClose)
        }
        .frame(maxWidth: 220)
        .help(conversation.title)
    }

    @ViewBuilder private var status: some View {
        if conversation.isAwaitingUser {
            Circle().fill(Color.orange).frame(width: 7, height: 7)
        } else if conversation.isRunning {
            ProgressView().controlSize(.small).scaleEffect(0.6)
        } else if conversation.isUnread {
            Circle().fill(IDEAppearance.ColorToken.accent).frame(width: 7, height: 7)
        } else {
            Image(systemName: "bubble.left")
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }

    private var label: String {
        if conversation.isAwaitingUser { return "\(conversation.title), waiting for you" }
        if conversation.isRunning { return "\(conversation.title), working" }
        if conversation.isUnread { return "\(conversation.title), new reply" }
        return conversation.title
    }
}
