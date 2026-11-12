import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// The agent panel's message row: attach button, the growing field, stop/send. Extracted from
/// `IDEAgentPanel` so the panel body stays a composition of subviews.
struct IDEAgentFieldRowView: View {
    let agent: IDEAgentController
    let isAIMode: Bool
    let composerState: IDEAgentComposerState
    @Binding var composerHeight: CGFloat
    let acceptRequest: Int
    @Binding var lastEscape: Date?

    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        HStack(alignment: .bottom, spacing: IDEAppearance.Spacing.sm) {
            @Bindable var agent = agent
            IDEIconButton(
                systemImage: "paperclip", help: "Attach an image",
                tint: IDEAppearance.ColorToken.muted, action: pickImages)
            let field = IDEAgentComposerField(
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
            if isAIMode {
                field
            } else {
                field
                    .padding(IDEAppearance.Spacing.sm)
                    .background(IDEAppearance.ColorToken.card)
                    .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
            }

            if agent.isRunning {
                IDEIconButton(
                    systemImage: "stop.fill", help: "Stop", tint: IDEAppearance.ColorToken.error, action: agent.stop)
                    .accessibilityIdentifier(IDEACPAccessibility.stop)
            } else {
                IDEIconButton(
                    systemImage: "arrow.up.circle.fill", help: "Send",
                    tint: IDEAppearance.ColorToken.accent,
                    isDisabled: agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && agent.selected.pendingImages.isEmpty,
                    action: send)
                    .accessibilityIdentifier(IDEACPAccessibility.send)
            }
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
