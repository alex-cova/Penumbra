import AppKit
import SwiftUI

struct IDEFileTreeView: View {
    let project: IDEProjectModel
    let onOpenFile: (URL) -> Void

    var body: some View {
        Group {
            if let root = project.rootNode {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(flattenedNodes(root: root)) { item in
                            IDEFileTreeRow(
                                node: item.node,
                                depth: item.depth,
                                isExpanded: project.isExpanded(item.node),
                                onToggle: { project.toggleExpanded(item.node) },
                                onOpen: { onOpenFile(item.node.url) }
                            )
                        }
                    }
                    .padding(.vertical, IDEAppearance.Spacing.xs)
                }
            } else {
                IDEFileTreeEmptyState()
            }
        }
    }

    private struct FlatNode: Identifiable {
        let node: IDEFileNode
        let depth: Int
        var id: String { "\(depth)-\(node.id)" }
    }

    private func flattenedNodes(root: IDEFileNode) -> [FlatNode] {
        var result: [FlatNode] = []
        appendNode(root, depth: 0, into: &result)
        return result
    }

    private func appendNode(_ node: IDEFileNode, depth: Int, into result: inout [FlatNode]) {
        result.append(FlatNode(node: node, depth: depth))
        guard node.isDirectory, project.isExpanded(node), let children = node.children else { return }
        for child in children {
            appendNode(child, depth: depth + 1, into: &result)
        }
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
    let onToggle: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if node.isDirectory {
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

            Image(systemName: node.isDirectory ? "folder" : IDEFileIcon.systemName(forFilename: node.name))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 14)

            Text(displayName)
                .lineLimit(1)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14 + IDEAppearance.Spacing.sm)
        .padding(.trailing, IDEAppearance.Spacing.sm)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isDirectory {
                onToggle()
            } else {
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
        node.isDirectory && depth == 0 ? node.url.lastPathComponent : node.name
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
