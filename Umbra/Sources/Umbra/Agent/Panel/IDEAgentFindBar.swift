import SwiftUI

/// Find in the agent transcript (⌘F while the panel has the keyboard): a field, "3 of 12", previous and
/// next. Return goes to the next match, ⇧Return to the previous, Escape closes the bar.
struct IDEAgentFindBar: View {
    @Binding var query: String
    let position: String
    let hasMatches: Bool
    /// Bumped to put the keyboard in the field again (⌘F while the bar is open).
    let focusRequest: Int
    let step: (Int) -> Void
    let close: () -> Void
    /// Told whenever the field gains or loses the keyboard (⌘F stays in the chat only while it has it).
    var focusChanged: (Bool) -> Void = { _ in }

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            TextField("Find in chat", text: $query)
                .textFieldStyle(.plain)
                .font(IDEAppearance.Typography.body)
                .focused($isFocused)
                .onKeyPress(.return, phases: .down) { press in
                    step(press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
                .accessibilityLabel("Find in chat")
            if !query.isEmpty {
                Text(position)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(hasMatches ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.error)
                    .monospacedDigit()
                    .fixedSize()
            }
            IDEIconButton(systemImage: "chevron.up", help: "Previous Match (⇧↩)", isDisabled: !hasMatches) { step(-1) }
            IDEIconButton(systemImage: "chevron.down", help: "Next Match (↩)", isDisabled: !hasMatches) { step(1) }
            IDEIconButton(systemImage: "xmark", help: "Close (Esc)") { close() }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.bottom, IDEAppearance.Spacing.xs)
        .onAppear { isFocused = true }
        .onChange(of: focusRequest) { isFocused = true }
        .onChange(of: isFocused) { focusChanged(isFocused) }
        .onDisappear { focusChanged(false) }
    }
}

/// Where the transcript's scroll view stands, for the views that draw it (the minimap's band). Kept in an
/// object of its own so a scrolled frame redraws only those, not the panel.
@MainActor @Observable
final class IDEAgentScrollPosition {
    var metrics = IDEAgentScrollMetrics(offset: 0, contentHeight: 0, viewportHeight: 0)

    /// The visible part as shares of the content: (top, bottom), both in 0…1.
    var visibleRange: (top: Double, bottom: Double) {
        guard metrics.contentHeight > 0 else { return (0, 1) }
        let top = max(0, metrics.offset / metrics.contentHeight)
        let bottom = min(1, (metrics.offset + metrics.viewportHeight) / metrics.contentHeight)
        return (Double(top), Double(max(top, bottom)))
    }
}

/// A thin rail on the transcript's trailing edge: a tick per user message (accent when that turn changed
/// files, orange when it waits for you) and a band for what is on screen. A tick names its prompt and the
/// turn's last reply, and a click scrolls there.
struct IDEAgentMinimapRail: View {
    let items: [IDEAgentMinimapItem]
    let position: IDEAgentScrollPosition
    let select: (UUID) -> Void

    static let width: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let range = position.visibleRange
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(IDEAppearance.ColorToken.muted.opacity(0.28))
                    .frame(width: 6, height: max(8, (range.bottom - range.top) * height))
                    .offset(y: range.top * height)
                    .accessibilityHidden(true)
                ForEach(items) { item in
                    Button { select(item.id) } label: {
                        Capsule()
                            .fill(color(item))
                            .frame(width: 8, height: 2)
                            .frame(width: Self.width, height: 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(y: min(max(0, item.position * height - 4), height - 8))
                    .help(item.reply.map { "\(item.prompt)\n→ \($0)" } ?? item.prompt)
                    .accessibilityLabel("Go to: \(item.prompt)")
                }
            }
            .frame(width: Self.width, height: height, alignment: .top)
        }
        .frame(width: Self.width)
        .padding(.vertical, IDEAppearance.Spacing.sm)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Messages in this chat")
    }

    private func color(_ item: IDEAgentMinimapItem) -> Color {
        if item.isWaiting { return .orange }
        if item.changedFiles { return IDEAppearance.ColorToken.accent }
        return IDEAppearance.ColorToken.muted
    }
}
