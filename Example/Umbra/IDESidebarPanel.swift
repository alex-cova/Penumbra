import SwiftUI

struct IDESidebarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace
    @Bindable private var preferences = IDEPreferences.shared
    @State private var isSearchPresented = false
    @State private var searchQuery = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Text("Explorer")
                    .font(IDEAppearance.Typography.sidebarHeader)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                IDEExplorerSearchButton(isPresented: isSearchPresented, action: toggleSearch)
            }
            .padding(.leading, IDEAppearance.Spacing.lg)
            .padding(.trailing, IDEAppearance.Spacing.xs)
            .frame(height: IDEAppearance.Spacing.tabHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                Toggle("Flatten Packages", isOn: $preferences.flattenJavaPackages)
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
                nameFilter: searchQuery
            )
            .focusable(false)
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
}

private struct IDEExplorerSearchButton: View {
    let isPresented: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph, weight: .medium))
                .foregroundStyle(isPresented || isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
                .background(buttonBackground)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isPresented ? .isSelected : [])
        .focusable(false)
    }

    private var help: String {
        isPresented ? "Hide Search" : "Search"
    }

    private var buttonBackground: Color {
        if isPresented {
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
