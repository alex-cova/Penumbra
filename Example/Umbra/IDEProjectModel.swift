import Foundation
import UmbraCore

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

    private static var ignoredDirectoryNames: Set<String> { FindInFilesService.ignoredDirectoryNames }

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
        return FindInFilesService.files(under: rootURL)
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
