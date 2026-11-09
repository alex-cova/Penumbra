import Foundation

/// The parses of unchanged text, kept by what they parsed: the same text is the same tree whoever
/// asks and whenever, so every feature that wants a tree of the buffer as it is now shares one
/// parse of it.
///
/// Two kinds of caller. Go to Definition: ⌘-hover runs a full definition request for every
/// identifier the pointer stops on, and a click right after is another, so without this each
/// paid to parse the whole current file and rebuild its stubs (about 3 ms per 1,000 lines), and
/// each cross-file jump parsed its destination again. And everything that runs once typing
/// pauses (semantic colours, gutter markers, breadcrumbs, auto-import, the role index's overlay,
/// hover, the bulb): each used to parse the buffer on its own, ten parses of one text per pause.
///
/// Concurrent requests for text that is being parsed wait for that parse instead of starting
/// another (the waiting thread is a thread that would have spent the same time parsing).
///
/// Trees handed out are shared and read-only: edit a ``JavaSyntaxTree/copy()``, never the tree
/// itself (`JavaCompletionProvider` does). Do not route bulk work through it (indexing thousands
/// of files would push out the buffer's tree): it is for the buffers the user is looking at.
///
/// Keyed by length and a 64-bit hash of the UTF-8 bytes, not by path or document version: a
/// navigation snapshot can lag the buffer, and a path says nothing about a file that changed.
final class JavaParseMemo: @unchecked Sendable {
    static let shared = JavaParseMemo()

    private struct Key: Hashable {
        let length: Int
        let hash: UInt64
    }

    private final class Entry {
        let key: Key
        let tree: JavaSyntaxTree
        let bytes: Int
        var stubsByPath: [String: JavaSourceFileStubs] = [:]

        init(key: Key, tree: JavaSyntaxTree, bytes: Int) {
            self.key = key
            self.tree = tree
            self.bytes = bytes
        }
    }

    private let lock = NSLock()
    /// Least recently used first.
    private var entries: [Entry] = []
    private var totalBytes = 0
    private var pendingParses: [Key: PendingParse] = [:]
    private var parses = 0
    /// What the memo did, for judging its capacity (`@_spi(Benchmarks)`): lookups that hit, parses made, entries
    /// pushed out, and the parses that were of text an eviction had pushed out a moment ago (the avoidable ones).
    private var hits = 0
    private var evictions = 0
    private var evictedKeys: Set<Key> = []
    private var evictedOrder: [Key] = []
    private var avoidableMisses = 0
    private var parseNanoseconds: UInt64 = 0
    private var avoidableNanoseconds: UInt64 = 0
    private var peakBytes = 0
    private var seenKeys: Set<Key> = []
    private let maximumEntries: Int
    private let maximumBytes: Int
    /// A source past this size is parsed but not kept: one very large file would push out everything else.
    private let maximumEntryBytes = 8 * 1024 * 1024

    init(maximumEntries: Int = 12, maximumBytes: Int = 24 * 1024 * 1024) {
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
    }

    var entryCount: Int { lock.withLock { entries.count } }

    /// The tree for `source`, parsed now only when no request has parsed this text recently.
    func tree(for source: String) -> JavaSyntaxTree? {
        entry(for: source, key: Self.key(of: source))?.tree
    }

    /// The tree for `source` and the stubs of its declarations as the file at `url`.
    func parsed(source: String, url: URL?) -> (tree: JavaSyntaxTree, stubs: JavaSourceFileStubs)? {
        guard let entry = entry(for: source, key: Self.key(of: source)) else { return nil }
        let path = url?.standardizedFileURL.path ?? ""
        if let stubs = lock.withLock({ entry.stubsByPath[path] }) { return (entry.tree, stubs) }
        let stubs = Self.stubs(of: entry.tree, url: url)
        lock.withLock { entry.stubsByPath[path] = stubs }
        return (entry.tree, stubs)
    }

    /// Parses made since the memo was created, for tests that hold a feature to one parse per text.
    var parseCount: Int { lock.withLock { parses } }

    /// The entry for `source`: kept from an earlier request, or the parse another thread is making
    /// right now (waited for), or a parse made here.
    private func entry(for source: String, key: Key) -> Entry? {
        lock.lock()
        if let cached = lookup(key) {
            hits += 1
            lock.unlock()
            return cached
        }
        if let pending = pendingParses[key] {
            lock.unlock()
            return pending.wait()
        }
        let pending = PendingParse()
        pendingParses[key] = pending
        parses += 1
        if seenKeys.count < 4_096 { seenKeys.insert(key) }
        let wasEvicted = evictedKeys.contains(key)
        if wasEvicted { avoidableMisses += 1 }
        lock.unlock()

        let parseStart = DispatchTime.now().uptimeNanoseconds
        let entry = JavaSyntaxParser().parse(source).map { Entry(key: key, tree: $0, bytes: source.utf8.count) }
        let parseTime = DispatchTime.now().uptimeNanoseconds &- parseStart
        lock.lock()
        parseNanoseconds &+= parseTime
        if wasEvicted { avoidableNanoseconds &+= parseTime }
        if let entry { insert(entry) }
        pendingParses[key] = nil
        lock.unlock()
        pending.finish(entry)
        return entry
    }

    /// A parse in progress, which other threads asking for the same text wait on.
    private final class PendingParse {
        private let condition = NSCondition()
        private var result: Entry?
        private var isFinished = false

        func wait() -> Entry? {
            condition.lock()
            defer { condition.unlock() }
            while !isFinished { condition.wait() }
            return result
        }

        func finish(_ entry: Entry?) {
            condition.lock()
            result = entry
            isFinished = true
            condition.broadcast()
            condition.unlock()
        }
    }

    func removeAll() {
        lock.withLock {
            entries.removeAll()
            totalBytes = 0
        }
    }

    // MARK: - Storage (the lock is held)

    private func lookup(_ key: Key) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry
    }

    private func insert(_ entry: Entry) {
        guard entry.bytes <= maximumEntryBytes else { return }
        if entries.contains(where: { $0.key == entry.key }) { return }
        entries.append(entry)
        totalBytes += entry.bytes
        // The newest entry stays even when it alone is over a cap.
        peakBytes = max(peakBytes, totalBytes)
        while entries.count > maximumEntries || totalBytes > maximumBytes, entries.count > 1 {
            let removed = entries.removeFirst()
            totalBytes -= removed.bytes
            evictions += 1
            if evictedKeys.insert(removed.key).inserted {
                evictedOrder.append(removed.key)
                if evictedOrder.count > 512 { evictedKeys.remove(evictedOrder.removeFirst()) }
            }
        }
    }

    struct Statistics: Sendable {
        var hits = 0, parses = 0, evictions = 0, avoidableParses = 0
        var parseSeconds = 0.0, avoidableSeconds = 0.0
        var entries = 0, bytes = 0, peakBytes = 0
        /// Different texts that had to be parsed (the working set of the workload, bounded at 4,096).
        var distinctTexts = 0
        var hitRate: Double { hits + parses == 0 ? 0 : Double(hits) / Double(hits + parses) }
    }

    var statistics: Statistics {
        lock.withLock {
            Statistics(
                hits: hits, parses: parses, evictions: evictions, avoidableParses: avoidableMisses,
                parseSeconds: Double(parseNanoseconds) / 1e9, avoidableSeconds: Double(avoidableNanoseconds) / 1e9,
                entries: entries.count, bytes: totalBytes, peakBytes: peakBytes, distinctTexts: seenKeys.count
            )
        }
    }

    func resetStatistics() {
        lock.withLock {
            hits = 0; parses = 0; evictions = 0; avoidableMisses = 0; parseNanoseconds = 0; avoidableNanoseconds = 0
            evictedKeys = []; evictedOrder = []; peakBytes = totalBytes; seenKeys = []
        }
    }

    // MARK: - Helpers

    private static func stubs(of tree: JavaSyntaxTree, url: URL?) -> JavaSourceFileStubs {
        JavaSourceStubBuilder.build(tree: tree, url: url ?? JavaNavigationSession.placeholderURL)
    }

    private static func key(of source: String) -> Key {
        var source = source
        let hash = source.withUTF8 { bytes -> UInt64 in
            let raw = UnsafeRawBufferPointer(bytes)
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            var index = 0
            while index + 8 <= raw.count {
                state = (state ^ raw.loadUnaligned(fromByteOffset: index, as: UInt64.self)) &* 0xFF51_AFD7_ED55_8CCD
                state ^= state >> 32
                index += 8
            }
            var tail: UInt64 = 0
            var shift: UInt64 = 0
            while index < raw.count {
                tail |= UInt64(raw[index]) << shift
                shift += 8
                index += 1
            }
            state = (state ^ tail) &* 0xC4CE_B9FE_1A85_EC53
            return state ^ (state >> 29)
        }
        return Key(length: source.utf8.count, hash: hash)
    }
}
