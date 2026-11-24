import SwiftUI

/// Where a transcript's scroll view stands: what decides whether it follows new output.
struct IDEAgentScrollMetrics: Equatable {
    var offset: CGFloat
    var contentHeight: CGFloat
    var viewportHeight: CGFloat

    var distanceFromBottom: CGFloat { contentHeight - (offset + viewportHeight) }
    var isAtBottom: Bool { distanceFromBottom <= IDEAgentScrollPin.tolerance }
}

/// Whether a transcript follows new output. It does while the user is at the bottom; scrolling up stops
/// it, and coming back down (or sending) starts it again. Growth of the content never stops it: that is
/// the output it is following.
enum IDEAgentScrollPin {
    static let tolerance: CGFloat = 40

    static func isPinned(wasPinned: Bool, from old: IDEAgentScrollMetrics, to new: IDEAgentScrollMetrics, userIsScrolling: Bool) -> Bool {
        if new.isAtBottom { return true }
        if userIsScrolling { return false }
        // Moved up while nothing else changed: a scroll wheel that reported no scroll phase.
        let sameLayout = abs(new.contentHeight - old.contentHeight) < 0.5 && abs(new.viewportHeight - old.viewportHeight) < 0.5
        if sameLayout, new.offset < old.offset - 0.5 { return false }
        return wasPinned
    }
}

/// A transcript's scroll view: it stays at the newest output while pinned, and otherwise shows a pill
/// that brings you back down ("New activity" once something arrived, or the caller's `attention`).
struct IDEAgentFollowingScrollView<Content: View>: View {
    /// A change scrolls down and pins again: the chat shown.
    var resetKey: AnyHashable
    /// A change scrolls down and pins again: the user's latest message, so sending brings the view down.
    var pinKey: AnyHashable?
    /// What the pill says when something needs the user ("Waiting for you").
    var attention: String?
    /// Set to an entry's id to bring it to the middle of the view; reset to nil once done.
    var scrollTarget: Binding<UUID?> = .constant(nil)
    /// Told where the view stands on every scroll, for a view that draws it (the minimap's band).
    var position: IDEAgentScrollPosition?
    @ViewBuilder var content: () -> Content

    @State private var isPinned = true
    @State private var hasNewActivity = false
    @State private var isUserScrolling = false
    @State private var metrics = IDEAgentScrollMetrics(offset: 0, contentHeight: 0, viewportHeight: 0)

    private static var bottomID: String { "agent-transcript-bottom" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    content()
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
            }
            .onScrollPhaseChange { _, phase in
                isUserScrolling = phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: IDEAgentScrollMetrics.self) { geometry in
                IDEAgentScrollMetrics(
                    offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                    viewportHeight: geometry.containerSize.height)
            } action: { old, new in
                metrics = new
                if let position, position.metrics != new { position.metrics = new }
                let pinned = IDEAgentScrollPin.isPinned(wasPinned: isPinned, from: old, to: new, userIsScrolling: isUserScrolling)
                if pinned != isPinned { isPinned = pinned }
                if pinned {
                    if hasNewActivity { hasNewActivity = false }
                    if !new.isAtBottom, new.contentHeight > old.contentHeight { scrollToBottom(proxy) }
                } else if new.contentHeight > old.contentHeight + 0.5, !isUserScrolling, !hasNewActivity {
                    hasNewActivity = true
                }
            }
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: resetKey) { pin(proxy) }
            .onChange(of: pinKey) { pin(proxy) }
            .onChange(of: scrollTarget.wrappedValue) {
                guard let target = scrollTarget.wrappedValue else { return }
                IDEAppearance.Motion.animate(IDEAppearance.Motion.standard) { proxy.scrollTo(target, anchor: .center) }
                scrollTarget.wrappedValue = nil
            }
            .overlay(alignment: .bottom) {
                if !isPinned {
                    pill { pin(proxy) }
                        .padding(.bottom, IDEAppearance.Spacing.sm)
                        .ideTransition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .ideAnimation(IDEAppearance.Motion.standard, value: isPinned)
        }
    }

    private func pin(_ proxy: ScrollViewProxy) {
        isPinned = true
        hasNewActivity = false
        scrollToBottom(proxy)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
    }

    private func pill(_ action: @escaping () -> Void) -> some View {
        let label = attention ?? (hasNewActivity ? "New activity" : "Jump to latest")
        return Button(action: action) {
            Label(label, systemImage: "arrow.down")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(attention == nil ? IDEAppearance.ColorToken.foreground : Color.orange)
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, IDEAppearance.Spacing.xs)
                .background(IDEAppearance.ColorToken.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(IDEAppearance.ColorToken.border))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Scroll to the newest message and follow new output")
        .accessibilityLabel(label)
    }
}
