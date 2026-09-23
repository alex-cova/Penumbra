import AppKit
import SwiftUI

struct IDEFileTreeView: View {
    let project: IDEProjectModel
    let onOpenFile: (URL) -> Void
    var flattenPackages = false
    var javaSourceRootPaths: Set<String> = []
    var nameFilter = ""

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
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(nodes) { item in
                                IDEFileTreeRow(
                                    node: item.node,
                                    depth: item.depth,
                                    isExpanded: isExpanded(item),
                                    canDisclose: item.canDisclose,
                                    filterQuery: filterNeedle,
                                    onToggle: { toggle(item) },
                                    onOpen: { onOpenFile(item.node.url) }
                                )
                            }
                        }
                        .padding(.vertical, IDEAppearance.Spacing.xs)
                    }
                }
            } else {
                IDEFileTreeEmptyState()
            }
        }
        .onChange(of: filterNeedle) { _, _ in
            collapsedWhileFiltering.removeAll()
        }
    }

    private var filterNeedle: String {
        nameFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct FlatNode: Identifiable {
        let node: IDEFileNode
        let depth: Int
        /// Folder with matching descendants. Its disclosure uses `collapsedWhileFiltering`.
        let revealedByFilter: Bool
        let canDisclose: Bool
        var id: String { "\(depth)-\(node.id)" }
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
    var body: some View {
        VStack(spacing: IDEAppearance.Spacing.md) {
            Image(systemName: "folder.badge.plus")
                .font(.title2)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Text("No Folder Open")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            Text("Open a project folder to browse files.")
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
    var filterQuery = ""
    let onToggle: () -> Void
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
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 14)

            title
                .lineLimit(1)
                .accessibilityLabel(displayName)

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14 + IDEAppearance.Spacing.sm)
        .padding(.trailing, IDEAppearance.Spacing.sm)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if canDisclose {
                onToggle()
            } else if !node.isDirectory {
                onOpen()
            }
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
        }
    }

    private var displayName: String {
        node.isDirectory && depth == 0 ? node.url.lastPathComponent : node.displayName ?? node.name
    }

    private var title: Text {
        let name = displayName
        let foreground = IDEAppearance.ColorToken.foreground
        let needle = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let range = name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(name).foregroundStyle(foreground)
        }
        return Text(name[..<range.lowerBound]).foregroundStyle(foreground)
            + Text(name[range]).fontWeight(.semibold).foregroundStyle(IDEAppearance.ColorToken.accent)
            + Text(name[range.upperBound...]).foregroundStyle(foreground)
    }

    private var iconName: String {
        guard node.isDirectory else { return IDEFileIcon.systemName(forFilename: node.name) }
        return node.displayName != nil ? "shippingbox" : "folder"
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
