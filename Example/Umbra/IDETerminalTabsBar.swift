import SwiftUI

struct IDETerminalTabsBar: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(workspace.terminalTabs) { tab in
                    IDETerminalTabItem(
                        tab: tab,
                        isSelected: workspace.isTerminalTabSelected
                            && tab.id == workspace.selectedTerminalTabID,
                        onSelect: { workspace.selectTerminalTab(tab.id) },
                        onClose: { workspace.closeTerminalTab(tab.id) }
                    )
                }
                if workspace.showsRunTab {
                    IDERunTabItem(
                        isSelected: workspace.isRunSelected,
                        isRunning: workspace.runs.isAnyActive,
                        onSelect: { workspace.selectRunTab() }
                    )
                }
                if workspace.showsGradleConsoleTab {
                    IDEGradleTabItem(
                        isSelected: workspace.isGradleConsoleSelected,
                        isSyncing: workspace.javaSupport.isGradleBusy,
                        isFailed: workspace.javaSupport.gradleSync.isFailed,
                        onSelect: { workspace.selectGradleConsoleTab() }
                    )
                }
                if workspace.showsHTTPTab {
                    IDEHTTPTabItem(
                        isSelected: workspace.isHTTPConsoleSelected,
                        isSending: workspace.httpSupport.isSending,
                        onSelect: { workspace.selectHTTPConsoleTab() }
                    )
                }
                if workspace.showsProblemsTab {
                    IDEProblemsTabItem(
                        isSelected: workspace.isProblemsSelected,
                        errorCount: workspace.problems.errorCount,
                        warningCount: workspace.problems.warningCount,
                        onSelect: { workspace.selectProblemsTab() }
                    )
                }
                if workspace.showsTypeHierarchyTab {
                    IDETypeHierarchyTabItem(
                        title: workspace.typeHierarchy.root.map { "Hierarchy · \($0.displayName)" } ?? "Hierarchy",
                        isSelected: workspace.isTypeHierarchySelected,
                        onSelect: { workspace.selectTypeHierarchyTab() }
                    )
                }
                if workspace.showsUsagesTab {
                    IDEUsagesTabItem(
                        title: workspace.usages.isSearching ? "Usages · …" : "Usages · \(workspace.usages.count)",
                        isSelected: workspace.isUsagesSelected,
                        onSelect: { workspace.selectUsagesTab() }
                    )
                }
                if workspace.showsTestResultsTab {
                    IDETestResultsTabItem(
                        title: workspace.testResults.isRunning
                            ? "Tests · …"
                            : "Tests · \(workspace.testResults.passedCount)/\(workspace.testResults.passedCount + workspace.testResults.failedCount + workspace.testResults.skippedCount)",
                        isSelected: workspace.isTestResultsSelected,
                        onSelect: { workspace.selectTestResultsTab() }
                    )
                }
                if workspace.showsDebugTab {
                    IDEDebugTabItem(
                        isSelected: workspace.isDebugSelected,
                        onSelect: { workspace.selectDebugTab() }
                    )
                }
                if workspace.showsCallHierarchyTab {
                    IDECallHierarchyTabItem(
                        title: workspace.callHierarchy.root.map { "Calls · \($0.displayName)" } ?? "Calls",
                        isSelected: workspace.isCallHierarchySelected,
                        onSelect: { workspace.selectCallHierarchyTab() }
                    )
                }
                if workspace.showsSourceControlTab {
                    IDESourceControlTabItem(
                        isSelected: workspace.isSourceControlSelected,
                        onSelect: { workspace.selectSourceControlTab() }
                    )
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
        }
        .frame(height: IDEAppearance.Spacing.tabHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IDETerminalTabItem: View {
    let tab: IDETerminalTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    private let trailingSlotSide: CGFloat = 14

    var body: some View {
        IDEChromeTabItem(title: tab.title, isSelected: isSelected, onSelect: onSelect) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        } trailing: {
            IDEChromeTabCloseButton(side: trailingSlotSide, onClose: onClose)
        }
    }
}

/// The bottom panel's read-only "Gradle" console tab -- always last, no close button (it comes and
/// goes with `IDEWorkspace.showsGradleConsoleTab`, not by user action).
private struct IDEGradleTabItem: View {
    let isSelected: Bool
    let isSyncing: Bool
    let isFailed: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            statusIcon
                .frame(width: 12)

            Text("Gradle")
                .foregroundStyle(isSelected ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .font(IDEAppearance.Typography.tabLabel.weight(isSelected ? .medium : .regular))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .overlay(alignment: .top) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(IDEAppearance.ColorToken.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isSyncing ? "Gradle, syncing" : isFailed ? "Gradle, sync failed" : "Gradle")
        .accessibilityAddTraits(.isButton)
        .focusable(false)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isSyncing {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
        } else if isFailed {
            Image(systemName: "hammer.fill")
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.error)
        } else {
            Image(systemName: "hammer")
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return IDEAppearance.ColorToken.tabActive
        }
        if isHovering {
            return IDEAppearance.ColorToken.tabHover
        }
        return IDEAppearance.ColorToken.tabInactive
    }
}

private struct IDEHTTPTabItem: View {
    let isSelected: Bool
    let isSending: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: "paperplane")
                        .font(.system(size: 10))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            .frame(width: 12)

            Text("HTTP")
                .foregroundStyle(isSelected ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .font(IDEAppearance.Typography.tabLabel.weight(isSelected ? .medium : .regular))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .overlay(alignment: .top) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(IDEAppearance.ColorToken.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isSending ? "HTTP, sending" : "HTTP")
        .accessibilityAddTraits(.isButton)
        .focusable(false)
    }

    private var backgroundColor: Color {
        if isSelected {
            return IDEAppearance.ColorToken.tabActive
        }
        if isHovering {
            return IDEAppearance.ColorToken.tabHover
        }
        return IDEAppearance.ColorToken.tabInactive
    }
}

/// The bottom panel's History tab (the commit graph); the working tree's changes are in the sidebar.
private struct IDESourceControlTabItem: View {
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 12)

            Text("History")
                .foregroundStyle(isSelected ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .font(IDEAppearance.Typography.tabLabel.weight(isSelected ? .medium : .regular))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .overlay(alignment: .top) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(IDEAppearance.ColorToken.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Git History")
        .accessibilityAddTraits(.isButton)
        .focusable(false)
    }

    private var backgroundColor: Color {
        if isSelected {
            return IDEAppearance.ColorToken.tabActive
        }
        if isHovering {
            return IDEAppearance.ColorToken.tabHover
        }
        return IDEAppearance.ColorToken.tabInactive
    }
}
