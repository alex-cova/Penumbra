import EditorIntelligence
import Foundation

/// Project packages for Go to Package. Built beside the file index, off the main thread, from
/// directories under a Java or Kotlin source root. JDK and library packages are not included.
struct IDEJavaPackageIndex: Sendable, Equatable {
    struct SourceRoot: Sendable, Equatable {
        var path: String
        /// Trailing column (`app.main`). The source-set name when no Gradle model is synced yet.
        var module: String?
        var isTest: Bool
    }

    struct Entry: Sendable, Equatable {
        /// Empty for the default package.
        var name: String
        var url: URL
        /// Path of the package directory relative to the project root.
        var relativePath: String
        var module: String?
        var isTest: Bool

        var title: String { name.isEmpty ? "(default package)" : name }

        /// Text ``CompletionMatcher`` sees. The displayed title wraps the default package in
        /// parentheses, which are not part of the match.
        var matchText: String { name.isEmpty ? "default package" : name }
    }

    struct Hit: Sendable, Equatable {
        var entry: Entry
        /// Offsets into ``Entry/title``.
        var matchedOffsets: [Int]
    }

    var entries: [Entry]

    static let empty = IDEJavaPackageIndex(entries: [])

    /// A directory strictly inside `sourceRoot` (the root itself is the default package, recorded
    /// separately when a source file sits there). `nil` when `directoryPath` is not inside it.
    static func packageEntry(directoryPath: String, projectRoot: String, sourceRoot: SourceRoot) -> Entry? {
        let prefix = sourceRoot.path + "/"
        guard directoryPath.hasPrefix(prefix) else { return nil }
        let relativeToSource = String(directoryPath.dropFirst(prefix.count))
        guard !relativeToSource.isEmpty else { return nil }
        return Entry(
            name: relativeToSource.replacingOccurrences(of: "/", with: "."),
            url: URL(fileURLWithPath: directoryPath),
            relativePath: relativePath(of: directoryPath, projectRoot: projectRoot),
            module: sourceRoot.module,
            isTest: sourceRoot.isTest
        )
    }

    /// The unnamed package: source files that live directly in the source root.
    static func defaultPackage(sourceRoot: SourceRoot, projectRoot: String) -> Entry {
        Entry(
            name: "",
            url: URL(fileURLWithPath: sourceRoot.path),
            relativePath: relativePath(of: sourceRoot.path, projectRoot: projectRoot),
            module: sourceRoot.module,
            isTest: sourceRoot.isTest
        )
    }

    /// `src/<set>/java` or `src/<set>/kotlin` containing `path`, read from the path alone so a
    /// project that has not synced yet still has packages. Resource directories are not roots.
    static func conventionalSourceRoot(path: String, projectRoot: String) -> SourceRoot? {
        guard path == projectRoot || path.hasPrefix(projectRoot + "/") else { return nil }
        let relative = path == projectRoot ? "" : String(path.dropFirst(projectRoot.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        var found: (root: String, set: String)?
        var index = 0
        while index + 2 < components.count {
            if components[index] == "src" {
                let kind = components[index + 2]
                if kind == "java" || kind == "kotlin" {
                    let root = projectRoot + "/" + components[0...index + 2].joined(separator: "/")
                    if path == root || path.hasPrefix(root + "/") {
                        found = (root, components[index + 1])
                    }
                }
            }
            index += 1
        }
        guard let found else { return nil }
        return SourceRoot(
            path: found.root,
            module: found.set,
            isTest: found.set.lowercased().contains("test")
        )
    }

    /// Best matches first. An empty query lists packages in name order, capped at `limit`.
    func matching(_ query: String, limit: Int) -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0 else { return [] }
        if trimmed.isEmpty {
            let ordered = entries.sorted { lhs, rhs in
                let order = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.relativePath < rhs.relativePath
            }
            return ordered.prefix(limit).map { Hit(entry: $0, matchedOffsets: []) }
        }
        var ranked: [(entry: Entry, match: CompletionMatcher.Match)] = []
        ranked.reserveCapacity(min(entries.count, limit))
        for entry in entries {
            guard let match = CompletionMatcher.match(trimmed, in: entry.matchText) else { continue }
            ranked.append((entry, match))
        }
        ranked.sort { lhs, rhs in
            if lhs.match.degree != rhs.match.degree { return lhs.match.degree > rhs.match.degree }
            if lhs.entry.name.count != rhs.entry.name.count { return lhs.entry.name.count < rhs.entry.name.count }
            return lhs.entry.relativePath < rhs.entry.relativePath
        }
        return ranked.prefix(limit).map { pair in
            let shift = pair.entry.name.isEmpty ? 1 : 0
            return Hit(entry: pair.entry, matchedOffsets: pair.match.matchedOffsets.map { $0 + shift })
        }
    }

    /// Whether `path` is a package directory or sits inside one, so deleting that folder rebuilds.
    func contains(path: String) -> Bool {
        entries.contains { entry in
            let entryPath = entry.url.path
            return path == entryPath || path.hasPrefix(entryPath + "/")
        }
    }

    private static func relativePath(of path: String, projectRoot: String) -> String {
        if path == projectRoot { return "" }
        guard path.hasPrefix(projectRoot + "/") else { return path }
        return String(path.dropFirst(projectRoot.count + 1))
    }
}

/// Status-bar crumbs for a file under a Java or Kotlin source root: folders through the root,
/// then dotted packages. Files elsewhere keep one crumb per folder.
enum IDEJavaPackages {
    /// Crumbs from the project root through `file`, including the file. `tree` compacts
    /// single-child package chains; without it each directory is its own crumb.
    static func pathItems(
        file: URL,
        projectRoot: URL,
        knownSourceRoots: Set<String>,
        tree: IDEFileNode?
    ) -> [IDEBreadcrumbItem] {
        let file = file.standardizedFileURL
        let root = projectRoot.standardizedFileURL
        let directory = file.deletingLastPathComponent()
        let fileItem = IDEBreadcrumbItem(id: "file:\(file.path)", title: file.lastPathComponent, target: .file(file))
        let directoryPath = directory.path
        let rootPath = root.path
        guard directoryPath == rootPath || directoryPath.hasPrefix(rootPath + "/") else {
            return [fileItem]
        }

        let relative = directoryPath == rootPath ? "" : String(directoryPath.dropFirst(rootPath.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        // `-1` means the project root itself is the source root, so every directory below it is a package.
        var sourceIndex: Int? = IDEFlattenedPackages.isSourceRoot(root, sourceRootPaths: knownSourceRoots) ? -1 : nil
        var cursor = root
        for (index, component) in components.enumerated() {
            cursor.appendPathComponent(component)
            if IDEFlattenedPackages.isSourceRoot(cursor, sourceRootPaths: knownSourceRoots) {
                sourceIndex = index
            }
        }

        let folderEnd = sourceIndex ?? components.count - 1
        var items = folderItems(from: root, components: components, through: folderEnd)
        if let sourceIndex, sourceIndex + 1 < components.count {
            items.append(contentsOf: packageItems(
                components: components,
                startingAt: sourceIndex + 1,
                projectRoot: root,
                tree: tree
            ))
        }
        items.append(fileItem)
        return items
    }

    private static func folderItems(from root: URL, components: [String], through lastIndex: Int) -> [IDEBreadcrumbItem] {
        guard lastIndex >= 0 else { return [folderItem(root)] }
        var items = [folderItem(root)]
        var current = root
        for component in components.prefix(lastIndex + 1) {
            current.appendPathComponent(component)
            items.append(folderItem(current))
        }
        return items
    }

    private static func folderItem(_ url: URL) -> IDEBreadcrumbItem {
        IDEBreadcrumbItem(id: "folder:\(url.path)", title: url.lastPathComponent, target: .folder(url))
    }

    /// Compacted package crumbs for `components[start...]`. Each crumb's URL is the deepest
    /// directory the dotted name covers.
    private static func packageItems(
        components: [String],
        startingAt start: Int,
        projectRoot: URL,
        tree: IDEFileNode?
    ) -> [IDEBreadcrumbItem] {
        guard let tree, let limit = node(at: components, through: components.count - 1, from: projectRoot, in: tree) else {
            return uncompacted(components: components, from: start, projectRoot: projectRoot)
        }
        var items: [IDEBreadcrumbItem] = []
        var parent = node(at: components, through: start - 1, from: projectRoot, in: tree)
        var index = start
        while index < components.count {
            guard let currentParent = parent,
                  let child = currentParent.children?.first(where: { $0.name == components[index] }) else {
                items.append(contentsOf: uncompacted(components: components, from: index, projectRoot: projectRoot))
                break
            }
            let compacted = compactedToward(child, limitPath: limit.url.path)
            let title = compacted.displayName ?? compacted.name
            items.append(IDEBreadcrumbItem(
                id: "package:\(compacted.url.path)",
                title: title,
                target: .package(compacted.url)
            ))
            let parentPath = currentParent.url.path
            let consumed = compacted.url.path.hasPrefix(parentPath + "/")
                ? compacted.url.path.dropFirst(parentPath.count + 1).split(separator: "/").count
                : 1
            guard consumed > 0 else { break }
            index += consumed
            parent = compacted
        }
        return items
    }

    private static func uncompacted(components: [String], from start: Int, projectRoot: URL) -> [IDEBreadcrumbItem] {
        var items: [IDEBreadcrumbItem] = []
        var current = projectRoot
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            if index >= start {
                items.append(IDEBreadcrumbItem(
                    id: "package:\(current.path)",
                    title: component,
                    target: .package(current)
                ))
            }
        }
        return items
    }

    /// `IDEExplorerPresentation.compacted`, stopped at `limitPath` and unwilling to follow a
    /// single child that does not lead to the open file.
    private static func compactedToward(_ node: IDEFileNode, limitPath: String) -> IDEFileNode {
        var current = node
        var name = node.displayName ?? node.name
        var merged = false
        while current.url.path != limitPath {
            let kids = (current.children ?? []).filter { !$0.isExcluded }
            guard kids.count == 1, let only = kids.first, only.isDirectory else { break }
            let onlyPath = only.url.path
            guard onlyPath == limitPath || limitPath.hasPrefix(onlyPath + "/") else { break }
            name += "." + (only.displayName ?? only.name)
            current = only
            merged = true
        }
        guard merged else { return node }
        var result = current
        result.displayName = name
        return result
    }

    private static func node(at components: [String], through lastIndex: Int, from root: URL, in tree: IDEFileNode) -> IDEFileNode? {
        guard lastIndex >= 0 else { return tree }
        var current = tree
        var url = root
        for component in components.prefix(lastIndex + 1) {
            url.appendPathComponent(component)
            guard let next = current.children?.first(where: { $0.name == component || $0.url.path == url.path }) else {
                return nil
            }
            current = next
        }
        return current
    }
}
