import AgentKit
import SwiftUI

/// The strip above the composer that shows one thing at a time: an approval whose card is out of view,
/// then a request waiting to be retried. Nothing shows when neither applies.
struct IDEAgentBannerLane: View {
    let conversation: IDEAgentConversation
    /// Whether the pending card is on screen; the bar only stands in for a card the user cannot see.
    let isPendingCardVisible: Bool
    let decide: (String, ApprovalDecision) -> Void
    let stop: () -> Void
    let retryNow: () -> Void
    let showEntry: (UUID) -> Void

    var body: some View {
        Group {
            if let entry = conversation.pendingDecision, !isPendingCardVisible {
                IDEAgentDecisionBar(entry: entry, decide: decide, show: { showEntry(entry.id) })
                    .id(entry.id)
            } else if let retry = conversation.retryState {
                IDEAgentRetryBanner(state: retry, stop: stop, retryNow: retryNow)
            }
        }
        .ideTransition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// What the agent is waiting on, for when its card has scrolled away: an approval can be answered here;
/// a question or a plan needs its card, so the bar takes you there.
struct IDEAgentDecisionBar: View {
    let entry: IDEAgentEntry
    let decide: (String, ApprovalDecision) -> Void
    let show: () -> Void

    var body: some View {
        if let request = entry.approval {
            IDEAgentBanner(
                systemImage: request.diff == nil ? "terminal" : "doc.badge.gearshape", tint: .orange,
                title: request.title, detail: request.command, detailIsCode: true
            ) {
                Button("Show", action: show)
                    .help("Scroll to the approval card for Edit…, a note or an Always… rule")
                Button(request.diff == nil ? "Deny" : "Reject") { decide(request.callID, .deny(note: "")) }
                Button(request.diff == nil ? "Run" : "Apply") { decide(request.callID, .approve) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        } else if let question = entry.question?.question ?? entry.elicitation.map({ $0.message.isEmpty ? $0.title : $0.message }) {
            IDEAgentBanner(systemImage: "questionmark.bubble", tint: .orange, title: "The agent is asking", detail: question) {
                Button("Answer…", action: show).buttonStyle(.borderedProminent)
            }
        } else if entry.plan != nil {
            IDEAgentBanner(systemImage: "list.bullet.clipboard", tint: .orange, title: "A plan is waiting for your approval", detail: nil) {
                Button("Review…", action: show).buttonStyle(.borderedProminent)
            }
        }
    }
}

/// A request that failed and is waiting to be sent again, with a live countdown.
struct IDEAgentRetryBanner: View {
    let state: IDEAgentRetryState
    let stop: () -> Void
    let retryNow: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            IDEAgentBanner(
                systemImage: state.exhaustedLimit == nil ? "wifi.exclamationmark" : "hourglass", tint: .orange,
                title: state.title, detail: state.countdown(now: context.date)
            ) {
                Button("Stop", action: stop)
                    .help("Stop the run instead of waiting")
                Button("Retry Now", action: retryNow)
                    .buttonStyle(.borderedProminent)
                    .disabled(state.nextAttemptAt <= context.date)
                    .help("Send the request again now instead of waiting")
            }
        }
    }
}

/// The look every banner shares: an icon, a title, one line of detail and up to three buttons, on one row
/// when it fits and with the buttons below when the panel is narrow.
struct IDEAgentBanner<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String?
    var detailIsCode = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                label
                Spacer(minLength: IDEAppearance.Spacing.sm)
                buttons
            }
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                label
                HStack {
                    Spacer(minLength: 0)
                    buttons
                }
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs + 2)
        .background(IDEAppearance.ColorToken.card)
        .overlay(
            RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous)
                .strokeBorder(tint.opacity(0.55)))
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement(title).post() }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(IDEAppearance.Typography.caption.weight(.semibold))
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? detail)
                        .font(detailIsCode ? IDEAppearance.Typography.monoSmall : IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) { actions() }
            .controlSize(.small)
            .fixedSize()
    }
}
