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
