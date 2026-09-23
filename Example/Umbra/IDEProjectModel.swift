import Foundation
import Observation

struct IDEFileNode: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [IDEFileNode]?
    var isExpanded: Bool
    /// Overrides `name` in the Explorer, e.g. a dotted package name when packages are flattened.
    var displayName: String?

    init(
        url: URL,
        isDirectory: Bool,
        children: [IDEFileNode]? = nil,
        isExpanded: Bool = false,
        displayName: String? = nil
    ) {
        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.children = children
        self.isExpanded = isExpanded
        self.displayName = displayName
    }
}

@MainActor
@Observable
final class IDEProjectModel {
    private(set) var rootURL: URL?
    private(set) var rootNode: IDEFileNode?
    var expandedPaths: Set<String> = []

    /// Directory names skipped when building the sidebar tree and the Go to File candidate
    /// list. Kept local rather than shared with `ProjectSearchEngine`'s `FileEnumerationPolicy`:
    /// this walk needs to stay synchronous (it feeds `CommandPaletteController.fileEntriesProvider`
    /// directly), while project search runs off the main actor.
    private static let ignoredDirectoryNames: Set<String> = [
        ".git", ".build", "node_modules", "DerivedData", ".swiftpm", "Pods", ".cursor"
    ]

    func setRoot(_ url: URL?) {
        rootURL = url
        if let url {
            rootNode = buildNode(at: url, isDirectory: true)
            expandedPaths.insert(url.path)
        } else {
            rootNode = nil
            expandedPaths = []
        }
    }

    /// Resolves a security-scoped project bookmark and starts access. `nil` when there is no
    /// bookmark or it can no longer be resolved. Does not update the model -- callers that also
    /// need Java/terminal side effects should pass the result through `IDEWorkspace`'s project-root
    /// path instead of `setRoot` alone.
    func rootURL(from bookmarkData: Data?) -> URL? {
        guard let bookmarkData else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    func restoreRoot(from bookmarkData: Data?) {
        setRoot(rootURL(from: bookmarkData))
    }

    func makeBookmarkData() -> Data? {
        guard let rootURL else { return nil }
        return try? rootURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func toggleExpanded(_ node: IDEFileNode) {
        guard node.isDirectory else { return }
        if expandedPaths.contains(node.id) {
            expandedPaths.remove(node.id)
        } else {
            expandedPaths.insert(node.id)
        }
    }

    func isExpanded(_ node: IDEFileNode) -> Bool {
        expandedPaths.contains(node.id)
    }

    /// Expands every ancestor from the project root down to `url` so the Explorer shows that
    /// folder. No-op when no project is open or `url` sits outside the root.
    func reveal(url: URL) {
        guard let rootURL else { return }
        let root = rootURL.standardizedFileURL
        let target = url.standardizedFileURL
        let rootPath = root.path
        let targetPath = target.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else { return }

        var current = root
        expandedPaths.insert(current.path)
        let relative = targetPath.dropFirst(rootPath.count)
        for component in relative.split(separator: "/") where !component.isEmpty {
            current.appendPathComponent(String(component))
            expandedPaths.insert(current.path)
        }
    }

    func allProjectFiles() -> [URL] {
        guard let rootURL else { return [] }
        var files: [URL] = []
        collectFiles(at: rootURL, into: &files)
        return files.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private func collectFiles(at url: URL, into files: inout [URL]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") || Self.ignoredDirectoryNames.contains(name) {
                continue
            }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                collectFiles(at: entry, into: &files)
            } else {
                files.append(entry)
            }
        }
    }

    private func buildNode(at url: URL, isDirectory: Bool) -> IDEFileNode? {
        guard isDirectory else {
            return IDEFileNode(url: url, isDirectory: false)
        }
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            return IDEFileNode(url: url, isDirectory: true, children: [])
        }

        let children = entries
            .filter { entry in
                let name = entry.lastPathComponent
                return !name.hasPrefix(".") && !Self.ignoredDirectoryNames.contains(name)
            }
            .compactMap { entry -> IDEFileNode? in
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
                let isDir = values?.isDirectory == true
                return buildNode(at: entry, isDirectory: isDir)
            }
            .sorted { lhs, rhs in
                switch (lhs.isDirectory, rhs.isDirectory) {
                case (true, false): return true
                case (false, true): return false
                default:
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            }

        return IDEFileNode(url: url, isDirectory: true, children: children)
    }
}
