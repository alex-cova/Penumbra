import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// The agent panel's message box (`IDEAgentComposerCard`): the growing field on top, and below it, inside the
/// card, attach (+), the chip row (permission, agent, model, context) and send/stop. Extracted from
/// `IDEAgentPanel` so the panel body stays a composition of subviews.
struct IDEAgentFieldRowView: View {
    let agent: IDEAgentController
    let settings: IDEAgentSettings
    let isAIMode: Bool
    let composerState: IDEAgentComposerState
    @Binding var composerHeight: CGFloat
    let acceptRequest: Int
    @Binding var lastEscape: Date?
    let openSettings: () -> Void

    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        @Bindable var agent = agent
        IDEAgentComposerCard(
            isRunning: agent.isRunning,
            canSend: !agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !agent.selected.pendingImages.isEmpty,
            send: send, stop: agent.stop,
            focus: { agent.composerFocusRequest += 1 }
        ) {
            IDEAgentComposerField(
                text: $agent.draft, height: $composerHeight,
                placeholder: placeholder,
                state: composerState, focusRequest: agent.composerFocusRequest, acceptRequest: acceptRequest,
                suggestions: { agent.suggestions(for: $0) },
                onSend: send,
                onStop: {
                    if agent.isRunning { agent.stop(); return }
                    // Esc twice in an empty field: go back to an earlier message.
                    guard agent.draft.isEmpty, !agent.selected.rewindTargets.isEmpty else { return }
                    if let last = lastEscape, Date.now.timeIntervalSince(last) < 0.6 {
                        lastEscape = nil
                        agent.rewindRequest = IDEAgentRewindRequest()
                    } else {
                        lastEscape = Date.now
                    }
                },
                onCycleMode: { agent.selected.cycleMode() },
                onAccept: { agent.perform($0) },
                onUserEdit: { agent.selected.promptRecall.reset() },
                onHistory: { agent.recallPrompt($0) },
                onDropFiles: { agent.selected.droppedFilesInsertion($0) },
                onPasteImage: { agent.selected.pasteImage($0) }
            )
            .frame(height: composerHeight)
        } leading: {
            IDEIconButton(
                systemImage: "plus", help: "Attach images or files (you can also drop or paste them)",
                tint: IDEAppearance.ColorToken.muted, action: pickImages)
            IDEAgentPanelChipRow(agent: agent, settings: settings, isAIMode: isAIMode, openSettings: openSettings)
        } trailing: {
            EmptyView()
        }
    }

    /// The file picker for image attachments. Picked files go through the same path as
    /// drops: images attach when the model sees them, anything else becomes an `@` mention.
    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .tiff, .heic]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            let insertion = agent.selected.droppedFilesInsertion(panel.urls)
            if !insertion.isEmpty { agent.draft += insertion }
        }
    }

    private var placeholder: String {
        if agent.isRunning { return "Write what to do next; it is sent at the next step…" }
        return isAIMode ? "Describe a task or ask a question" : "Ask about this project…"
    }

    private func send() {
        // A message that would be sent (not a /command) with no usable model asks for one first.
        if isAIMode, !agent.draft.hasPrefix("/"), workspace.aiModelSetupHint(for: .code) != nil {
            workspace.requestAIModelSetup(for: .code)
            return
        }
        agent.submit()
    }
}
