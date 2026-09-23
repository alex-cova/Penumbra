import SwiftUI

struct IDESidebarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @Bindable private var preferences = IDEPreferences.shared
    @State private var isSearchPresented = false
    @State private var searchQuery = ""
    @State private var collapsedWhileFiltering: Set<String> = []
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text("Explorer")
                    .font(IDEAppearance.Typography.sidebarHeader)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if workspace.project.rootNode != nil {
                    IDEExplorerToolbarButton(
                        systemImage: "doc.badge.plus",
                        help: "New File",
                        action: { workspace.createExplorerFile() }
                    )
                    IDEExplorerToolbarButton(
                        systemImage: "folder.badge.plus",
                        help: "New Folder",
                        action: { workspace.createExplorerFolder() }
                    )
                    IDEExplorerToolbarButton(
                        systemImage: "rectangle.expand.vertical",
                        help: "Expand All",
                        action: expandAll
                    )
                    IDEExplorerToolbarButton(
                        systemImage: "rectangle.compress.vertical",
                        help: "Collapse All",
                        action: collapseAll
                    )
                }

                IDEExplorerToolbarButton(
                    systemImage: "magnifyingglass",
                    help: isSearchPresented ? "Hide Search" : "Search",
                    isActive: isSearchPresented,
                    action: toggleSearch
                )
            }
            .padding(.leading, IDEAppearance.Spacing.lg)
            .padding(.trailing, IDEAppearance.Spacing.xs)
            .frame(height: IDEAppearance.Spacing.tabHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                Toggle("Flatten Packages", isOn: $preferences.flattenJavaPackages)
                Toggle("Auto-Reveal Active File", isOn: $preferences.explorerAutoReveal)
            }

            if isSearchPresented {
                IDEExplorerSearchField(query: $searchQuery, isFocused: $isSearchFocused, onDismiss: dismissSearch)
                    .padding(.horizontal, IDEAppearance.Spacing.sm)
                    .padding(.bottom, IDEAppearance.Spacing.sm)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)

            IDEFileTreeView(
                project: workspace.project,
                onOpenFile: { url in
                    Task { await workspace.openDocument(from: url) }
                },
                flattenPackages: preferences.flattenJavaPackages,
                javaSourceRootPaths: workspace.javaSupport.javaSourceRootPaths,
                nameFilter: searchQuery,
                gitStatus: workspace.gitStatus,
                openPaths: workspace.openDocumentPaths,
                actions: IDEFileTreeActions(
                    newItem: { workspace.createExplorerItem(in: $0, isDirectory: $1) },
                    beginRename: { workspace.beginExplorerRename($0) },
                    commitRename: { workspace.commitExplorerRename(of: $0, to: $1) },
                    cancelRename: { workspace.cancelExplorerRename() },
                    duplicate: { workspace.duplicateExplorerItem($0) },
                    trash: { workspace.trashExplorerItem($0) },
                    copyPath: { workspace.copyExplorerPath($0, relative: $1) }
                ),
                collapsedWhileFiltering: $collapsedWhileFiltering
            )
        }
        .onChange(of: workspace.project.revealRequest) { _, request in
            // A filter would hide the revealed row.
            if request?.centered == true, !searchQuery.isEmpty { searchQuery.removeAll() }
        }
        .onChange(of: searchQuery) { _, _ in
            collapsedWhileFiltering.removeAll()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IDEAppearance.ColorToken.sidebar)
    }

    private func toggleSearch() {
        if isSearchPresented {
            dismissSearch()
        } else {
            withAnimation(.easeOut(duration: 0.16)) {
                isSearchPresented = true
            }
        }
    }

    private func dismissSearch() {
        guard isSearchPresented else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            isSearchPresented = false
            searchQuery.removeAll()
        }
        isSearchFocused = false
        workspace.focusActiveEditor()
    }

    private func expandAll() {
        workspace.project.expandAll()
        collapsedWhileFiltering.removeAll()
    }

    private func collapseAll() {
        workspace.project.collapseAll()
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        collapsedWhileFiltering = needle.isEmpty ? [] : workspace.project.allDirectoryPaths()
    }
}

private struct IDEExplorerToolbarButton: View {
    let systemImage: String
    let help: String
    var isActive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph, weight: .medium))
                .foregroundStyle(isActive || isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
                .background(buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .focusable(false)
    }

    private var buttonBackground: Color {
        if isActive {
            return IDEAppearance.ColorToken.selection
        }
        return isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear
    }
}

private struct IDEExplorerSearchField: View {
    @Binding var query: String
    var isFocused: FocusState<Bool>.Binding
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .accessibilityHidden(true)

            TextField("Search files", text: $query)
                .textFieldStyle(.plain)
                .font(IDEAppearance.Typography.tabLabel)
                .focused(isFocused)
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }

            if !query.isEmpty {
                Button {
                    query.removeAll()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .frame(height: 24)
        .background(IDEAppearance.ColorToken.editor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous)
                .strokeBorder(
                    isFocused.wrappedValue ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.border,
                    lineWidth: 1
                )
        }
        .task { isFocused.wrappedValue = true }
        .onExitCommand(perform: onDismiss)
    }
}

#Preview {
    IDESidebarPanel()
        .environment({
            let workspace = IDEWorkspace()
            workspace.project.setRoot(URL(fileURLWithPath: #filePath).deletingLastPathComponent())
            return workspace
        }())
        .frame(width: 240, height: 480)
        .preferredColorScheme(.dark)
}
