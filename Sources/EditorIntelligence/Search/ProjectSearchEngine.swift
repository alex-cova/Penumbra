import Foundation

/// Enumeration policy for a disk-wide project search: which directories, extensions, and file
/// sizes to skip. Mirrors the ignore rules a text editor needs (VCS metadata, build output,
/// dependency caches, binaries) without any project-specific configuration.
public struct FileEnumerationPolicy: Sendable {
    /// Directory names skipped entirely, wherever they occur in the tree.
    public var ignoredDirectoryNames: Set<String>
    /// Lowercase file extensions (no leading dot) skipped without being opened.
    public var skippedExtensions: Set<String>
    /// Files larger than this are skipped without being opened.
    public var maxFileByteCount: Int
    /// Whether dotfiles/dot-directories are skipped.
    public var skipsHiddenFiles: Bool
    /// Whether symbolic links are followed. Default `false` avoids cycles and double-counting.
    public var followsSymbolicLinks: Bool

    public init(
        ignoredDirectoryNames: Set<String> = Self.defaultIgnoredDirectoryNames,
        skippedExtensions: Set<String> = Self.defaultSkippedExtensions,
        maxFileByteCount: Int = 2_000_000,
        skipsHiddenFiles: Bool = true,
        followsSymbolicLinks: Bool = false
    ) {
        self.ignoredDirectoryNames = ignoredDirectoryNames
        self.skippedExtensions = skippedExtensions
        self.maxFileByteCount = maxFileByteCount
        self.skipsHiddenFiles = skipsHiddenFiles
        self.followsSymbolicLinks = followsSymbolicLinks
    }

    public static let defaultIgnoredDirectoryNames: Set<String> = [
        ".git", ".build", "node_modules", "DerivedData", ".swiftpm", "Pods", ".cursor"
    ]

    public static let defaultSkippedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "bmp",
        "pdf", "zip", "gz", "bz2", "xz", "tar", "7z",
        "woff", "woff2", "ttf", "otf", "eot",
        "mp3", "mp4", "mov", "wav", "aac",
        "o", "a", "dylib", "so", "exe", "bin", "wasm"
    ]

    public static let `default` = FileEnumerationPolicy()

    /// Whether a project-relative path would survive the disk walk: a hidden name or an ignored
    /// directory name anywhere in it is skipped. Used when a caller already has the file list.
    public func includes(relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return false }
        for name in parts {
            if (skipsHiddenFiles && name.hasPrefix(".")) || ignoredDirectoryNames.contains(name) {
                return false
            }
        }
        return true
    }
}

/// Narrows a project search or replace. One value feeds both Find and Replace, so the two can
/// never disagree on the file set.
public struct ProjectSearchFilter: Sendable, Equatable {
    /// A file mask, matched against paths relative to the search root.
    public var mask: FileMask
    /// Restricts the walk to this folder. It must be inside the search root; a folder outside it
    /// yields no files.
    public var directory: URL?
    /// Searches exactly these files (Open Files, Changed Files) instead of walking. Files outside
    /// the search root or `directory` are dropped; the mask still applies.
    public var onlyFiles: Set<URL>?

    public init(mask: FileMask = FileMask(""), directory: URL? = nil, onlyFiles: Set<URL>? = nil) {
        self.mask = mask
        self.directory = directory
        self.onlyFiles = onlyFiles
    }

    public static let none = ProjectSearchFilter()

    public var isUnrestricted: Bool { mask.isEmpty && directory == nil && onlyFiles == nil }
}

/// A single match from a disk-wide project search.
public struct ProjectSearchResult: Sendable, Hashable, Identifiable {
    public var id: String { "\(url.path):\(range.start.utf16Offset):\(range.end.utf16Offset)" }
    public let url: URL
    /// 0-based line, matching ``WorkspaceSearchResult/line``.
    public let line: Int
    public let column: Int
    public let preview: String
    public let range: TextRange

    public init(url: URL, line: Int, column: Int, preview: String, range: TextRange) {
        self.url = url
        self.line = line
        self.column = column
        self.preview = preview
        self.range = range
    }
}

/// Searches a folder on disk — the counterpart to ``WorkspaceSearchEngine``, which only sees
/// open documents. Runs off the main actor; enumeration and per-file scanning both honor
/// cancellation so a superseded search stops promptly.
public actor ProjectSearchEngine {
    public init() {}

    /// Recursive listing of text-file candidates under `root`, filtered by `policy` and `filter`.
    /// Directories are walked depth-first and sorted case-insensitively. A directory the mask
    /// excludes is never read, and a file the mask rejects is never opened.
    ///
    /// `visibleRelativePaths`, when set, replaces the walk: only those project-relative paths are
    /// considered (still subject to `policy` and `filter`). That is how a host passes the files
    /// git would show. Nil keeps the walk. An explicit `filter.onlyFiles` list is never cut by it,
    /// because the user named those files.
    public func files(
        under root: URL,
        policy: FileEnumerationPolicy = .default,
        filter: ProjectSearchFilter = .none,
        visibleRelativePaths: Set<String>? = nil
    ) async -> [URL] {
        guard filter.mask.isValid else { return [] }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        var scopePath = rootPath
        if let directory = filter.directory {
            let path = directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard path == rootPath || path.hasPrefix(rootPath + "/") else { return [] }
            scopePath = path
        }
        var files: [URL] = []
        if let only = filter.onlyFiles {
            for url in only {
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard path.hasPrefix(scopePath + "/") else { continue }
                let relative = String(path.dropFirst(rootPath.count + 1))
                guard filter.mask.matches(relativePath: relative) else { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                files.append(url)
            }
        } else if let visible = visibleRelativePaths {
            let scopeRelative = scopePath == rootPath ? "" : String(scopePath.dropFirst(rootPath.count + 1))
            collectVisible(
                visible, root: root, rootPath: rootPath, scopeRelative: scopeRelative,
                policy: policy, mask: filter.mask, into: &files)
        } else {
            let scopeRelative = scopePath == rootPath ? "" : String(scopePath.dropFirst(rootPath.count + 1))
            let start = scopeRelative.isEmpty ? root : root.appendingPathComponent(scopeRelative, isDirectory: true)
            enumerateFiles(at: start, relativeDirectory: scopeRelative, policy: policy, mask: filter.mask, into: &files)
        }
        return files.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    /// Enumerates `root` then searches the results. A blank (or whitespace-only, outside regex
    /// mode) `query.text` yields no results.
    public func search(
        _ query: WorkspaceSearchQuery,
        in root: URL,
        policy: FileEnumerationPolicy = .default,
        filter: ProjectSearchFilter = .none,
        maxResults: Int = 2_000,
        visibleRelativePaths: Set<String>? = nil
    ) async -> [ProjectSearchResult] {
        guard !isEffectivelyEmpty(query) else {
            return []
        }
        let files = await files(under: root, policy: policy, filter: filter, visibleRelativePaths: visibleRelativePaths)
        return await search(query, files: files, policy: policy, maxResults: maxResults)
    }

    /// Searches `files` for `query`. Exposed separately so callers with their own candidate list
    /// (e.g. an already-enumerated project index) can skip re-scanning the disk tree.
    public func search(
        _ query: WorkspaceSearchQuery,
        files: [URL],
        policy: FileEnumerationPolicy = .default,
        maxResults: Int = 2_000
    ) async -> [ProjectSearchResult] {
        guard !isEffectivelyEmpty(query) else {
            return []
        }
        guard let regex = query.compiledRegularExpression() else {
            return []
        }
        var results: [ProjectSearchResult] = []
        for file in files {
            guard !Task.isCancelled, results.count < maxResults else { break }
            searchFile(file, regex: regex, policy: policy, maxResults: maxResults, into: &results)
        }
        return results
    }

    /// `visible` paths are project-relative. A symlink is skipped unless the policy follows them,
    /// matching the walk, and a path that resolves outside `root` is dropped.
    private func collectVisible(
        _ visible: Set<String>,
        root: URL,
        rootPath: String,
        scopeRelative: String,
        policy: FileEnumerationPolicy,
        mask: FileMask,
        into files: inout [URL]
    ) {
        for relative in visible {
            guard !Task.isCancelled else { return }
            guard policy.includes(relativePath: relative), mask.matches(relativePath: relative) else { continue }
            if !scopeRelative.isEmpty, relative != scopeRelative, !relative.hasPrefix(scopeRelative + "/") { continue }
            let url = root.appendingPathComponent(relative)
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values?.isSymbolicLink == true && !policy.followsSymbolicLinks { continue }
            if values?.isDirectory == true { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else { continue }
            files.append(url)
        }
    }

    private func enumerateFiles(
        at url: URL,
        relativeDirectory: String,
        policy: FileEnumerationPolicy,
        mask: FileMask,
        into files: inout [URL]
    ) {
        guard !Task.isCancelled else { return }
        var options: FileManager.DirectoryEnumerationOptions = []
        if policy.skipsHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: options
        ) else {
            return
        }
        for entry in entries {
            guard !Task.isCancelled else { return }
            let name = entry.lastPathComponent
            if (policy.skipsHiddenFiles && name.hasPrefix(".")) || policy.ignoredDirectoryNames.contains(name) {
                continue
            }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true && !policy.followsSymbolicLinks {
                continue
            }
            // Built up rather than cut from `entry.path`, which FileManager may report with symlinks resolved.
            let relative = relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
            if values?.isDirectory == true {
                if mask.isExcluded(relativePath: relative) { continue }
                enumerateFiles(at: entry, relativeDirectory: relative, policy: policy, mask: mask, into: &files)
            } else if mask.matches(relativePath: relative) {
                files.append(entry)
            }
        }
    }

    private func searchFile(
        _ url: URL,
        regex: NSRegularExpression,
        policy: FileEnumerationPolicy,
        maxResults: Int,
        into results: inout [ProjectSearchResult]
    ) {
        let ext = url.pathExtension.lowercased()
        if policy.skippedExtensions.contains(ext) { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size > 0, size <= policy.maxFileByteCount else {
            return
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return }
        if data.contains(0) { return }
        guard let text = String(data: data, encoding: .utf8) else { return }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var lineNumber = 0
        var lastLineStart = 0
        for match in matches {
            guard results.count < maxResults else { return }
            lineNumber += newlineCount(in: nsText, from: lastLineStart, to: match.range.location)
            lastLineStart = match.range.location
            let lineRange = nsText.lineRange(for: NSRange(location: match.range.location, length: 0))
            let column = match.range.location - lineRange.location
            var preview = nsText.substring(with: lineRange)
            if preview.hasSuffix("\n") { preview.removeLast() }
            if preview.hasSuffix("\r") { preview.removeLast() }
            let start = TextPosition(line: lineNumber, column: column, utf16Offset: match.range.location)
            let end = TextPosition(
                line: lineNumber,
                column: column + match.range.length,
                utf16Offset: match.range.location + match.range.length
            )
            results.append(ProjectSearchResult(
                url: url,
                line: lineNumber,
                column: column,
                preview: preview,
                range: TextRange(start: start, end: end)
            ))
        }
    }

    /// Newlines between two offsets, walked once per file rather than rebuilding a prefix
    /// substring per match.
    private func newlineCount(in text: NSString, from start: Int, to end: Int) -> Int {
        guard end > start else { return 0 }
        var count = 0
        var index = start
        while index < end {
            if text.character(at: index) == 0x000A {
                count += 1
            }
            index += 1
        }
        return count
    }

    /// A whitespace-only query is treated as "no query" for a plain/whole-word search — a typed
    /// space shouldn't scan the whole tree for indentation. A regex query is exempt: `" +"` or a
    /// literal run of spaces may be exactly what's intended.
    private func isEffectivelyEmpty(_ query: WorkspaceSearchQuery) -> Bool {
        if query.useRegularExpression {
            return query.text.isEmpty
        }
        return query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
