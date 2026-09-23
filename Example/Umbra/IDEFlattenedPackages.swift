import Foundation

/// Rewrites the Explorer tree so each Java source root lists its packages as flat dotted rows
/// (IntelliJ's "Flatten Packages"). Presentation only: package rows keep their real directory URL
/// as `id`, so `IDEProjectModel`'s expansion state and `reveal(url:)` work unchanged.
enum IDEFlattenedPackages {
    static func flatten(_ root: IDEFileNode, sourceRootPaths: Set<String>) -> IDEFileNode {
        flattenNode(root, sourceRootPaths: sourceRootPaths)
    }

    /// A Gradle-reported source dir, or the Maven/Gradle `…/src/<set>/java` convention so a
    /// project flattens before (or without) a Gradle sync.
    static func isSourceRoot(_ url: URL, sourceRootPaths: Set<String>) -> Bool {
        let standardized = url.standardizedFileURL
        if sourceRootPaths.contains(standardized.path) {
            return true
        }
        let components = standardized.pathComponents
        guard components.count >= 3 else { return false }
        return components[components.count - 1] == "java" && components[components.count - 3] == "src"
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
