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
    /// Whether the card of the decision the chat waits on is on screen (the banner lane stands in for it when not).
    var isPendingCardVisible = true
    /// Scrolls the transcript to an entry.
    var showEntry: (UUID) -> Void = { _ in }

    @Environment(IDEWorkspace.self) private var workspace

    private var choice: IDEAIModelChoice { agent.selected.effectiveChoice }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            IDEAgentToastLane(agent: agent)
            if !agent.selected.hasConsent {
                IDEAgentDisclosureCard(settings: settings, provider: choice.provider)
            }
            IDEAgentBannerLane(
                conversation: agent.selected, isPendingCardVisible: isPendingCardVisible,
                decide: { agent.decide(callID: $0, $1) }, stop: { agent.stop() }, retryNow: { agent.retryNow() },
                showEntry: showEntry)
            // The retry banner says what the status line would, with a countdown.
            if let status = agent.status, agent.selected.retryState == nil {
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    IDEATypingDots()
                    Text(status)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            if !agent.selected.queue.isEmpty {
                IDEAgentQueuedMessages(conversation: agent.selected, toast: { agent.showToast($0) })
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
                // Codex's "This computer / Choose project" strip: the project and branch sit on a tray that the
                // message box overlaps.
                VStack(spacing: -IDEAgentComposerMetrics.cornerRadius) {
                    HStack(spacing: IDEAppearance.Spacing.md) {
                        IDEAIProjectChip()
                        IDEAIBranchChip()
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, IDEAppearance.Spacing.md)
                    .padding(.top, IDEAppearance.Spacing.snug)
                    .padding(.bottom, IDEAppearance.Spacing.snug + IDEAgentComposerMetrics.cornerRadius)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: IDEAgentComposerMetrics.cornerRadius,
                            topTrailingRadius: IDEAgentComposerMetrics.cornerRadius,
                            style: .continuous)
                            .fill(IDEAppearance.ColorToken.controlHover))
                    .padding(.horizontal, IDEAppearance.Spacing.md)
                    fieldRow
                }
            } else {
                fieldRow
            }
            if let warning = IDEAgentComposerLimits.validationMessage(for: agent.draft) {
                Text(warning)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, IDEAppearance.Spacing.xs)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityIdentifier("agent.composer.lengthWarning")
            }
        }
        .padding(IDEAppearance.Spacing.sm)
    }

    private var fieldRow: some View {
        IDEAgentFieldRowView(
            agent: agent, settings: settings, isAIMode: isAIMode, composerState: composerState,
            composerHeight: $composerHeight, acceptRequest: acceptRequest, lastEscape: $lastEscape,
            openSettings: openSettings)
    }
}
