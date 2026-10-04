import Foundation

/// What a project walk skips. The same list Find in Files uses in Umbra: build outputs, VCS and
/// tool folders, hidden files, binaries and anything too big to be source.
public struct FileFilter: Sendable {
    public var ignoredDirectories: Set<String>
    public var binaryExtensions: Set<String>
    public var maxFileBytes: Int

    public static let `default` = FileFilter(
        ignoredDirectories: [".git", ".gradle", ".idea", ".build", "build", "out", "node_modules", "target", "DerivedData", "Pods"],
        binaryExtensions: [
            "png", "jpg", "jpeg", "gif", "ico", "icns", "pdf", "zip", "gz", "jar", "class", "war", "so", "dylib",
            "a", "o", "exe", "dll", "bin", "dmg", "mp3", "mp4", "mov", "wav", "ttf", "otf", "woff", "woff2", "sqlite", "db",
        ],
        maxFileBytes: 2_000_000)

    public init(ignoredDirectories: Set<String>, binaryExtensions: Set<String>, maxFileBytes: Int) {
        self.ignoredDirectories = ignoredDirectories
        self.binaryExtensions = binaryExtensions
        self.maxFileBytes = maxFileBytes
    }

    func skipsDirectory(_ name: String) -> Bool { name.hasPrefix(".") || ignoredDirectories.contains(name) }
    func skipsFile(_ name: String) -> Bool {
        name.hasPrefix(".") || binaryExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }
}

/// An `AgentWorkspace` over a folder on disk, for tests and the eval CLI. Umbra has its own, which
/// reads open buffers.
public struct DiskAgentWorkspace: AgentWorkspace {
    public let jail: PathJail
    public let filter: FileFilter
    /// Reading is allowed a little past the search limit; a log file is still worth paging through.
    public let maxReadBytes: Int
    /// Text of open files with edits not yet saved, keyed by absolute path. Asked once per read or
    /// search, so it should return only the files that differ from disk.
    private let unsavedBuffers: @Sendable () async -> [String: String]
    public let writeProtection: WriteProtection

    public var rootPath: String { jail.root.path }

    public init(
        root: URL,
        filter: FileFilter = .default,
        maxReadBytes: Int = 5_000_000,
        writeProtection: WriteProtection = .default,
        unsavedBuffers: @escaping @Sendable () async -> [String: String] = { [:] }
    ) {
        self.jail = PathJail(root: root)
        self.filter = filter
        self.maxReadBytes = maxReadBytes
        self.writeProtection = writeProtection
        self.unsavedBuffers = unsavedBuffers
    }

    /// Unsaved buffers by resolved path, so `/var/...` and `/private/var/...` spellings agree.
    private func buffers() async -> [String: String] {
        var result: [String: String] = [:]
        for (path, text) in await unsavedBuffers() {
            result[URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path] = text
        }
        return result
    }

    public func readText(path: String) async throws -> String {
        let url = try jail.resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AgentWorkspaceError.notFound(path)
        }
        guard !isDirectory.boolValue else { throw AgentWorkspaceError.notAFile(path) }
        if let unsaved = await buffers()[url.path] { return unsaved }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= maxReadBytes else { throw AgentWorkspaceError.tooLarge(path: path, bytes: size) }
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8)
        else { throw AgentWorkspaceError.notText(path) }
        return text
    }

    public func listDirectory(path: String) async throws -> [DirectoryEntry] {
        let url = try jail.resolve(path.isEmpty ? "." : path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AgentWorkspaceError.notFound(path)
        }
        guard isDirectory.boolValue else { throw AgentWorkspaceError.notADirectory(path) }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        return names.compactMap { name -> DirectoryEntry? in
            var childIsDirectory: ObjCBool = false
            let child = url.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: child.path, isDirectory: &childIsDirectory) else { return nil }
            if childIsDirectory.boolValue { return filter.skipsDirectory(name) ? nil : DirectoryEntry(name: name, isDirectory: true) }
            return filter.skipsFile(name) ? nil : DirectoryEntry(name: name, isDirectory: false)
        }
        // Folders first, like the Explorer, then by name.
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func allFiles() async throws -> [String] {
        try files(under: nil)
    }

    private func files(under subpath: String?) throws -> [String] {
        let start = try jail.resolve(subpath ?? ".")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: start.path, isDirectory: &isDirectory) else {
            throw AgentWorkspaceError.notFound(subpath ?? ".")
        }
        if !isDirectory.boolValue { return [jail.relativePath(of: start)] }

        guard let walker = FileManager.default.enumerator(
            at: start, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        var result: [String] = []
        for case let url as URL in walker {
            if Task.isCancelled { break }
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if filter.skipsDirectory(name) { walker.skipDescendants() }
            } else if values?.isRegularFile == true, !filter.skipsFile(name) {
                result.append(jail.relativePath(of: url))
            }
        }
        return result.sorted()
    }

    public func search(_ query: SearchQuery) async throws -> SearchResults {
        let source = query.isRegex ? query.pattern : NSRegularExpression.escapedPattern(for: query.pattern)
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: source, options: query.caseSensitive ? [] : [.caseInsensitive])
        } catch {
            throw AgentWorkspaceError.invalidPattern(query.pattern)
        }
        let glob = try query.fileGlob.map(GlobPattern.init)
        let unsaved = await buffers()

        var matches: [SearchMatch] = []
        var truncated = false
        files: for relative in try files(under: query.path) {
            try Task.checkCancellation()
            if let glob, !glob.matches(relative) { continue }
            guard let text = readSearchable(relative, unsaved: unsaved) else { continue }
            var lineNumber = 0
            for line in text.components(separatedBy: "\n") {
                lineNumber += 1
                guard regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                if matches.count == query.maxResults {
                    truncated = true
                    break files
                }
                matches.append(SearchMatch(path: relative, line: lineNumber, text: line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))))
            }
        }
        return SearchResults(matches: matches, truncated: truncated)
    }

    private func readSearchable(_ relative: String, unsaved: [String: String]) -> String? {
        guard let url = try? jail.resolve(relative) else { return nil }
        if let text = unsaved[url.path] { return text }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int),
              size <= filter.maxFileBytes,
              let data = FileManager.default.contents(atPath: url.path),
              !data.prefix(8_192).contains(0)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Writing

    public func checkWritable(path: String) throws {
        _ = try writableURL(path)
    }

    private func writableURL(_ path: String) throws -> URL {
        let url = try jail.resolve(path)
        guard url.path != jail.root.path else { throw AgentWorkspaceError.notAFile(path) }
        if writeProtection.isProtected(url, root: jail.root) { throw AgentWorkspaceError.writeProtected(path) }
        return url
    }

    /// Disk only: an editor holding unsaved changes to the file would silently diverge, so the
    /// app's own workspace handles open files and this one refuses them.
    public func replaceText(path: String, expecting: String, edits: [AgentTextEdit]) async throws {
        let url = try writableURL(path)
        if await buffers()[url.path] != nil { throw AgentWorkspaceError.unsavedBuffer(path) }
        let current = try await readText(path: path)
        guard current == expecting else { throw AgentWorkspaceError.changedSinceRead(path) }
        let updated = try AgentTextEdit.apply(edits, to: current)
        try Self.writeAtomically(updated, to: url, path: path)
    }

    public func createFile(path: String, contents: String) async throws {
        let url = try writableURL(path)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw AgentWorkspaceError.alreadyExists(path) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw AgentWorkspaceError.writeFailed(path: path, reason: error.localizedDescription)
        }
        try Self.writeAtomically(contents, to: url, path: path)
    }

    public func trashFile(path: String) async throws {
        let url = try writableURL(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AgentWorkspaceError.notFound(path) }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            throw AgentWorkspaceError.writeFailed(path: path, reason: error.localizedDescription)
        }
    }

    /// UTF-8, atomic, keeping the file's permissions.
    private static func writeAtomically(_ text: String, to url: URL, path: String) throws {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        } catch {
            throw AgentWorkspaceError.writeFailed(path: path, reason: error.localizedDescription)
        }
    }
}
