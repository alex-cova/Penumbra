import CryptoKit
import Foundation

/// Why a revision of a file exists.
enum IDELocalHistorySource: Codable, Equatable {
    /// First seen when the file was opened; the starting point later changes are measured from.
    case baseline
    case save
    /// Written by an agent run in the chat named `tab`, asked `prompt`.
    case agent(tab: String, prompt: String)
    /// A rename, extract or other refactoring.
    case refactor(String)
    /// Restored from this history.
    case revert
    /// Changed on disk by something else while the file was open.
    case external
    /// Pinned with a name (`label` on the event).
    case label

    var isAgent: Bool { if case .agent = self { true } else { false } }
}

/// One change to one file: the content before and after, as hashes of stored texts.
struct IDELocalHistoryEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var time: Date
    /// Project-relative.
    var path: String
    /// `nil`: nothing was known before (the first revision, or the file did not exist).
    var before: String?
    /// `nil`: the file was deleted.
    var after: String?
    var source: IDELocalHistorySource
    /// Events made by one action (an agent run, one refactoring) share it, so they can be reverted together.
    var group: UUID?
    /// A name the user gave this revision. A named revision is kept past the usual age.
    var label: String?
}

/// Revisions of the files in one project, kept on disk: `index.jsonl` (one event a line, appended) and
/// `objects/<sha256>` (each distinct text once, compressed). Readable by the user alone, since it holds
/// file contents. Everything here is off the main thread; the window talks to it through
/// `IDELocalHistoryRecorder`.
actor IDELocalHistoryStore {
    static let maxFileBytes = 2_000_000
    static let defaultMaxAge: TimeInterval = 7 * 24 * 3_600
    static let defaultMaxBytes = 500_000_000

    let directory: URL
    private(set) var events: [IDELocalHistoryEvent] = []
    /// The newest known content hash of each path (`nil` once deleted).
    private var known: [String: String?] = [:]
    private let fileManager = FileManager.default

    private var indexURL: URL { directory.appendingPathComponent("index.jsonl") }
    private var objectsURL: URL { directory.appendingPathComponent("objects", isDirectory: true) }

    init(directory: URL) {
        self.directory = directory
        let loaded = Self.loadIndex(directory.appendingPathComponent("index.jsonl"))
        events = loaded
        for event in loaded { known[event.path] = .some(event.after) }
    }

    // MARK: - Recording

    /// Files that are not worth keeping revisions of: version control data and build output.
    static func isStorable(path: String, text: String?) -> Bool {
        let skipped: Set<String> = [".git", ".gradle", ".idea", ".build", "node_modules", "build", "target", "out", "DerivedData", ".svn", ".hg"]
        if path.split(separator: "/").dropLast().contains(where: { skipped.contains(String($0)) }) { return false }
        guard let text else { return true }
        return text.utf8.count <= maxFileBytes && !text.utf8.contains(0)
    }

    /// Records that `path` now has `text` (`nil`: it was deleted). Nothing is recorded when that is what
    /// is already known, so saving an unchanged file adds nothing. When the file has no history yet and the
    /// caller knows what it held just before (`assumingBefore`), that becomes its starting point first, so the
    /// change has a left side. Returns the event, if there was one.
    @discardableResult
    func record(
        path: String, text: String?, source: IDELocalHistorySource, group: UUID? = nil, label: String? = nil,
        assumingBefore prior: String? = nil, at time: Date = Date()
    ) -> IDELocalHistoryEvent? {
        guard Self.isStorable(path: path, text: text) else { return nil }
        if known[path] == nil, let prior, Self.isStorable(path: path, text: prior) {
            record(path: path, text: prior, source: .baseline, at: time.addingTimeInterval(-0.001))
        }
        let after = text.map(store)
        let isKnown = known[path] != nil
        let before: String? = known[path] ?? nil
        if label == nil, isKnown, before == after { return nil }
        let event = IDELocalHistoryEvent(time: time, path: path, before: before, after: after, source: source, group: group, label: label)
        events.append(event)
        known[path] = .some(after)
        appendToIndex(event)
        return event
    }

    /// The starting point of a file: recorded only if nothing is known about it yet.
    @discardableResult
    func recordBaseline(path: String, text: String, at time: Date = Date()) -> Bool {
        guard known[path] == nil else { return false }
        return record(path: path, text: text, source: .baseline, at: time) != nil
    }

    /// Pins the current revision of a file with a name.
    @discardableResult
    func putLabel(path: String, name: String, text: String, at time: Date = Date()) -> IDELocalHistoryEvent? {
        record(path: path, text: text, source: .label, label: name, at: time)
    }

    // MARK: - Reading

    /// A file's revisions, newest first.
    func events(forPath path: String) -> [IDELocalHistoryEvent] {
        events.filter { $0.path == path }.reversed()
    }

    /// Every event since `date`, newest first.
    func recentEvents(since date: Date = .distantPast, limit: Int = 500) -> [IDELocalHistoryEvent] {
        Array(events.reversed().prefix { $0.time >= date }.prefix(limit))
    }

    func hasHistory(forPath path: String) -> Bool { known[path] != nil }

    func content(of hash: String) -> String? {
        guard let data = try? Data(contentsOf: objectsURL.appendingPathComponent(hash)),
              let plain = try? (data as NSData).decompressed(using: .lzfse) as Data
        else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// The text of a file at an event: what it was after, or before when `before` is asked for.
    func text(of event: IDELocalHistoryEvent, before: Bool = false) -> String? {
        (before ? event.before : event.after).flatMap(content(of:))
    }

    // MARK: - Keeping it small

    /// Drops revisions older than `maxAge` (named ones stay) and then the oldest unnamed ones until the
    /// stored texts fit in `maxBytes`, and deletes every text nothing refers to. Returns how many events went.
    @discardableResult
    func prune(now: Date = Date(), maxAge: TimeInterval = defaultMaxAge, maxBytes: Int = defaultMaxBytes) -> Int {
        let originalCount = events.count
        let cutoff = now.addingTimeInterval(-maxAge)
        events.removeAll { $0.time < cutoff && $0.label == nil }

        var sizes = objectSizes()
        func referenced() -> Set<String> { Set(events.flatMap { [$0.before, $0.after].compactMap { $0 } }) }
        var live = referenced()
        var total = live.reduce(0) { $0 + (sizes[$1] ?? 0) }
        while total > maxBytes, let index = events.firstIndex(where: { $0.label == nil }) {
            events.remove(at: index)
            live = referenced()
            total = live.reduce(0) { $0 + (sizes[$1] ?? 0) }
        }
        for (hash, _) in sizes where !live.contains(hash) {
            try? fileManager.removeItem(at: objectsURL.appendingPathComponent(hash))
            sizes[hash] = nil
        }
        known = [:]
        for event in events { known[event.path] = .some(event.after) }
        if events.count != originalCount { rewriteIndex() }
        return originalCount - events.count
    }

    func clear() {
        events = []
        known = [:]
        try? fileManager.removeItem(at: directory)
    }

    /// What the stored texts take on disk.
    func storedBytes() -> Int { objectSizes().values.reduce(0, +) }

    // MARK: - Disk

    private func store(_ text: String) -> String {
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = objectsURL.appendingPathComponent(hash)
        guard !fileManager.fileExists(atPath: file.path) else { return hash }
        try? fileManager.createDirectory(at: objectsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let compressed = try? (Data(text.utf8) as NSData).compressed(using: .lzfse) as Data {
            try? compressed.write(to: file, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return hash
    }

    private func objectSizes() -> [String: Int] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: objectsURL.path) else { return [:] }
        var sizes: [String: Int] = [:]
        for name in names {
            sizes[name] = (try? fileManager.attributesOfItem(atPath: objectsURL.appendingPathComponent(name).path)[.size] as? Int) ?? 0
        }
        return sizes
    }

    private static func loadIndex(_ file: URL) -> [IDELocalHistoryEvent] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A half-written last line (a crash) is skipped.
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(IDELocalHistoryEvent.self, from: Data($0)) }
    }

    private func appendToIndex(_ event: IDELocalHistoryEvent) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(event) else { return }
        line.append(UInt8(ascii: "\n"))
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let handle = try? FileHandle(forWritingTo: indexURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: indexURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        }
    }

    private func rewriteIndex() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for event in events {
            guard var line = try? encoder.encode(event) else { continue }
            line.append(UInt8(ascii: "\n"))
            data.append(line)
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: indexURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }
}
