import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// The agent panel's composer: status, queued messages, image chips, the browser-notes chip,
/// suggestions and the field row. Extracted from `IDEAgentPanel` so the panel body stays a
/// composition of subviews.
struct IDEAgentComposerView: View {
    let agent: IDEAgentController
    let settings: IDEAgentSettings
    let isAIMode: Bool
    let composerState: IDEAgentComposerState
    @Binding var composerHeight: CGFloat
    @Binding var acceptRequest: Int
    @Binding var lastEscape: Date?
    let openSettings: () -> Void

    @Environment(IDEWorkspace.self) private var workspace

    private var choice: IDEAIModelChoice { agent.selected.effectiveChoice }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            if !agent.selected.hasConsent {
                IDEAgentDisclosureCard(settings: settings, provider: choice.provider)
            }
            if let status = agent.status {
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    IDEATypingDots()
                    Text(status)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            if !agent.selected.queue.isEmpty {
                IDEAgentQueuedMessages(queue: agent.selected.queue) { agent.selected.removeQueued($0) }
            }
            if !agent.selected.pendingImages.isEmpty {
                IDEAgentImageChips(images: agent.selected.pendingImages) { agent.selected.removePendingImage($0) }
            }
            if isAIMode, let browser = workspace.aiBrowser, !browser.annotations.userOpenItems.isEmpty {
                IDEAgentBrowserNotesChip(
                    notes: browser.annotations.userOpenItems, isAttached: agent.selected.attachesBrowserNotes,
                    toggle: { agent.selected.attachesBrowserNotes.toggle() },
                    show: { workspace.toggleAIInspector(tab: .browser) })
            }
            if composerState.isShowingSuggestions {
                IDEAgentSuggestionList(state: composerState) { index in
                    composerState.selectedIndex = index
                    acceptRequest += 1
                }
            }
            if isAIMode {
                // One card holds the field and its chips, like the message box of a chat app.
                VStack(spacing: IDEAppearance.Spacing.xs) {
                    fieldRow
                    IDEAgentPanelChipRow(agent: agent, settings: settings, isAIMode: isAIMode, openSettings: openSettings)
                }
                .padding(IDEAppearance.Spacing.sm)
                .background(IDEAppearance.ColorToken.card)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.panel, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: IDEAppearance.Radius.panel, style: .continuous)
                        .stroke(IDEAppearance.ColorToken.border, lineWidth: 1))
            } else {
                fieldRow
                IDEAgentPanelChipRow(agent: agent, settings: settings, isAIMode: isAIMode, openSettings: openSettings)
                    .padding(.horizontal, IDEAppearance.Spacing.xs)
            }
        }
        .padding(IDEAppearance.Spacing.sm)
    }

    private var fieldRow: some View {
        IDEAgentFieldRowView(
            agent: agent, isAIMode: isAIMode, composerState: composerState,
            composerHeight: $composerHeight, acceptRequest: acceptRequest, lastEscape: $lastEscape)
    }
}
