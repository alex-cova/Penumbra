import SwiftUI

/// The narrow icon column on the window's left or right edge (IntelliJ's tool window bar,
/// VS Code's activity bar). Each button opens or hides one tool window; the top group holds side
/// panels, the bottom group the bottom-panel tabs.
struct IDEToolWindowStripe: View {
    enum Edge {
        case leading
        case trailing
    }

    let edge: Edge

    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        IDEToolWindowStripeLegacy(
            edge: edge,
            topItems: topItems,
            bottomItems: bottomItems
        )
    }

    /// True when the stripe has any button; the right stripe is left out otherwise.
    static func hasItems(edge: Edge, workspace: IDEWorkspace) -> Bool {
        let items = IDEToolWindowStripe(edge: edge).items(workspace)
        return !items.top.isEmpty || !items.bottom.isEmpty
    }

    private var topItems: [IDEToolWindowStripeItem] { items(workspace).top }
    private var bottomItems: [IDEToolWindowStripeItem] { items(workspace).bottom }

    private func items(_ workspace: IDEWorkspace) -> (top: [IDEToolWindowStripeItem], bottom: [IDEToolWindowStripeItem]) {
        switch edge {
        case .leading:
            // The whole leading stripe stays hidden until a folder or a file is open.
            let hasContent = workspace.hasOpenProject || workspace.hasOpenDocuments
            guard hasContent else { return ([], []) }

            var top: [IDEToolWindowStripeItem] = [
                IDEToolWindowStripeItem(
                    id: "explorer", systemImage: "folder", title: "Explorer",
                    isOpen: workspace.showsSidebar, action: workspace.toggleSidebar
                ),
                IDEToolWindowStripeItem(
                    id: "find", systemImage: "magnifyingglass", title: "Find in Files",
                    isOpen: workspace.isFindInFilesVisible, action: workspace.toggleFindInFiles
                ),
            ]
            if workspace.showsJavaStructureButton {
                top.append(IDEToolWindowStripeItem(
                    id: "structure", systemImage: "list.bullet.indent", title: "Structure",
                    isOpen: workspace.showsStructureSidebar, action: workspace.toggleStructureSidebar
                ))
            }
            if workspace.showsSourceControlTab {
                top.append(bottomItem(.sourceControl, "arrow.triangle.branch", "Source Control", workspace))
            }

            var bottom: [IDEToolWindowStripeItem] = []
            if workspace.showsDebugTab {
                bottom.append(bottomItem(.debug, "ladybug", "Debug", workspace))
            }
            if workspace.showsTestResultsTab {
                bottom.append(bottomItem(.testResults, "flask", "Test Results", workspace))
            }
            if workspace.showsUsagesTab {
                bottom.append(bottomItem(.usages, "text.magnifyingglass", "Usages", workspace))
            }
            if workspace.showsTypeHierarchyTab {
                bottom.append(bottomItem(.typeHierarchy, "list.bullet.indent", "Hierarchy", workspace))
            }
            if workspace.showsCallHierarchyTab {
                bottom.append(bottomItem(.callHierarchy, "phone.arrow.down.left", "Call Hierarchy", workspace))
            }
            bottom.append(bottomItem(.problems, "exclamationmark.triangle", "Problems", workspace))
            bottom.append(bottomItem(.terminal, "terminal", "Terminal", workspace))
            return (top, bottom)

        case .trailing:
            var top: [IDEToolWindowStripeItem] = []
            if workspace.javaSupport.isGradleProject {
                top.append(IDEToolWindowStripeItem(
                    id: "gradle", systemImage: "square.stack.3d.up", title: "Gradle",
                    isOpen: workspace.showsGradleSidebar, action: workspace.toggleGradleSidebar
                ))
            }
            var bottom: [IDEToolWindowStripeItem] = []
            if workspace.showsGradleConsoleTab {
                bottom.append(bottomItem(.gradle, "text.alignleft", "Gradle Console", workspace))
            }
            if workspace.showsHTTPTab {
                bottom.append(bottomItem(.http, "network", "HTTP Response", workspace))
            }
            return (top, bottom)
        }
    }

    private func bottomItem(
        _ tab: IDEBottomPanelTab,
        _ systemImage: String,
        _ title: String,
        _ workspace: IDEWorkspace
    ) -> IDEToolWindowStripeItem {
        IDEToolWindowStripeItem(
            id: "\(tab)", systemImage: systemImage, title: title,
            isOpen: workspace.isBottomToolWindowOpen(tab),
            action: { workspace.toggleBottomToolWindow(tab) }
        )
    }
}

struct IDEToolWindowStripeItem: Identifiable {
    let id: String
    let systemImage: String
    let title: String
    let isOpen: Bool
    let action: () -> Void
}

private struct IDEToolWindowStripeLegacy: View {
    let edge: IDEToolWindowStripe.Edge
    let topItems: [IDEToolWindowStripeItem]
    let bottomItems: [IDEToolWindowStripeItem]

    var body: some View {
        VStack(spacing: IDEAppearance.Spacing.xs) {
            ForEach(topItems) { IDEToolWindowStripeLegacyButton(item: $0) }
            Spacer(minLength: IDEAppearance.Spacing.sm)
            ForEach(bottomItems) { IDEToolWindowStripeLegacyButton(item: $0) }
        }
        .padding(.vertical, IDEAppearance.Spacing.sm)
        .frame(width: IDEAppearance.Spacing.toolWindowStripeWidth)
        .frame(maxHeight: .infinity)
        .background(IDEAppearance.ColorToken.frame)
        .focusable(false)
    }
}

private struct IDEToolWindowStripeButtonLabel: View {
    let item: IDEToolWindowStripeItem

    var body: some View {
        Image(systemName: item.systemImage)
            .font(.system(size: IDEAppearance.IconSize.toolWindowGlyph, weight: .regular))
            .frame(width: IDEAppearance.Spacing.toolWindowButton, height: IDEAppearance.Spacing.toolWindowButton)
            .contentShape(Rectangle())
    }
}

private struct IDEToolWindowStripeLegacyButton: View {
    let item: IDEToolWindowStripeItem

    @State private var isHovering = false

    var body: some View {
        Button(action: item.action) {
            IDEToolWindowStripeButtonLabel(item: item)
                .foregroundStyle(item.isOpen || isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(item.isOpen ? "Hide \(item.title)" : item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(item.isOpen ? [.isButton, .isSelected] : .isButton)
        .focusable(false)
    }

    @ViewBuilder
    private var background: some View {
        if item.isOpen {
            RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous)
                .fill(Color.white.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                }
        } else if isHovering {
            RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous)
                .fill(IDEAppearance.ColorToken.controlHover)
        } else {
            Color.clear
        }
    }
}

#Preview {
    HStack(spacing: 0) {
        IDEToolWindowStripe(edge: .leading)
        Color.clear
    }
    .environment(IDEWorkspace())
    .frame(width: 300, height: 480)
    .preferredColorScheme(.dark)
}
