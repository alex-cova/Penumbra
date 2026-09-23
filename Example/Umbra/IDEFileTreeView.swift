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
    var copyPath: (_ url: URL, _ relative: Bool) -> Void
}

struct IDEFileTreeView: View {
    let project: IDEProjectModel
    let onOpenFile: (URL) -> Void
    var flattenPackages = false
    var javaSourceRootPaths: Set<String> = []
    var nameFilter = ""
    var gitStatus: IDEGitStatusModel?
    var openPaths: Set<String> = []
    var actions: IDEFileTreeActions?

    /// Folders opened so a match stays visible. Collapsing one hides that branch until the query
    /// changes; it does not rewrite the project's own expansion state.
    @State private var collapsedWhileFiltering: Set<String> = []

    var body: some View {
        Group {
            if let root = project.rootNode {
                let displayRoot = flattenPackages
                    ? IDEFlattenedPackages.flatten(root, sourceRootPaths: javaSourceRootPaths)
                    : root
                let nodes = flattenedNodes(root: displayRoot)
                if nodes.isEmpty {
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
                                    isRoot: item.depth == 0,
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
                        }
                        .padding(.vertical, IDEAppearance.Spacing.xs)
                        .frame(minWidth: proxy.size.width, alignment: .leading)
                    }
                    .focusable(actions != nil)
                    .focusEffectDisabled()
                    .onKeyPress(phases: [.down, .repeat]) { press in
                        handleKey(press, nodes: nodes)
                    }
                    .onChange(of: project.revealRequest) { _, request in
                        guard let request else { return }
                        // Let the ancestors' expansion land in the row list before scrolling.
                        DispatchQueue.main.async {
                            scroller.scrollTo(request.path, anchor: request.centered ? .center : nil)
                        }
                    }
                    }
                    }
                }
            } else {
                IDEFileTreeEmptyState(isRootMissing: project.isRootMissing)
            }
        }
        .onChange(of: filterNeedle) { _, _ in
            collapsedWhileFiltering.removeAll()
        }
    }

    private func handleKey(_ press: KeyPress, nodes: [FlatNode]) -> KeyPress.Result {
        guard project.renamingPath == nil, !nodes.isEmpty else { return .ignored }
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

    private struct FlatNode: Identifiable {
        let node: IDEFileNode
        let depth: Int
        /// Folder with matching descendants. Its disclosure uses `collapsedWhileFiltering`.
        let revealedByFilter: Bool
        let canDisclose: Bool
        var id: String { node.id }
    }

    private func flattenedNodes(root: IDEFileNode) -> [FlatNode] {
        var result: [FlatNode] = []
        _ = collect(root, depth: 0, needle: filterNeedle, into: &result)
        return result
    }

    /// While filtering, a row is kept when its name matches or a descendant does. Children of a
    /// matching folder stay filtered, and any folder that contains a match is opened so the match
    /// is visible. With an empty query the project's own expansion is used.
    @discardableResult
    private func collect(
        _ node: IDEFileNode,
        depth: Int,
        needle: String,
        into result: inout [FlatNode]
    ) -> Bool {
        let filtering = !needle.isEmpty
        let name = node.displayName ?? node.name
        let nameMatched = filtering && name.range(of: needle, options: Self.matchOptions) != nil

        if !node.isDirectory {
            guard !filtering || nameMatched else { return false }
            result.append(FlatNode(node: node, depth: depth, revealedByFilter: false, canDisclose: false))
            return true
        }

        if !filtering {
            result.append(FlatNode(node: node, depth: depth, revealedByFilter: false, canDisclose: true))
            if project.isExpanded(node) {
                for child in node.children ?? [] {
                    _ = collect(child, depth: depth + 1, needle: "", into: &result)
                }
            }
            return true
        }

        var descendantRows: [FlatNode] = []
        var matchedDescendant = false
        for child in node.children ?? [] {
            if collect(child, depth: depth + 1, needle: needle, into: &descendantRows) {
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
                canDisclose: matchedDescendant
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

private struct IDEFileTreeEmptyState: View {
    var isRootMissing = false

    var body: some View {
        VStack(spacing: IDEAppearance.Spacing.md) {
            Image(systemName: "folder.badge.plus")
                .font(.title2)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text(isRootMissing ? "Folder Not Found" : "No Folder Open")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            Text(isRootMissing ? "The project folder was moved or deleted." : "Open a project folder to browse files.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .multilineTextAlignment(.center)
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IDEFileTreeRow: View {
    let node: IDEFileNode
    let depth: Int
    let isExpanded: Bool
    var canDisclose = false
    var isSelected = false
    var isOpen = false
    var isRoot = false
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
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
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
        }
        .padding(.leading, CGFloat(depth) * 14 + IDEAppearance.Spacing.sm)
        .padding(.trailing, IDEAppearance.Spacing.sm)
        .padding(.vertical, 4)
        .background(isSelected ? IDEAppearance.ColorToken.selection : Color.clear)
        .contentShape(Rectangle())
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
            Button("New File…") { actions.newItem(directory, false) }
            Button("New Folder…") { actions.newItem(directory, true) }
            Divider()
            Button("Rename") { actions.beginRename(node.url) }
                .disabled(isRoot)
            Button("Duplicate") { actions.duplicate(node.url) }
                .disabled(isRoot)
            Divider()
            Button("Copy Path") { actions.copyPath(node.url, false) }
            Button("Copy Relative Path") { actions.copyPath(node.url, true) }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
        if let actions {
            Divider()
            Button("Move to Trash", role: .destructive) { actions.trash(node.url) }
                .disabled(isRoot)
        }
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
        return Text(name[..<range.lowerBound]).foregroundStyle(foreground)
            + Text(name[range]).fontWeight(.semibold).foregroundStyle(IDEAppearance.ColorToken.accent)
            + Text(name[range.upperBound...]).foregroundStyle(foreground)
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
        if gitStatus == .ignored { return IDEAppearance.ColorToken.gitIgnored }
        if node.isDirectory { return roleColor ?? gitColor ?? IDEAppearance.ColorToken.foreground }
        return gitColor ?? IDEAppearance.ColorToken.foreground
    }

    private var iconColor: Color {
        if gitStatus == .ignored { return IDEAppearance.ColorToken.gitIgnored }
        return roleColor ?? gitColor ?? IDEAppearance.ColorToken.muted
    }
}

/// Borderless text field for renaming a row in place. Return commits, Esc cancels, and losing
/// focus commits. For files only the name before the extension is preselected.
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
        DispatchQueue.main.async {
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
            project.setRoot(URL(fileURLWithPath: #filePath).deletingLastPathComponent())
            return project
        }(),
        onOpenFile: { _ in }
    )
    .frame(width: 240, height: 320)
    .background(IDEAppearance.ColorToken.sidebar)
    .preferredColorScheme(.dark)
}

#Preview("Empty") {
    IDEFileTreeView(project: IDEProjectModel(), onOpenFile: { _ in })
        .frame(width: 240, height: 320)
        .background(IDEAppearance.ColorToken.sidebar)
        .preferredColorScheme(.dark)
}
