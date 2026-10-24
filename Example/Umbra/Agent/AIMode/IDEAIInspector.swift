import SwiftUI

/// The tabs of AI mode's panel to the right of Code's conversation.
enum IDEAIInspectorTab: String, Codable, CaseIterable, Identifiable, Sendable {
    case changes
    case plan
    case browser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .changes: "Changes"
        case .plan: "Plan"
        case .browser: "Browser"
        }
    }

    var symbolName: String {
        switch self {
        case .changes: "plusminus.circle"
        case .plan: "list.bullet.clipboard"
        case .browser: "globe"
        }
    }
}

/// Changes (what this chat's agent edited), Plan (the plan and the checklist) and Browser (a page, such as
/// the dev server the agent started), beside the conversation like Cursor's agent panel. Code only: Chat
/// has no project, files or plan.
struct IDEAIInspector: View {
    @Environment(IDEWorkspace.self) private var workspace

    static let defaultWidth: Double = 380

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Group {
                switch workspace.aiInspectorTab {
                case .changes: IDEAIChangesTab()
                case .plan: IDEAIPlanTab()
                case .browser: IDEAIBrowserTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IDEAppearance.ColorToken.panel)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(IDEAIInspectorTab.allCases) { tab in
                IDEAIInspectorTabItem(
                    tab: tab,
                    isSelected: tab == workspace.aiInspectorTab,
                    badge: badge(for: tab),
                    onSelect: { workspace.aiInspectorTab = tab })
            }
            Spacer(minLength: 0)
            Button {
                workspace.showsAIInspector = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: IDEAppearance.IconSize.toolbarGlyph - 2, weight: .medium))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide this panel")
            .accessibilityLabel("Hide Changes, Plan and Browser")
        }
        .padding(.horizontal, IDEAppearance.Spacing.xs)
        .frame(height: IDEAppearance.Spacing.tabHeight + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Files changed in this chat, or the checklist's progress.
    private func badge(for tab: IDEAIInspectorTab) -> String? {
        switch tab {
        case .changes:
            let count = IDEAIChangedFiles.summarize(workspace.agent.selected.entries).filter { !$0.isReverted }.count
            return count > 0 ? "\(count)" : nil
        case .plan:
            let todos = workspace.agent.selected.todos
            guard !todos.isEmpty else { return nil }
            return "\(todos.filter { $0.status == .completed }.count)/\(todos.count)"
        case .browser:
            return nil
        }
    }
}

/// The selected tab shows its title and badge; the others are icons, as in the left sidebar.
private struct IDEAIInspectorTabItem: View {
    let tab: IDEAIInspectorTab
    let isSelected: Bool
    let badge: String?
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected || isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .frame(width: 14)
            if isSelected {
                Text(tab.title)
                    .font(IDEAppearance.Typography.panelTab)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
            }
            if let badge {
                Text(badge)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
        .padding(.horizontal, isSelected ? IDEAppearance.Spacing.sm : 6)
        .frame(minHeight: IDEAppearance.Spacing.iconButton - 2)
        .background(
            isSelected ? IDEAppearance.ColorToken.card : (isHovering ? IDEAppearance.ColorToken.controlHover : .clear),
            in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(badge.map { "\(tab.title) (\($0))" } ?? tab.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.map { "\(tab.title), \($0)" } ?? tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .focusable(false)
    }
}
