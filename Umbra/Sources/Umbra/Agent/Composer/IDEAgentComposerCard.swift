import SwiftUI

enum IDEAgentComposerMetrics {
    /// The message box's corners; AI mode's project tray uses the same, and is overlapped by that much.
    static let cornerRadius: CGFloat = 14
}

/// The message box, laid out like Codex's: one rounded card with the text on top (growing up to
/// `IDEAgentComposerField.maxTextHeight`, so the card stops at about 340 pt) and a bar inside the card below it,
/// `leading` controls on the left, `trailing` ones on the right, then the round send/stop button. A click on the
/// card's empty space puts the caret in the field.
struct IDEAgentComposerCard<Field: View, Leading: View, Trailing: View>: View {
    let isRunning: Bool
    let canSend: Bool
    let send: () -> Void
    let stop: () -> Void
    let focus: () -> Void
    @ViewBuilder let field: () -> Field
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            field()
                .padding(.horizontal, IDEAppearance.Spacing.xs)
            HStack(spacing: IDEAppearance.Spacing.sm) {
                // First pick of the width, so a leading row with its own spacer (the agent's chips) reaches the
                // send button instead of sharing the gap with the spacer below.
                HStack(spacing: IDEAppearance.Spacing.sm) { leading() }
                    .layoutPriority(1)
                Spacer(minLength: 0)
                trailing()
                IDEAgentSendButton(isRunning: isRunning, canSend: canSend, send: send, stop: stop)
            }
        }
        .padding(.top, IDEAppearance.Spacing.md)
        .padding(.horizontal, IDEAppearance.Spacing.cozy)
        .padding(.bottom, IDEAppearance.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: IDEAgentComposerMetrics.cornerRadius, style: .continuous)
                .fill(IDEAppearance.ColorToken.card)
                .onTapGesture(perform: focus)
        }
        .overlay(
            RoundedRectangle(cornerRadius: IDEAgentComposerMetrics.cornerRadius, style: .continuous)
                .stroke(IDEAppearance.ColorToken.border, lineWidth: 1)
                .allowsHitTesting(false))
    }
}

/// The filled round button at the end of the composer bar: an arrow to send, a square to stop.
struct IDEAgentSendButton: View {
    let isRunning: Bool
    let canSend: Bool
    let send: () -> Void
    let stop: () -> Void

    private var isEnabled: Bool { isRunning || canSend }

    var body: some View {
        Button(action: isRunning ? stop : send) {
            Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: isRunning ? 10 : 12, weight: .bold))
                .foregroundStyle(isEnabled ? IDEAppearance.ColorToken.card : IDEAppearance.ColorToken.muted)
                .frame(width: 26, height: 26)
                .background(Circle().fill(isEnabled ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.controlHover))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isRunning ? "Stop (Esc)" : "Send (Return)")
        .accessibilityLabel(isRunning ? "Stop" : "Send")
        .accessibilityIdentifier(isRunning ? IDEACPAccessibility.stop : IDEACPAccessibility.send)
    }
}
