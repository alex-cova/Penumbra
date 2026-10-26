import AppKit
import SwiftUI

/// Explorer file actions supplied by the workspace. `nil` (previews) hides the editing menu items.
struct IDEFileTreeActions {
    var newItem: (_ directory: URL, _ isDirectory: Bool) -> Void
    var beginRename: (URL) -> Void
    var commitRename: (_ url: URL, _ name: String) -> Void
    var cancelRename: () -> Void
    var duplicate: (URL) -> Void
    var trash: (URL) -> Void
    var copyPathReference: (URL) -> Void
    var findInFiles: (_ directory: URL) -> Void
    var showHistory: (URL) -> Void
    var openOnWeb: (_ url: URL, _ copy: Bool) -> Void
    var addToIgnoreFile: (_ url: URL, _ localOnly: Bool) -> Void
    var showClassDiagram: (URL) -> Void
    var inspectCode: (URL) -> Void
}

struct IDEFileTreeView: View {
    let project: IDEProjectModel
    let onOpenFile: (URL) -> Void
    var flattenPackages = false
    var javaSourceRootPaths: Set<String> = []
    var sortOrder: IDEExplorerSortOrder = .name
    var foldersOnTop = true
    var showExcludedFiles = true
    var compactMiddlePackages = false
    var nameFilter = ""
    var gitStatus: IDEGitStatusModel?
    var openPaths: Set<String> = []
    /// Files whose open buffer has unsaved changes, dotted like their tab (Mark Modified).
    var unsavedPaths: Set<String> = []
    var actions: IDEFileTreeActions?
    /// The External Libraries section; `nil` leaves it out.
    var externalLibraries: IDEExternalLibrariesModel?
    var onOpenLibraryItem: ((IDEExternalLibraryItem) -> Void)?
    var onCopyLibraryName: ((IDEExternalLibraryItem) -> Void)?
    /// Folders opened so a match stays visible. Collapsing one hides that branch until the query
    /// changes; it does not rewrite the project's own expansion state.
    @Binding var collapsedWhileFiltering: Set<String>

    var body: some View {
        Group {
            if let root = project.rootNode {
                let displayRoot = flattenPackages
                    ? IDEFlattenedPackages.flatten(root, sourceRootPaths: javaSourceRootPaths)
                    : root
                let nodes = flattenedNodes(root: displayRoot)
                let libraryRows = externalLibraries?.rows(filter: filterNeedle) ?? []
                if nodes.isEmpty && libraryRows.isEmpty {
                    IDEFileTreeFilterEmptyState()
                } else {
                    GeometryReader { proxy in
                    ScrollViewReader { scroller in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(nodes) { item in
                                IDEFileTreeRow(
                                    node: item.node,
                                    depth: item.depth,
                                    isExpanded: isExpanded(item),
                                    canDisclose: item.canDisclose,
                                    isSelected: project.selectedPath == item.node.id,
                                    isOpen: openPaths.contains(item.node.id),
                                    isUnsaved: unsavedPaths.contains(item.node.id),
                                    isRoot: item.depth == 0,
                                    isExcluded: item.isExcluded,
                                    isRenaming: project.renamingPath == item.node.id,
                                    actions: actions,
                                    filterQuery: filterNeedle,
                                    gitStatus: gitStatus?.status(for: item.node.url, isDirectory: item.node.isDirectory),
                                    folderRole: item.node.isDirectory
                                        ? IDEFlattenedPackages.folderRole(for: item.node.url, sourceRootPaths: javaSourceRootPaths)
                                        : .plain,
                                    onToggle: { toggle(item) },
                                    onSelect: { project.selectedPath = item.node.id },
                                    onOpen: { onOpenFile(item.node.url) }
                                )
                            }
                            ForEach(libraryRows) { item in
                                IDEExternalLibraryRow(
                                    item: item,
                                    isSelected: project.selectedPath == nil && externalLibraries?.selectedID == item.id,
                                    onSelect: { selectLibraryRow(item) },
                                    onToggle: { externalLibraries?.toggle(item.id) },
                                    onOpen: { onOpenLibraryItem?(item) },
                                    onCopyName: { onCopyLibraryName?(item) }
                                )
                            }
                        }
                        .padding(.vertical, IDEAppearance.Spacing.xs)
                        .frame(minWidth: max(proxy.size.width, contentWidth(of: nodes, libraryRows: libraryRows)), minHeight: proxy.size.height, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .contextMenu { creationContextMenu(for: creationDirectory) }
                    }
                    .focusable(actions != nil)
                    .focusEffectDisabled()
                    .onKeyPress(phases: [.down, .repeat]) { press in
                        handleKey(press, nodes: nodes, libraryRows: libraryRows)
                    }
                    .onChange(of: project.revealRequest) { _, request in
                        guard let request else { return }
                        // Let the ancestors' expansion land in the row list before scrolling.
                        Task { @MainActor in
                            scroller.scrollTo(request.path, anchor: request.centered ? .center : nil)
                        }
                    }
                    }
                    }
                }
            } else {
                IDEEmptyState(
                    symbol: "folder.badge.plus",
                    title: project.isRootMissing ? "Folder Not Found" : "No Folder Open",
                    message: project.isRootMissing ? "The project folder was moved or deleted." : "Open a project folder to browse files.")
            }
        }
        .onChange(of: filterNeedle) { _, _ in
            collapsedWhileFiltering.removeAll()
        }
        .onChange(of: externalLibraries?.jdkProvider()?.home) { _, _ in
            externalLibraries?.loadMissingContents()
        }
    }

    /// A `LazyVStack` only measures the rows it has realized, so the scrollable width would change
    /// while scrolling and the horizontal scroller would come and go. Size it from every row instead.
    private func contentWidth(of nodes: [FlatNode], libraryRows: [IDEExternalLibraryItem]) -> CGFloat {
        let font = IDEUIFonts.nsFont(
            familyName: IDEUIFonts.currentFamilyName,
            size: IDEUIFonts.scaledSize(12),
            weight: .semibold
        )
        let chrome = CGFloat(12 + 14 + IDEAppearance.Spacing.xs * 2 + IDEAppearance.Spacing.sm * 2)
        func width(_ name: String, depth: Int) -> CGFloat {
            let textWidth = (name as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
            return CGFloat(depth) * 14 + chrome + textWidth
        }
        let files = nodes.reduce(CGFloat(0)) { widest, item in
            max(widest, width(item.node.displayName ?? item.node.name, depth: item.depth))
        }
        return libraryRows.reduce(files) { widest, item in
            max(widest, width(item.title + (item.subtitle.map { " " + $0 } ?? ""), depth: item.depth))
        }
    }

    private func selectLibraryRow(_ item: IDEExternalLibraryItem) {
        project.selectedPath = nil
        externalLibraries?.selectedID = item.id
    }

    /// Keys while a library row is selected. Up from the first row returns to the last project row.
    private func handleLibraryKey(
        _ press: KeyPress, rows: [IDEExternalLibraryItem], index: Int, nodes: [FlatNode]
    ) -> KeyPress.Result {
        guard let externalLibraries else { return .ignored }
        let current = rows[index]
        func select(_ row: IDEExternalLibraryItem) {
            selectLibraryRow(row)
            project.requestScroll(to: row.id)
        }
        switch press.key {
        case .upArrow:
            if index > 0 {
                select(rows[index - 1])
            } else if let last = nodes.last {
                externalLibraries.selectedID = nil
                project.selectedPath = last.node.id
                project.requestScroll(to: last.node.id)
            }
            return .handled
        case .downArrow where !press.modifiers.contains(.command):
            if index + 1 < rows.count { select(rows[index + 1]) }
            return .handled
        case .downArrow, .return:
            if current.isOpenable {
                onOpenLibraryItem?(current)
            } else if current.canDisclose {
                externalLibraries.toggle(current.id)
            }
            return .handled
        case .rightArrow:
            guard current.canDisclose, !current.isExpanded else { return .ignored }
            externalLibraries.expand(current.id)
            return .handled
        case .leftArrow:
            if current.canDisclose, current.isExpanded {
                externalLibraries.collapse(current.id)
            } else if let parent = rows[..<index].last(where: { $0.depth < current.depth }) {
                select(parent)
            }
            return .handled
        default:
            return .ignored
        }
    }

    private func handleKey(_ press: KeyPress, nodes: [FlatNode], libraryRows: [IDEExternalLibraryItem]) -> KeyPress.Result {
        guard project.renamingPath == nil else { return .ignored }
        if project.selectedPath == nil, let selected = externalLibraries?.selectedID,
           let libraryIndex = libraryRows.firstIndex(where: { $0.id == selected }) {
            return handleLibraryKey(press, rows: libraryRows, index: libraryIndex, nodes: nodes)
        }
        guard !nodes.isEmpty else { return .ignored }
        let index = nodes.firstIndex { $0.node.id == project.selectedPath }
        let current = index.map { nodes[$0] }
        let command = press.modifiers.contains(.command)

        switch press.key {
        case .upArrow:
            let target = index.map { max($0 - 1, 0) } ?? 0
            project.selectedPath = nodes[target].node.id
            project.requestScroll(to: nodes[target].node.id)
            return .handled
        case .downArrow where !command:
            if index == nodes.count - 1, let first = libraryRows.first {
                selectLibraryRow(first)
                project.requestScroll(to: first.id)
                return .handled
            }
            let target = index.map { min($0 + 1, nodes.count - 1) } ?? 0
            project.selectedPath = nodes[target].node.id
            project.requestScroll(to: nodes[target].node.id)
            return .handled
        case .downArrow:
            guard let current, !current.node.isDirectory else { return .ignored }
            onOpenFile(current.node.url)
            return .handled
        case .rightArrow:
            guard let current, current.canDisclose, !isExpanded(current) else { return .ignored }
            toggle(current)
            return .handled
        case .leftArrow:
            guard let current else { return .ignored }
            if current.canDisclose, isExpanded(current) {
                toggle(current)
            } else if let index, let parent = nodes[..<index].last(where: { $0.depth < current.depth }) {
                project.selectedPath = parent.node.id
                project.requestScroll(to: parent.node.id)
            }
            return .handled
        case .return:
            guard let current, current.depth > 0 else { return .ignored }
            actions?.beginRename(current.node.url)
            return .handled
        case .delete where command:
            guard let current, current.depth > 0 else { return .ignored }
            actions?.trash(current.node.url)
            return .handled
        default:
            if press.key == Self.f2Key, let current, current.depth > 0 {
                actions?.beginRename(current.node.url)
                return .handled
            }
            return .ignored
        }
    }

    private static let f2Key = KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!))

    private var filterNeedle: String {
        nameFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var creationDirectory: URL? {
        guard let rootURL = project.rootURL else { return nil }
        if let selected = project.selectedPath, let node = project.node(at: selected) {
            return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        }
        return rootURL
    }

    @ViewBuilder
    private func creationContextMenu(for directory: URL?) -> some View {
        if let actions, let directory {
            Button("New File…") { actions.newItem(directory, false) }
            Button("New Folder…") { actions.newItem(directory, true) }
        }
    }

    private struct FlatNode: Identifiable {
        let node: IDEFileNode
        let depth: Int
        /// Folder with matching descendants. Its disclosure uses `collapsedWhileFiltering`.
        let revealedByFilter: Bool
        let canDisclose: Bool
        /// A build output, or something inside one. Drawn dimmed.
        var isExcluded = false
        var id: String { node.id }
    }

    private func flattenedNodes(root: IDEFileNode) -> [FlatNode] {
        var result: [FlatNode] = []
        _ = collect(root, depth: 0, needle: filterNeedle, underSourceRoot: false, insideExcluded: false, into: &result)
        return result
    }

    private var presentationOptions: IDEExplorerPresentation.Options {
        .init(
            sortOrder: sortOrder,
            foldersOnTop: foldersOnTop,
            showExcluded: showExcludedFiles,
            compactMiddlePackages: compactMiddlePackages && !flattenPackages
        )
    }

    /// `node`'s children as the Explorer shows them: excluded entries hidden when asked, in the
    /// chosen order, with single-child package chains merged under a source root.
    private func displayChildren(of node: IDEFileNode, underSourceRoot: Bool) -> [IDEFileNode] {
        let options = presentationOptions
        let ordered = IDEExplorerPresentation.ordered(node.children ?? [], options: options)
        guard options.compactMiddlePackages, underSourceRoot else { return ordered }
        return ordered.map { child in
            IDEExplorerPresentation.compacted(child) {
                IDEExplorerPresentation.ordered($0.children ?? [], options: options)
            }
        }
    }

    /// While filtering, a row is kept when its name matches or a descendant does. Children of a
    /// matching folder stay filtered, and any folder that contains a match is opened so the match
    /// is visible. With an empty query the project's own expansion is used.
    @discardableResult
    private func collect(
        _ node: IDEFileNode,
        depth: Int,
        needle: String,
        underSourceRoot: Bool,
        insideExcluded: Bool,
        into result: inout [FlatNode]
    ) -> Bool {
        let filtering = !needle.isEmpty
        let excluded = insideExcluded || node.isExcluded
        let inSourceRoot = underSourceRoot
            || (node.isDirectory && IDEFlattenedPackages.isSourceRoot(node.url, sourceRootPaths: javaSourceRootPaths))
        let name = node.displayName ?? node.name
        let nameMatched = filtering && name.range(of: needle, options: Self.matchOptions) != nil

        if !node.isDirectory {
            guard !filtering || nameMatched else { return false }
            result.append(FlatNode(node: node, depth: depth, revealedByFilter: false, canDisclose: false, isExcluded: excluded))
            return true
        }

        if !filtering {
            result.append(FlatNode(node: node, depth: depth, revealedByFilter: false, canDisclose: true, isExcluded: excluded))
            if project.isExpanded(node) {
                for child in displayChildren(of: node, underSourceRoot: inSourceRoot) {
                    _ = collect(
                        child, depth: depth + 1, needle: "",
                        underSourceRoot: inSourceRoot, insideExcluded: excluded, into: &result
                    )
                }
            }
            return true
        }

        var descendantRows: [FlatNode] = []
        var matchedDescendant = false
        for child in displayChildren(of: node, underSourceRoot: inSourceRoot) {
            if collect(
                child, depth: depth + 1, needle: needle,
                underSourceRoot: inSourceRoot, insideExcluded: excluded, into: &descendantRows
            ) {
                matchedDescendant = true
            }
        }
        guard nameMatched || matchedDescendant else { return false }

        let expanded = !collapsedWhileFiltering.contains(node.id)
        result.append(
            FlatNode(
                node: node,
                depth: depth,
                revealedByFilter: matchedDescendant,
                canDisclose: matchedDescendant,
                isExcluded: excluded
            )
        )
        if matchedDescendant, expanded {
            result.append(contentsOf: descendantRows)
        }
        return true
    }

    private func isExpanded(_ item: FlatNode) -> Bool {
        if item.revealedByFilter {
            return !collapsedWhileFiltering.contains(item.node.id)
        }
        return project.isExpanded(item.node)
    }

    private func toggle(_ item: FlatNode) {
        if item.revealedByFilter {
            collapsedWhileFiltering.formSymmetricDifference([item.node.id])
        } else {
            project.toggleExpanded(item.node)
        }
    }

    private static let matchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
}

private struct IDEFileTreeFilterEmptyState: View {
    var body: some View {
        Text("No matching files")
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .padding(.horizontal, IDEAppearance.Spacing.lg)
            .padding(.top, IDEAppearance.Spacing.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct IDEFileTreeRow: View {
    let node: IDEFileNode
    let depth: Int
    let isExpanded: Bool
    var canDisclose = false
    var isSelected = false
    var isOpen = false
    var isUnsaved = false
    var isRoot = false
    var isExcluded = false
    var isRenaming = false
    var actions: IDEFileTreeActions?
    var filterQuery = ""
    var gitStatus: IDEGitFileStatus?
    var folderRole: IDEFlattenedPackages.FolderRole = .plain
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if canDisclose {
                Button(action: onToggle) {
                    IDEDisclosureChevron(isExpanded: isExpanded, size: 10, width: 12)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse \(displayName)" : "Expand \(displayName)")
            } else {
                Spacer().frame(width: 12)
            }

            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 14)

            if isRenaming, let actions {
                IDEInlineRenameField(
                    initialText: node.name,
                    selectsStemOnly: !node.isDirectory,
                    onCommit: { actions.commitRename(node.url, $0) },
                    onCancel: actions.cancelRename
                )
                .frame(width: 200, height: 18)
            } else {
                title
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(displayName)
            }

            Spacer(minLength: 0)

            if isUnsaved {
                Circle()
                    .fill(IDEAppearance.ColorToken.accent)
                    .frame(width: IDEAppearance.Spacing.dirtyDotSize, height: IDEAppearance.Spacing.dirtyDotSize)
                    .accessibilityLabel("Unsaved changes")
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + CGFloat(IDEAppearance.Spacing.sm))
        .padding(.trailing, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
        .background(isSelected ? IDEAppearance.ColorToken.selection : Color.clear)
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .onTapGesture {
            onSelect()
            if canDisclose {
                onToggle()
            } else if !node.isDirectory {
                onOpen()
            }
        }
        .contextMenu { contextMenuItems }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if let actions {
            let directory = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
            if node.isDirectory {
                Button("New File…") { selectAndRun { actions.newItem(node.url, false) } }
                Button("New Folder…") { selectAndRun { actions.newItem(node.url, true) } }
            } else {
                Button("New File…") { selectAndRun { actions.newItem(directory, false) } }
                Button("New Folder…") { selectAndRun { actions.newItem(directory, true) } }
            }
            Divider()
            Button("Rename") { selectAndRun { actions.beginRename(node.url) } }
                .disabled(isRoot)
            Button("Duplicate") { selectAndRun { actions.duplicate(node.url) } }
                .disabled(isRoot)
            Divider()
            Button("Copy Path/Reference…") { selectAndRun { actions.copyPathReference(node.url) } }
            Button("Show History") { selectAndRun { actions.showHistory(node.url) } }
            if gitStatus == .untracked || (node.isDirectory && gitStatus != .ignored && !isRoot) {
                Button("Add to .gitignore") { selectAndRun { actions.addToIgnoreFile(node.url, false) } }
                Button("Add to .git/info/exclude") { selectAndRun { actions.addToIgnoreFile(node.url, true) } }
            }
            if !node.isDirectory, gitStatus != .untracked, gitStatus != .ignored {
                Button("Open on Web") { selectAndRun { actions.openOnWeb(node.url, false) } }
                Button("Copy Web Link") { selectAndRun { actions.openOnWeb(node.url, true) } }
            }
            if node.isDirectory || node.url.pathExtension.lowercased() == "java" {
                Button("Show Class Diagram") { selectAndRun { actions.showClassDiagram(node.url) } }
            }
            if node.isDirectory || node.url.pathExtension.lowercased() == "java" {
                Button("Inspect Code…") { selectAndRun { actions.inspectCode(node.url) } }
            }
            if node.isDirectory {
                Button("Find in Files Here…") { selectAndRun { actions.findInFiles(node.url) } }
            }
        }
        Button("Reveal in Finder") {
            selectAndRun {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
        }
        if let actions {
            Divider()
            Button("Move to Trash", role: .destructive) { selectAndRun { actions.trash(node.url) } }
                .disabled(isRoot)
        }
    }

    private func selectAndRun(_ action: () -> Void) {
        onSelect()
        action()
    }

    private var displayName: String {
        node.isDirectory && depth == 0 ? node.url.lastPathComponent : node.displayName ?? node.name
    }

    private var title: Text {
        let name = displayName
        let foreground = titleColor
        let needle = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let range = name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(name).fontWeight(isOpen ? .semibold : .regular).foregroundStyle(foreground)
        }
        return Text("\(Text(name[..<range.lowerBound]).foregroundStyle(foreground))\(Text(name[range]).fontWeight(.semibold).foregroundStyle(IDEAppearance.ColorToken.accent))\(Text(name[range.upperBound...]).foregroundStyle(foreground))")
    }

    private var iconName: String {
        guard node.isDirectory else { return IDEFileIcon.systemName(forFilename: node.name) }
        switch folderRole {
        case .sourceRoot, .testSourceRoot: return "folder.fill"
        case .resources, .testResources: return "folder.badge.gearshape"
        case .plain: return node.displayName != nil ? "shippingbox" : "folder"
        }
    }

    private var gitColor: Color? {
        switch gitStatus {
        case .modified: IDEAppearance.ColorToken.gitModified
        case .added: IDEAppearance.ColorToken.gitAdded
        case .untracked: IDEAppearance.ColorToken.gitUntracked
        case .conflicted: IDEAppearance.ColorToken.gitConflict
        case .ignored: IDEAppearance.ColorToken.gitIgnored
        case nil: nil
        }
    }

    private var roleColor: Color? {
        switch folderRole {
        case .sourceRoot: IDEAppearance.ColorToken.sourceRoot
        case .testSourceRoot: IDEAppearance.ColorToken.testSourceRoot
        case .resources, .testResources: IDEAppearance.ColorToken.resourcesFolder
        case .plain: nil
        }
    }

    /// Ignored wins over everything so ignored folders stay dim; otherwise a folder role tints
    /// folders and git status tints files.
    private var titleColor: Color {
        if isExcluded || gitStatus == .ignored { return IDEAppearance.ColorToken.gitIgnored }
        if node.isDirectory { return roleColor ?? gitColor ?? IDEAppearance.ColorToken.foreground }
        return gitColor ?? IDEAppearance.ColorToken.foreground
    }

    private var iconColor: Color {
        if isExcluded || gitStatus == .ignored { return IDEAppearance.ColorToken.gitIgnored }
        return roleColor ?? gitColor ?? IDEAppearance.ColorToken.muted
    }
}

/// Borderless text field for renaming a row in place. Return commits, Esc cancels, and losing
/// focus commits. For files only the name before the extension is preselected.
private struct IDEExternalLibraryRow: View {
    let item: IDEExternalLibraryItem
    var isSelected = false
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onCopyName: () -> Void

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if item.canDisclose {
                Button(action: onToggle) {
                    IDEDisclosureChevron(isExpanded: item.isExpanded, size: 10, width: 12)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.isExpanded ? "Collapse \(item.title)" : "Expand \(item.title)")
            } else {
                Spacer().frame(width: 12)
            }

            if let iconName {
                Image(systemName: iconName)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 14)
            } else {
                Spacer().frame(width: 14)
            }

            Text(item.title)
                .fontWeight(item.kind == .section ? .semibold : .regular)
                .foregroundStyle(item.kind == .message ? IDEAppearance.ColorToken.muted : IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(item.depth) * 14 + CGFloat(IDEAppearance.Spacing.sm))
        .padding(.trailing, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
        .padding(.top, item.kind == .section ? IDEAppearance.Spacing.sm : 0)
        .background(isSelected ? IDEAppearance.ColorToken.selection : Color.clear)
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .onTapGesture {
            guard item.kind != .message else { return }
            onSelect()
            if item.isOpenable {
                onOpen()
            } else if item.canDisclose {
                onToggle()
            }
        }
        .contextMenu {
            if item.isOpenable {
                Button("Open") { onSelect(); onOpen() }
            }
            if item.kind == .type {
                Button("Copy Reference") { onCopyName() }
            }
            if let location = item.location {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(location.path, forType: .string)
                }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([location]) }
            }
        }
    }

    private var iconName: String? {
        switch item.kind {
        case .section: "books.vertical"
        case .jdk: "cup.and.saucer"
        case .library: "shippingbox"
        case .module: "cube"
        case .package, .folder: "folder"
        case .type: "c.square"
        case .resource: IDEFileIcon.systemName(forFilename: item.title)
        case .message: nil
        }
    }
}

private struct IDEInlineRenameField: NSViewRepresentable {
    let initialText: String
    let selectsStemOnly: Bool
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCommit: onCommit, onCancel: onCancel) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: initialText)
        field.font = .systemFont(ofSize: 12)
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = IDEAppearance.NSToken.editor
        field.textColor = IDEAppearance.NSToken.foreground
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        let stemLength = selectsStemOnly ? (initialText as NSString).deletingPathExtension.count : initialText.count
        Task { @MainActor in
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: stemLength > 0 ? stemLength : initialText.count)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {}

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let onCommit: (String) -> Void
        let onCancel: () -> Void
        private var finished = false

        init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                finish(commit: true, text: control.stringValue)
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                finish(commit: false, text: control.stringValue)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            finish(commit: true, text: field.stringValue)
        }

        private func finish(commit: Bool, text: String) {
            guard !finished else { return }
            finished = true
            if commit { onCommit(text) } else { onCancel() }
        }
    }
}

#Preview {
    IDEFileTreeView(
        project: {
            let project = IDEProjectModel()
            project.setRoot(IDEDevelopmentPaths.sourceRoot)
            return project
        }(),
        onOpenFile: { _ in },
        collapsedWhileFiltering: .constant([])
    )
    .frame(width: 240, height: 320)
    .background(IDEAppearance.ColorToken.sidebar)
    .preferredColorScheme(IDEAppearance.preferredColorScheme)
}

#Preview("Empty") {
    IDEFileTreeView(project: IDEProjectModel(), onOpenFile: { _ in }, collapsedWhileFiltering: .constant([]))
        .frame(width: 240, height: 320)
        .background(IDEAppearance.ColorToken.sidebar)
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
}
