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

    /// Recursive listing of text-file candidates under `root`, filtered by `policy`. Directories
    /// are walked depth-first and sorted case-insensitively.
    public func files(under root: URL, policy: FileEnumerationPolicy = .default) async -> [URL] {
        var files: [URL] = []
        enumerateFiles(at: root, policy: policy, into: &files)
        return files.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    /// Enumerates `root` then searches the results. A blank (or whitespace-only, outside regex
    /// mode) `query.text` yields no results.
    public func search(
        _ query: WorkspaceSearchQuery,
        in root: URL,
        policy: FileEnumerationPolicy = .default,
        maxResults: Int = 2_000
    ) async -> [ProjectSearchResult] {
        guard !isEffectivelyEmpty(query) else {
            return []
        }
        let files = await files(under: root, policy: policy)
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
        guard let regex = try? NSRegularExpression(pattern: regexPattern(for: query), options: regexOptions(for: query)) else {
            return []
        }
        var results: [ProjectSearchResult] = []
        for file in files {
            guard !Task.isCancelled, results.count < maxResults else { break }
            searchFile(file, regex: regex, policy: policy, maxResults: maxResults, into: &results)
        }
        return results
    }

    private func enumerateFiles(at url: URL, policy: FileEnumerationPolicy, into files: inout [URL]) {
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
            if values?.isDirectory == true {
                enumerateFiles(at: entry, policy: policy, into: &files)
            } else {
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

    private func regexPattern(for query: WorkspaceSearchQuery) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: query.text)
        if query.useRegularExpression {
            return query.text
        }
        if query.matchWholeWord {
            return "\\b\(escaped)\\b"
        }
        return escaped
    }

    private func regexOptions(for query: WorkspaceSearchQuery) -> NSRegularExpression.Options {
        query.isCaseSensitive ? [] : [.caseInsensitive]
    }
}
