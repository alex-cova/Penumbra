import Foundation

/// File map and cold walk shared by the native language indexes.
///
/// A language index actor stores one value and mutates it on its own executor.
/// `generation`, pending edits, and the file map then stay in the same isolation
/// domain as that index's lookup tables, so `SwiftIndex.applyFileChanges` can
/// remain synchronous. A nested actor would make that method asynchronous.
///
/// The value stores files and reports additions and removals. It does not know
/// about declarations. Skip lists, extensions, and the parser arrive as
/// `Configuration`. Enumeration uses `FileManager` with `.skipsHiddenFiles`,
/// skips a configured directory, ignores non-source files, and skips a file
/// over `maxBytes`. Parsing fans out to eight tasks. A cancelled walk does not
/// publish: `isCurrent` is false after a newer `beginWalk`, and `cancelWalk`
/// drops the token without replacing the file map.
public struct SourceFileIndex<Model: Sendable> {
    public struct Configuration: Sendable {
        public var skipDirectories: Set<String>
        public var maxBytes: Int
        public var isSourceFile: @Sendable (URL) -> Bool
        public var isSkipped: @Sendable (URL) -> Bool
        public var parse: @Sendable (String, URL) -> Model?

        public init(
            skipDirectories: Set<String>,
            maxBytes: Int,
            isSourceFile: @escaping @Sendable (URL) -> Bool,
            isSkipped: @escaping @Sendable (URL) -> Bool,
            parse: @escaping @Sendable (String, URL) -> Model?
        ) {
            self.skipDirectories = skipDirectories
            self.maxBytes = maxBytes
            self.isSourceFile = isSourceFile
            self.isSkipped = isSkipped
            self.parse = parse
        }
    }

    /// One `beginWalk`. `root` is nil when the caller asked to clear the index.
    public struct Walk: Sendable {
        public var token: Int
        public var root: URL?
    }

    /// What a file-map edit did, so the owning index can update its own tables.
    public enum FileChange: Sendable {
        case added(URL, Model)
        case removed(URL, Model)
    }

    public let configuration: Configuration
    public private(set) var openBuffer: (@Sendable (URL) async -> String?)?

    private var root: URL?
    private var generation = 0
    private var buildingToken: Int?
    private var pendingEdits: [URL: Model?] = [:]
    private var files: [URL: Model] = [:]

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var fileCount: Int { files.count }
    public var isBuilding: Bool { buildingToken != nil }
    public var storedFiles: [URL: Model] { files }

    public mutating func setOpenBufferLookup(_ lookup: (@Sendable (URL) async -> String?)?) {
        openBuffer = lookup
    }

    public func contains(_ url: URL) -> Bool {
        files[url.standardizedFileURL] != nil
    }

    public func file(at url: URL) -> Model? {
        files[url.standardizedFileURL]
    }

    /// Bumps `generation`, clears pending edits, and stores `root`. A newer walk
    /// makes `isCurrent` false for every earlier token.
    public mutating func beginWalk(root: URL?) -> Walk {
        generation += 1
        let token = generation
        buildingToken = token
        pendingEdits = [:]
        let standardized = root?.standardizedFileURL
        self.root = standardized
        return Walk(token: token, root: standardized)
    }

    public func isCurrent(_ token: Int) -> Bool {
        token == generation
    }

    /// Ends a walk that must not publish. A newer walk's token is left alone.
    public mutating func cancelWalk(_ token: Int) {
        if buildingToken == token { buildingToken = nil }
    }

    /// Applies edits that arrived while `token`'s walk was parsing. Does not
    /// publish and does not clear the pending map; call `finishWalk` after the
    /// owner has published.
    public func mergingPending(into parsed: [URL: Model]) -> [URL: Model] {
        var merged = parsed
        for (url, edit) in pendingEdits {
            if let edit {
                merged[url] = edit
            } else {
                merged.removeValue(forKey: url)
            }
        }
        return merged
    }

    public mutating func finishWalk(_ token: Int) {
        pendingEdits = [:]
        if buildingToken == token { buildingToken = nil }
    }

    /// Records an add or a delete while a walk is in flight. A nil model removes
    /// the file when that walk merges.
    public mutating func recordPending(_ url: URL, _ model: Model?) {
        if buildingToken != nil {
            pendingEdits[url.standardizedFileURL] = model
        }
    }

    @discardableResult
    public mutating func insert(_ url: URL, _ model: Model) -> FileChange {
        let standardized = url.standardizedFileURL
        files[standardized] = model
        return .added(standardized, model)
    }

    /// Removes `url` and reports the model that left the map, so the owner can
    /// drop it from lookup tables. Nil when the file was not stored.
    public mutating func remove(_ url: URL) -> FileChange? {
        let standardized = url.standardizedFileURL
        guard let model = files.removeValue(forKey: standardized) else { return nil }
        return .removed(standardized, model)
    }

    public mutating func removeAll() {
        files = [:]
    }

    public mutating func replaceFiles(with models: [URL: Model]) {
        files = models
    }

    public func parse(_ source: String, url: URL) -> Model? {
        configuration.parse(source, url)
    }

    public static func enumerate(root: URL, configuration: Configuration) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var urls: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if configuration.skipDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard configuration.isSourceFile(url), !configuration.isSkipped(url) else { continue }
            if let size = values?.fileSize, size > configuration.maxBytes { continue }
            urls.append(url.standardizedFileURL)
        }
        return urls
    }

    public static func parseAll(_ urls: [URL], configuration: Configuration) async -> [URL: Model] {
        let limit = 8
        return await withTaskGroup(of: (URL, Model)?.self) { group in
            var next = 0
            func add(_ url: URL) {
                group.addTask {
                    if Task.isCancelled { return nil }
                    guard let source = readDisk(url, maxBytes: configuration.maxBytes) else { return nil }
                    guard let model = configuration.parse(source, url) else { return nil }
                    return (url, model)
                }
            }
            while next < urls.count && next < limit {
                add(urls[next])
                next += 1
            }
            var result: [URL: Model] = [:]
            for await item in group {
                if let (url, model) = item { result[url] = model }
                if next < urls.count {
                    add(urls[next])
                    next += 1
                }
            }
            return result
        }
    }

    public static func readDisk(_ url: URL, maxBytes: Int) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        guard data.count <= maxBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
