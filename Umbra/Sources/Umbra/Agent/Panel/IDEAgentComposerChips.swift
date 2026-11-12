import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// The Browser tab's open notes, going with the next message: "📌 3 notes · localhost:3000/dashboard". ✕ keeps
/// them out of that message (they stay on the page); click shows the Browser tab.
struct IDEAgentBrowserNotesChip: View {
    let notes: [IDEAIAnnotation]
    let isAttached: Bool
    let toggle: () -> Void
    let show: () -> Void

    private var title: String {
        let page = notes.first.map { "\($0.pageURL.host() ?? "page")\($0.pageURL.path)" } ?? ""
        return "\(notes.count) note\(notes.count == 1 ? "" : "s") · \(page)"
    }

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "pin.fill")
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph - 2))
                .foregroundStyle(isAttached ? Color.orange : IDEAppearance.ColorToken.muted)
            Button(action: show) {
                Text(title)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground.opacity(isAttached ? 1 : 0.55))
                    .strikethrough(!isAttached)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("Show the notes in the Browser tab")
            Spacer(minLength: 0)
            Text(isAttached ? "sent with your next message" : "kept out of the next message")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Button(
                isAttached ? "Leave browser notes out of the next message" : "Send browser notes with the next message",
                systemImage: isAttached ? "xmark" : "arrow.uturn.backward",
                action: toggle
            )
            .labelStyle(.iconOnly)
            .font(.caption2)
            .bold()
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .help(isAttached ? "Leave these notes out of the next message" : "Send these notes with the next message")
        }
        .padding(IDEAppearance.Spacing.xs + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Messages written while the agent works, waiting for its next step. ✕ takes one back.
struct IDEAgentQueuedMessages: View {
    let queue: [IDEAgentConversation.QueuedMessage]
    let remove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(queue) { message in
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
                    Button("Remove queued message", systemImage: "xmark") { remove(message.id) }
                    .labelStyle(.iconOnly)
                    .font(.caption2)
                    .bold()
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .help("Take this message back")
                }
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

/// How full the model's window is: a ring and a percentage, turning orange and then red as it fills.
/// The menu summarizes the earlier conversation to make room.
struct IDEAgentContextMeter: View {
    let fraction: Double
    let tokens: Int
    let window: Int
    let isBusy: Bool
    let compact: () -> Void

    private var tint: Color {
        switch fraction {
        case ..<0.75: IDEAppearance.ColorToken.muted
        case ..<0.9: .orange
        default: IDEAppearance.ColorToken.error
        }
    }

    var body: some View {
        Menu {
            Text("\(IDEAgentFormat.tokens(tokens)) of \(IDEAgentFormat.tokens(window)) tokens in use")
            Button("Summarize the Earlier Conversation", action: compact)
                .disabled(isBusy)
        } label: {
            HStack(spacing: 4) {
                ZStack {
                    Circle().stroke(IDEAppearance.ColorToken.border, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(tint)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(IDEAgentFormat.tokens(tokens)) of \(IDEAgentFormat.tokens(window)) tokens in the model's window. Older messages are summarized automatically as it fills; /compact does it now.")
        .accessibilityLabel("Context window \(Int((fraction * 100).rounded())) percent full")
    }
}

/// The chat's permission mode. A menu to pick one; ⇧Tab in the message field walks through them.
struct IDEAgentModeChip: View {
    let mode: PermissionMode
    let select: (PermissionMode) -> Void

    private var tint: Color {
        switch mode {
        case .manual: IDEAppearance.ColorToken.muted
        case .acceptEdits: IDEAppearance.ColorToken.accent
        case .auto: .orange
        case .plan: .teal
        }
    }

    var body: some View {
        Menu {
            ForEach(PermissionMode.allCases, id: \.self) { candidate in
                Button {
                    select(candidate)
                } label: {
                    Label(candidate.title, systemImage: candidate == mode ? "checkmark" : candidate.symbol)
                }
                .help(candidate.detail)
            }
        } label: {
            Label(mode.title, systemImage: mode.symbol)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(tint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(mode.title): \(mode.detail)\nPress ⇧Tab in the message field to switch.")
        .accessibilityLabel("Permission mode: \(mode.title)")
    }
}

/// The external agent's own mode (`session/set_mode`), visibly separate from Umbra's
/// `PermissionMode` chip: the agent's modes are agent-defined, local gating stays Umbra's.
struct IDEACPModeChip: View {
    let conversation: IDEAgentConversation

    var body: some View {
        if conversation.acpAvailableModes.isEmpty {
            Text(conversation.acpAgentName ?? "ACP agent")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
        } else {
            Menu {
                ForEach(conversation.acpAvailableModes, id: \.id) { candidate in
                    Button {
                        conversation.setACPMode(candidate.id)
                    } label: {
                        if candidate.id == conversation.acpCurrentModeID {
                            Label(candidate.name, systemImage: "checkmark")
                        } else {
                            Text(candidate.name)
                        }
                    }
                    .help(candidate.description ?? candidate.name)
                }
            } label: {
                Label(
                    conversation.acpAvailableModes.first { $0.id == conversation.acpCurrentModeID }?.name ?? "Agent mode",
                    systemImage: "person.crop.circle")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.accent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("The external agent's mode. Umbra's permission mode (left) still gates file and terminal effects on this Mac.")
            .accessibilityLabel("ACP agent mode")
        }
    }
}

/// Options the connected agent advertised. A select option can be changed. An option
/// with no advertised values is shown as text, so Umbra does not invent a model list.
struct IDEACPConfigChip: View {
    let conversation: IDEAgentConversation

    var body: some View {
        Menu {
            ForEach(conversation.acpConfigOptions, id: \.id) { option in
                let choices = option.selectableChoices
                if choices.isEmpty {
                    Text("\(option.name): \(option.currentValueDescription ?? "—")")
                } else {
                    Menu(option.name) {
                        ForEach(choices, id: \.value) { choice in
                            Button {
                                conversation.setACPConfig(id: option.id, value: choice.value)
                            } label: {
                                if choice.value == option.currentValueDescription {
                                    Label(choice.title, systemImage: "checkmark")
                                } else {
                                    Text(choice.title)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Label(label, systemImage: "slider.horizontal.3")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model, mode and other options this agent advertised.")
        .accessibilityLabel("Agent configuration: \(label)")
    }

    private var label: String {
        let model = conversation.acpConfigOptions.first {
            $0.id == "model" || $0.name.compare("model", options: .caseInsensitive) == .orderedSame
        }
        if let model, let value = model.currentValueDescription, !value.isEmpty { return value }
        return "Config"
    }
}

/// The model this chat uses. Opens agent settings, where the model and provider are chosen.
struct IDEAgentModelChip: View {
    let settings: IDEAgentSettings
    let openSettings: () -> Void

    private var title: String {
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? settings.provider.title : model
    }

    var body: some View {
        Button(action: openSettings) {
            Text(title)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: 180)
        .help(settings.provider.title)
        .accessibilityLabel("Model: \(title)")
    }
}

// MARK: - Entries
