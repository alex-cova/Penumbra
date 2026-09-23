import Foundation
import JavaIntelligence

/// One node of the Gradle tool window tree. Built purely from ``JavaGradleProjectModel`` so the
/// structure, IDs, and filtering can be reasoned about (and tested) without SwiftUI.
struct IDEGradleTreeNode: Identifiable {
    enum Kind {
        case project(JavaGradleProjectModel.Subproject)
        case tasks
        case taskGroup
        case task(JavaGradleProjectModel.GradleTask)
        case dependencies
        case configuration(sourceSet: String)
        case projectDependency(JavaGradleProjectModel.ProjectDependency)
        case jar(URL)
        case unresolvedGroup
        case unresolved
        case sourceSets
        case sourceSet(name: String)
        case sourceDirectory(URL, sourceSet: String)
    }

    /// Stable and scoped by project path, so expansion survives a re-sync.
    let id: String
    let kind: Kind
    let title: String
    var detail: String?
    var help: String?
    var children: [IDEGradleTreeNode] = []

    var isContainer: Bool { !children.isEmpty }
}

enum IDEGradleTree {
    struct Row: Identifiable {
        let node: IDEGradleTreeNode
        let depth: Int
        let canDisclose: Bool
        let isExpanded: Bool
        var id: String { node.id }
    }

    // MARK: Building

    static func build(from model: JavaGradleProjectModel, rootName: String? = nil) -> IDEGradleTreeNode? {
        guard !model.subprojects.isEmpty else { return nil }

        let byPath = Dictionary(model.subprojects.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var childPaths: [String: [String]] = [:]

        for subproject in model.subprojects where subproject.path != ":" {
            var parent = parentPath(of: subproject.path)
            // Skip over intermediate paths that have no project of their own.
            while parent != ":", byPath[parent] == nil {
                parent = parentPath(of: parent)
            }
            childPaths[parent, default: []].append(subproject.path)
        }

        func node(for subproject: JavaGradleProjectModel.Subproject, isRoot: Bool) -> IDEGradleTreeNode {
            var children: [IDEGradleTreeNode] = []
            let tasks = taskNode(for: subproject)
            if let tasks { children.append(tasks) }
            if let dependencies = dependenciesNode(for: subproject, unresolved: isRoot ? model.unresolved : []) {
                children.append(dependencies)
            }
            if let sourceSets = sourceSetsNode(for: subproject) { children.append(sourceSets) }
            for path in (childPaths[subproject.path] ?? []).sorted() {
                if let child = byPath[path] { children.append(node(for: child, isRoot: false)) }
            }

            var detail: String?
            if isRoot {
                detail = model.gradleVersion.isEmpty ? nil : "Gradle \(model.gradleVersion)"
            } else if let level = subproject.languageLevel {
                detail = "Java \(level)"
            }
            return IDEGradleTreeNode(
                id: "project::\(subproject.path)",
                kind: .project(subproject),
                title: title(for: subproject, rootName: rootName),
                detail: detail,
                help: subproject.directory.path,
                children: children
            )
        }

        if let root = byPath[":"] {
            return node(for: root, isRoot: true)
        }

        // No `:` project entry -- synthesize a container so nested modules still hang off one root.
        let synthetic = JavaGradleProjectModel.Subproject(
            path: ":",
            directory: model.subprojects[0].directory.deletingLastPathComponent()
        )
        return node(for: synthetic, isRoot: true)
    }

    private static func title(for subproject: JavaGradleProjectModel.Subproject, rootName: String?) -> String {
        guard subproject.path == ":" else { return subproject.path }
        if let rootName, !rootName.isEmpty { return rootName }
        let name = subproject.directory.lastPathComponent
        return name.isEmpty ? "root" : name
    }

    static func parentPath(of path: String) -> String {
        guard let index = path.lastIndex(of: ":"), index != path.startIndex else { return ":" }
        return String(path[..<index])
    }

    private static func taskNode(for subproject: JavaGradleProjectModel.Subproject) -> IDEGradleTreeNode? {
        let groups = subproject.taskGroups
        guard !groups.isEmpty else { return nil }
        let groupNodes = groups.map { group in
            IDEGradleTreeNode(
                id: "group::\(subproject.path)/\(group.name)",
                kind: .taskGroup,
                title: group.name,
                detail: "\(group.tasks.count)",
                children: group.tasks.map { task in
                    IDEGradleTreeNode(
                        id: "task::\(task.path)",
                        kind: .task(task),
                        title: task.name,
                        help: task.description.isEmpty ? task.path : "\(task.description)\n\(task.path)"
                    )
                }
            )
        }
        return IDEGradleTreeNode(id: "tasks::\(subproject.path)", kind: .tasks, title: "Tasks", children: groupNodes)
    }

    private static func dependenciesNode(
        for subproject: JavaGradleProjectModel.Subproject,
        unresolved: [String]
    ) -> IDEGradleTreeNode? {
        var children: [IDEGradleTreeNode] = []

        if !unresolved.isEmpty {
            children.append(IDEGradleTreeNode(
                id: "unresolved::\(subproject.path)",
                kind: .unresolvedGroup,
                title: "Unresolved",
                detail: "\(unresolved.count)",
                children: unresolved.enumerated().map { index, item in
                    IDEGradleTreeNode(
                        id: "unresolved::\(subproject.path)/\(index)/\(item)",
                        kind: .unresolved,
                        title: item,
                        help: item
                    )
                }
            ))
        }

        for sourceSet in subproject.sourceSets {
            let scope = "\(subproject.path)/\(sourceSet.name)"
            var items: [IDEGradleTreeNode] = sourceSet.projectDependencies.map { dependency in
                IDEGradleTreeNode(
                    id: "projdep::\(scope)/\(dependency.projectPath)/\(dependency.sourceSetName)",
                    kind: .projectDependency(dependency),
                    title: "project \(dependency.projectPath)",
                    detail: dependency.sourceSetName == "main" ? nil : dependency.sourceSetName,
                    help: "Project dependency"
                )
            }
            items += sourceSet.compileClasspathJars.map { jar in
                let coordinate = mavenCoordinate(for: jar)
                return IDEGradleTreeNode(
                    id: "jar::\(scope)/\(jar.path)",
                    kind: .jar(jar),
                    title: coordinate ?? jar.lastPathComponent,
                    help: jar.path
                )
            }
            guard !items.isEmpty else { continue }
            children.append(IDEGradleTreeNode(
                id: "cfg::\(scope)",
                kind: .configuration(sourceSet: sourceSet.name),
                title: configurationName(for: sourceSet.name),
                detail: "\(items.count)",
                children: items
            ))
        }

        guard !children.isEmpty else { return nil }
        return IDEGradleTreeNode(
            id: "deps::\(subproject.path)",
            kind: .dependencies,
            title: "Dependencies",
            children: children
        )
    }

    private static func sourceSetsNode(for subproject: JavaGradleProjectModel.Subproject) -> IDEGradleTreeNode? {
        let sets = subproject.sourceSets.filter { !$0.sourceDirs.isEmpty }
        guard !sets.isEmpty else { return nil }
        let children = sets.map { sourceSet in
            IDEGradleTreeNode(
                id: "sourceset::\(subproject.path)/\(sourceSet.name)",
                kind: .sourceSet(name: sourceSet.name),
                title: sourceSet.name,
                children: sourceSet.sourceDirs.map { directory in
                    IDEGradleTreeNode(
                        id: "srcdir::\(subproject.path)/\(sourceSet.name)/\(directory.path)",
                        kind: .sourceDirectory(directory, sourceSet: sourceSet.name),
                        title: relativePath(directory, root: subproject.directory),
                        help: directory.path
                    )
                }
            )
        }
        return IDEGradleTreeNode(
            id: "sourcesets::\(subproject.path)",
            kind: .sourceSets,
            title: "Source Sets",
            children: children
        )
    }

    static func configurationName(for sourceSet: String) -> String {
        switch sourceSet {
        case "main": "compileClasspath"
        case "test": "testCompileClasspath"
        default: "\(sourceSet)CompileClasspath"
        }
    }

    /// `group:artifact:version` for a jar in Gradle's module cache (`.../files-2.1/g/a/v/<hash>/x.jar`).
    static func mavenCoordinate(for jar: URL) -> String? {
        let components = jar.pathComponents
        guard let index = components.firstIndex(of: "files-2.1"), index + 3 < components.count else {
            return nil
        }
        return "\(components[index + 1]):\(components[index + 2]):\(components[index + 3])"
    }

    private static func relativePath(_ directory: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let dirPath = directory.standardizedFileURL.path
        if dirPath.hasPrefix(rootPath + "/") {
            return String(dirPath.dropFirst(rootPath.count + 1))
        }
        return directory.lastPathComponent
    }

    // MARK: Flattening

    /// Visible rows for `root`. With an empty `filter` the caller's `expanded` set decides what is
    /// open. With a filter, a row is kept when its title matches or a descendant does; children of a
    /// matching node stay filtered, and any node with a match beneath it opens (unless
    /// `collapsedWhileFiltering` holds it).
    static func flatten(
        _ root: IDEGradleTreeNode,
        expanded: Set<String>,
        filter: String,
        collapsedWhileFiltering: Set<String>
    ) -> [Row] {
        var rows: [Row] = []
        _ = collect(
            root, depth: 0, needle: filter, expanded: expanded,
            collapsed: collapsedWhileFiltering, into: &rows
        )
        return rows
    }

    @discardableResult
    private static func collect(
        _ node: IDEGradleTreeNode,
        depth: Int,
        needle: String,
        expanded: Set<String>,
        collapsed: Set<String>,
        into rows: inout [Row]
    ) -> Bool {
        guard !needle.isEmpty else {
            let open = node.isContainer && expanded.contains(node.id)
            rows.append(Row(node: node, depth: depth, canDisclose: node.isContainer, isExpanded: open))
            if open {
                for child in node.children {
                    collect(child, depth: depth + 1, needle: "", expanded: expanded, collapsed: collapsed, into: &rows)
                }
            }
            return true
        }

        let nameMatched = node.title.range(of: needle, options: matchOptions) != nil
        var descendantRows: [Row] = []
        var matchedDescendant = false
        for child in node.children {
            if collect(
                child, depth: depth + 1, needle: needle, expanded: expanded,
                collapsed: collapsed, into: &descendantRows
            ) {
                matchedDescendant = true
            }
        }
        guard nameMatched || matchedDescendant else { return false }

        let open = matchedDescendant && !collapsed.contains(node.id)
        rows.append(Row(node: node, depth: depth, canDisclose: matchedDescendant, isExpanded: open))
        if open { rows.append(contentsOf: descendantRows) }
        return true
    }

    private static let matchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    // MARK: Subtree helpers

    /// IDs of `node` and every container below it, for Expand All / Expand Subtree.
    static func containerIDs(in node: IDEGradleTreeNode) -> Set<String> {
        var ids = Set<String>()
        func walk(_ node: IDEGradleTreeNode) {
            guard node.isContainer else { return }
            ids.insert(node.id)
            node.children.forEach(walk)
        }
        walk(node)
        return ids
    }

    static func find(_ id: String, in node: IDEGradleTreeNode) -> IDEGradleTreeNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = find(id, in: child) { return found }
        }
        return nil
    }
}
