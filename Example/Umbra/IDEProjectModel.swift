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
    /// The project folder was deleted or moved out from under the open window.
    private(set) var isRootMissing = false
    @ObservationIgnored private var generation = 0
    /// The Explorer row highlighted as current (last clicked, or the revealed file).
    var selectedPath: String?
    private(set) var revealRequest: RevealRequest?
    /// Row currently showing the inline rename field.
    var renamingPath: String?
    /// A just-created placeholder file/folder awaiting its real name. Cancelling the rename deletes it.
    var pendingCreationPath: String?

    /// Asks the tree to scroll `path` into view. A fresh `token` per request lets the same file be
    /// revealed twice in a row.
    struct RevealRequest: Equatable {
        let path: String
        let centered: Bool
        let token = UUID()
    }

    /// Directory names skipped when building the sidebar tree and the Go to File candidate
    /// list. Kept local rather than shared with `ProjectSearchEngine`'s `FileEnumerationPolicy`:
    /// this walk needs to stay synchronous (it feeds `CommandPaletteController.fileEntriesProvider`
    /// directly), while project search runs off the main actor.
    nonisolated static let ignoredDirectoryNames: Set<String> = [
        ".git", ".build", "node_modules", "DerivedData", ".swiftpm", "Pods", ".cursor"
    ]

    func setRoot(_ url: URL?) {
        rootURL = url
        generation += 1
        isRootMissing = false
        if let url {
            rootNode = Self.buildNode(at: url, isDirectory: true)
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

    /// Expands every directory in the tree. The project root stays open.
    func expandAll() {
        guard let rootNode else { return }
        expandedPaths = Self.allDirectoryPaths(in: rootNode)
    }

    /// Collapses every folder except the project root.
    func collapseAll() {
        guard let rootURL else { return }
        expandedPaths = [rootURL.path]
    }

    /// Every directory path in the current tree, including the project root.
    func allDirectoryPaths() -> Set<String> {
        guard let rootNode else { return [] }
        return Self.allDirectoryPaths(in: rootNode)
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

    // MARK: - Live refresh

    /// More changed directories than this in one batch (`git checkout`, `gradle clean`) is cheaper
    /// to handle as a full rebuild than as many single-directory splices.
    private static let fullRebuildThreshold = 200

    /// Re-lists `directories` (paths that changed on disk) and splices the result into the tree.
    /// Unchanged child nodes are kept as-is, so expansion, selection and scroll position survive.
    func applyChanges(in directories: Set<String>) {
        Task { await refresh(directories: directories) }
    }

    /// Same as `applyChanges(in:)` but suspends until the tree reflects the result, so a caller
    /// that just created or renamed an item can rely on its row existing afterwards.
    func refresh(directories: Set<String>) async {
        guard let rootURL, !directories.isEmpty else { return }
        let generation = self.generation
        let rootPath = rootURL.path
        let rebuildEverything = directories.count > Self.fullRebuildThreshold
        let knownChildren = directories.reduce(into: [String: [String: Bool]]()) { result, path in
            if let node = node(at: path), let children = node.children {
                result[path] = Dictionary(uniqueKeysWithValues: children.map { ($0.id, $0.isDirectory) })
            }
        }

        do {
            let outcome = await Task.detached(priority: .utility) { () -> RefreshOutcome in
                guard FileManager.default.fileExists(atPath: rootPath) else { return .rootMissing }
                if rebuildEverything {
                    return .rebuilt(Self.buildNode(at: URL(fileURLWithPath: rootPath), isDirectory: true))
                }
                var listings: [DirectoryListing] = []
                var seen: Set<String> = []
                for path in directories {
                    let directory = Self.nearestExistingDirectory(from: path, root: rootPath)
                    guard seen.insert(directory).inserted else { continue }
                    let known = knownChildren[directory] ?? [:]
                    if let listing = Self.listDirectory(directory, known: known) {
                        listings.append(listing)
                    }
                }
                return .listings(listings)
            }.value
            guard self.generation == generation else { return }
            apply(outcome)
        }
    }

    private enum RefreshOutcome: Sendable {
        case rootMissing
        case rebuilt(IDEFileNode?)
        case listings([DirectoryListing])
    }

    /// One directory's fresh listing. `node` is nil for children that already exist unchanged.
    private struct DirectoryListing: Sendable {
        struct Entry: Sendable {
            let id: String
            let node: IDEFileNode?
        }

        let path: String
        let entries: [Entry]
    }

    private func apply(_ outcome: RefreshOutcome) {
        switch outcome {
        case .rootMissing:
            rootNode = nil
            isRootMissing = true
            expandedPaths = []
        case .rebuilt(let node):
            rootNode = node
            isRootMissing = false
            pruneExpandedPaths()
        case .listings(let listings):
            isRootMissing = false
            for listing in listings { splice(listing) }
        }
    }

    private func splice(_ listing: DirectoryListing) {
        guard var root = rootNode, let existing = node(at: listing.path, in: root)?.children else { return }
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let merged = listing.entries.compactMap { entry in entry.node ?? existingByID[entry.id] }
        let unchanged = listing.entries.allSatisfy { $0.node == nil } && merged.map(\.id) == existing.map(\.id)
        guard !unchanged else { return }
        let removed = Set(existing.map(\.id)).subtracting(merged.map(\.id))
        replaceChildren(of: listing.path, with: merged, in: &root)
        for id in removed { removeExpanded(under: id) }
    }

    private func replaceChildren(of path: String, with children: [IDEFileNode], in root: inout IDEFileNode) {
        _ = Self.mutate(&root, path: path) { $0.children = children }
        rootNode = root
    }

    func removeExpanded(under id: String) {
        expandedPaths = expandedPaths.filter { $0 != id && !$0.hasPrefix(id + "/") }
    }

    private func pruneExpandedPaths() {
        guard let rootNode else { return }
        var live: Set<String> = []
        func walk(_ node: IDEFileNode) {
            guard node.isDirectory else { return }
            live.insert(node.id)
            node.children?.forEach(walk)
        }
        walk(rootNode)
        expandedPaths = expandedPaths.intersection(live)
    }

    /// Moves state keyed by path (expansion, selection) from `old` to `new` after a rename.
    func didMove(from old: String, to new: String) {
        func remap(_ path: String) -> String {
            if path == old { return new }
            if path.hasPrefix(old + "/") { return new + path.dropFirst(old.count) }
            return path
        }
        expandedPaths = Set(expandedPaths.map(remap))
        selectedPath = selectedPath.map(remap)
    }

    func node(at path: String) -> IDEFileNode? {
        guard let rootNode else { return nil }
        return node(at: path, in: rootNode)
    }

    private func node(at path: String, in node: IDEFileNode) -> IDEFileNode? {
        if node.id == path { return node }
        guard path.hasPrefix(node.id + "/") else { return nil }
        for child in node.children ?? [] {
            if let found = self.node(at: path, in: child) { return found }
        }
        return nil
    }

    nonisolated private static func mutate(_ node: inout IDEFileNode, path: String, _ body: (inout IDEFileNode) -> Void) -> Bool {
        if node.id == path {
            body(&node)
            return true
        }
        guard path.hasPrefix(node.id + "/"), var children = node.children else { return false }
        for index in children.indices where mutate(&children[index], path: path, body) {
            node.children = children
            return true
        }
        return false
    }

    nonisolated private static func nearestExistingDirectory(from path: String, root: String) -> String {
        var current = path
        var isDirectory: ObjCBool = false
        while current.count > root.count {
            if FileManager.default.fileExists(atPath: current, isDirectory: &isDirectory), isDirectory.boolValue {
                return current
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return root
    }

    /// One level of `path`, filtered and sorted like `buildNode`. Children whose id and kind match
    /// `known` are returned without a node so the caller keeps its existing subtree.
    nonisolated private static func listDirectory(_ path: String, known: [String: Bool]) -> DirectoryListing? {
        let url = URL(fileURLWithPath: path)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let visible = entries.compactMap { entry -> (url: URL, isDirectory: Bool)? in
            let name = entry.lastPathComponent
            guard !name.hasPrefix("."), !ignoredDirectoryNames.contains(name) else { return nil }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            return (entry, isDirectory)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.url.lastPathComponent.localizedCaseInsensitiveCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
        let listed = visible.map { item -> DirectoryListing.Entry in
            let id = item.url.path
            if known[id] == item.isDirectory { return .init(id: id, node: nil) }
            return .init(id: id, node: buildNode(at: item.url, isDirectory: item.isDirectory))
        }
        return DirectoryListing(path: path, entries: listed)
    }

    /// Expands the ancestors of `url`, selects its row, and asks the tree to scroll to it.
    /// `centered` is for an explicit user request; automatic follow scrolls minimally.
    func revealAndSelect(url: URL, centered: Bool) {
        reveal(url: url)
        guard let rootURL else { return }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootURL.path + "/") else { return }
        selectedPath = path
        revealRequest = RevealRequest(path: path, centered: centered)
    }

    /// Scrolls `path` into view without changing expansion or selection (keyboard navigation).
    func requestScroll(to path: String) {
        revealRequest = RevealRequest(path: path, centered: false)
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

    nonisolated private static func allDirectoryPaths(in node: IDEFileNode) -> Set<String> {
        var paths = Set<String>()
        func walk(_ node: IDEFileNode) {
            guard node.isDirectory else { return }
            paths.insert(node.id)
            node.children?.forEach(walk)
        }
        walk(node)
        return paths
    }

    nonisolated private static func buildNode(at url: URL, isDirectory: Bool) -> IDEFileNode? {
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
                return !name.hasPrefix(".") && !ignoredDirectoryNames.contains(name)
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
