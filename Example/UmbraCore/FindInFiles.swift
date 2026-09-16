import Foundation

/// One match from a project-folder Find in Files scan.
public struct FindInFilesHit: Equatable, Sendable, Identifiable {
    public var id: String { "\(url.path):\(matchRange.location):\(matchRange.length)" }
    public let url: URL
    /// 1-based line number of the match start.
    public let lineNumber: Int
    /// UTF-16 range of the match in the whole file (suitable for `TextView.selectedRange`).
    public let matchRange: NSRange
    public let lineText: String

    public init(url: URL, lineNumber: Int, matchRange: NSRange, lineText: String) {
        self.url = url
        self.lineNumber = lineNumber
        self.matchRange = matchRange
        self.lineText = lineText
    }
}

/// File + range to open when the user chooses a Find in Files hit.
public struct FindInFilesOpenTarget: Equatable, Sendable {
    public let url: URL
    public let range: NSRange
    public let lineNumber: Int

    public init(url: URL, range: NSRange, lineNumber: Int) {
        self.url = url
        self.range = range
        self.lineNumber = lineNumber
    }
}

/// Project-folder Find in Files: enumerate files on disk, search lines, open the chosen hit.
///
/// This is the path Umbra’s Find menu, ⌘⇧F, and tests all call. It does not use
/// `WorkspaceSearchEngine` (open buffers only).
public enum FindInFilesService {
    public static let ignoredDirectoryNames: Set<String> = [
        ".git", ".build", "node_modules", "DerivedData", ".swiftpm", "Pods", ".cursor"
    ]

    public static let maxFileByteCount = 2_000_000
    public static let maxHitCount = 2_000

    private static let skippedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "bmp",
        "pdf", "zip", "gz", "bz2", "xz", "tar", "7z",
        "woff", "woff2", "ttf", "otf", "eot",
        "mp3", "mp4", "mov", "wav", "aac",
        "o", "a", "dylib", "so", "exe", "bin", "wasm"
    ]

    /// Recursive text-file listing under `root`, skipping hidden names and known junk directories.
    public static func files(under root: URL, fileManager: FileManager = .default) -> [URL] {
        var files: [URL] = []
        enumerateFiles(at: root, fileManager: fileManager, into: &files)
        return files.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    /// Search `files` for `query` (case-insensitive substring). Empty / whitespace queries yield no hits.
    public static func search(query: String, files: [URL], fileManager: FileManager = .default) -> [FindInFilesHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var hits: [FindInFilesHit] = []
        for file in files {
            guard hits.count < maxHitCount else { break }
            searchFile(file, needle: needle, fileManager: fileManager, into: &hits)
        }
        return hits
    }

    /// Enumerate `root` then search. This is the scan entry the app uses when a folder is open.
    public static func search(query: String, root: URL, fileManager: FileManager = .default) -> [FindInFilesHit] {
        search(query: query, files: files(under: root, fileManager: fileManager), fileManager: fileManager)
    }

    /// Choosing a hit: the file URL plus the UTF-16 range on the matching line.
    public static func openTarget(for hit: FindInFilesHit) -> FindInFilesOpenTarget {
        FindInFilesOpenTarget(url: hit.url, range: hit.matchRange, lineNumber: hit.lineNumber)
    }

    private static func enumerateFiles(at url: URL, fileManager: FileManager, into files: inout [URL]) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") || ignoredDirectoryNames.contains(name) {
                continue
            }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                continue
            }
            if values?.isDirectory == true {
                enumerateFiles(at: entry, fileManager: fileManager, into: &files)
            } else {
                files.append(entry)
            }
        }
    }

    private static func searchFile(
        _ url: URL,
        needle: String,
        fileManager: FileManager,
        into hits: inout [FindInFilesHit]
    ) {
        let ext = url.pathExtension.lowercased()
        if skippedExtensions.contains(ext) { return }
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size > 0, size <= maxFileByteCount else {
            return
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return }
        if data.contains(0) { return }
        guard let text = String(data: data, encoding: .utf8) else { return }

        let nsText = text as NSString
        let options: NSString.CompareOptions = [.caseInsensitive]
        var searchRange = NSRange(location: 0, length: nsText.length)
        while hits.count < maxHitCount, searchRange.length > 0 {
            let found = nsText.range(of: needle, options: options, range: searchRange)
            if found.location == NSNotFound { break }
            let lineRange = nsText.lineRange(for: NSRange(location: found.location, length: 0))
            let lineNumber = newlineCount(in: nsText, before: found.location) + 1
            var lineText = nsText.substring(with: lineRange)
            if lineText.hasSuffix("\n") { lineText.removeLast() }
            if lineText.hasSuffix("\r") { lineText.removeLast() }
            hits.append(
                FindInFilesHit(
                    url: url,
                    lineNumber: lineNumber,
                    matchRange: found,
                    lineText: lineText
                )
            )
            let nextLocation = found.location + max(found.length, 1)
            if nextLocation >= nsText.length { break }
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }
    }

    private static func newlineCount(in text: NSString, before location: Int) -> Int {
        guard location > 0 else { return 0 }
        let prefix = text.substring(to: min(location, text.length))
        return prefix.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
    }
}
