import Foundation

struct IDEFileNode: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [IDEFileNode]?
    var isExpanded: Bool

    init(url: URL, isDirectory: Bool, children: [IDEFileNode]? = nil, isExpanded: Bool = false) {
        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.children = children
        self.isExpanded = isExpanded
    }
}

@MainActor
final class IDEProjectModel: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var rootNode: IDEFileNode?
    @Published var expandedPaths: Set<String> = []

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

    func restoreRoot(from bookmarkData: Data?) {
        guard let bookmarkData else {
            setRoot(nil)
            return
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            setRoot(nil)
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        setRoot(url)
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
