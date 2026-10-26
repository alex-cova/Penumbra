import Foundation

/// Rewrites the Explorer tree so each Java source root lists its packages as flat dotted rows
/// (IntelliJ's "Flatten Packages"), for both Java and Kotlin roots. Presentation only: package rows keep their real directory URL
/// as `id`, so `IDEProjectModel`'s expansion state and `reveal(url:)` work unchanged.
enum IDEFlattenedPackages {
    static func flatten(_ root: IDEFileNode, sourceRootPaths: Set<String>) -> IDEFileNode {
        flattenNode(root, sourceRootPaths: sourceRootPaths)
    }

    /// A Gradle-reported source dir, or the Maven/Gradle `…/src/<set>/java|kotlin` convention so a
    /// project flattens before (or without) a Gradle sync.
    static func isSourceRoot(_ url: URL, sourceRootPaths: Set<String>) -> Bool {
        let standardized = url.standardizedFileURL
        if sourceRootPaths.contains(standardized.path) {
            return true
        }
        let components = standardized.pathComponents
        guard components.count >= 3 else { return false }
        let last = components[components.count - 1]
        return (last == "java" || last == "kotlin") && components[components.count - 3] == "src"
    }

    enum FolderRole: Equatable {
        case plain, sourceRoot, testSourceRoot, resources, testResources
    }

    /// Classifies a directory for Explorer icon/tint: source roots (Java/Kotlin) and `resources`
    /// folders, each with a test variant when the enclosing `src/<set>` name contains "test".
    static func folderRole(for url: URL, sourceRootPaths: Set<String>) -> FolderRole {
        let standardized = url.standardizedFileURL
        let components = standardized.pathComponents
        let isTestSet = components.count >= 3
            && components[components.count - 3] == "src"
            && components[components.count - 2].lowercased().contains("test")
        if isSourceRoot(standardized, sourceRootPaths: sourceRootPaths) {
            return isTestSet ? .testSourceRoot : .sourceRoot
        }
        if components.last == "resources" {
            return isTestSet ? .testResources : .resources
        }
        return .plain
    }

    private static func flattenNode(_ node: IDEFileNode, sourceRootPaths: Set<String>) -> IDEFileNode {
        guard node.isDirectory, let children = node.children else { return node }
        var copy = node
        if isSourceRoot(node.url, sourceRootPaths: sourceRootPaths) {
            var packages: [IDEFileNode] = []
            for child in children where child.isDirectory {
                collectPackages(child, prefix: child.name, into: &packages)
            }
            packages.sort { lhs, rhs in
                (lhs.displayName ?? lhs.name).localizedCaseInsensitiveCompare(rhs.displayName ?? rhs.name) == .orderedAscending
            }
            copy.children = packages + children.filter { !$0.isDirectory }
        } else {
            copy.children = children.map { flattenNode($0, sourceRootPaths: sourceRootPaths) }
        }
        return copy
    }

    /// Emits a row for every directory that directly holds files, plus empty leaf directories so an
    /// empty package doesn't vanish. Directories that only hold other directories are skipped.
    private static func collectPackages(_ directory: IDEFileNode, prefix: String, into packages: inout [IDEFileNode]) {
        let children = directory.children ?? []
        let files = children.filter { !$0.isDirectory }
        let subdirectories = children.filter(\.isDirectory)
        if !files.isEmpty || subdirectories.isEmpty {
            packages.append(IDEFileNode(url: directory.url, isDirectory: true, children: files, displayName: prefix))
        }
        for subdirectory in subdirectories {
            collectPackages(subdirectory, prefix: prefix + "." + subdirectory.name, into: &packages)
        }
    }
}

enum IDEExplorerSortOrder: String, CaseIterable, Identifiable {
    case name
    case type

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Sort by Name"
        case .type: "Sort by Type"
        }
    }
}

/// Explorer row ordering and package compaction. Pure functions over `IDEFileNode`, applied while
/// the tree view walks its expanded rows, so options change without rebuilding the project tree.
enum IDEExplorerPresentation {
    struct Options: Equatable {
        var sortOrder: IDEExplorerSortOrder = .name
        var foldersOnTop = true
        var showExcluded = true
        var compactMiddlePackages = false
    }

    /// `children` without excluded entries (when hidden), in the requested order. Folders order by
    /// name even under Sort by Type.
    static func ordered(_ children: [IDEFileNode], options: Options) -> [IDEFileNode] {
        let visible = options.showExcluded ? children : children.filter { !$0.isExcluded }
        return visible.sorted { lhs, rhs in
            if options.foldersOnTop, lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            if options.sortOrder == .type {
                let lhsKey = typeKey(lhs)
                let rhsKey = typeKey(rhs)
                if lhsKey != rhsKey { return lhsKey < rhsKey }
            }
            let lhsName = lhs.displayName ?? lhs.name
            let rhsName = rhs.displayName ?? rhs.name
            let order = lhsName.localizedCaseInsensitiveCompare(rhsName)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    private static func typeKey(_ node: IDEFileNode) -> String {
        node.isDirectory ? "" : node.url.pathExtension.lowercased()
    }

    /// Follows single-child folder chains below `node`. Returns the deepest folder with a dotted
    /// `displayName` when at least one folder was merged, otherwise `node` unchanged. `children`
    /// is the already ordered/filtered list per folder, supplied by the caller.
    static func compacted(
        _ node: IDEFileNode,
        children: (IDEFileNode) -> [IDEFileNode]
    ) -> IDEFileNode {
        guard node.isDirectory else { return node }
        var current = node
        var name = node.displayName ?? node.name
        var merged = false
        while true {
            let kids = children(current)
            guard kids.count == 1, let only = kids.first, only.isDirectory, !only.isExcluded else { break }
            name += "." + (only.displayName ?? only.name)
            current = only
            merged = true
        }
        guard merged else { return node }
        var result = current
        result.displayName = name
        return result
    }
}
