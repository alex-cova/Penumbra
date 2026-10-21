import Foundation

/// The parses Go to Definition asked for, kept by what they parsed: the same text is the same
/// tree whoever asks and whenever, so hovering over a word and then clicking it, hovering over the
/// next one, and clicking into a class that was just opened all find their parse already done.
///
/// ⌘-hover runs a full definition request for every identifier the pointer stops on, and a click
/// right after is another: without this each paid to parse the whole current file and rebuild its
/// stubs (about 3 ms per 1,000 lines), and each cross-file jump parsed its destination again.
///
/// Keyed by length and a 64-bit hash of the UTF-8 bytes, not by path or document version: a
/// navigation snapshot can lag the buffer, and a path says nothing about a file that changed.
final class JavaNavigationParseMemo: @unchecked Sendable {
    static let shared = JavaNavigationParseMemo()

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
        let key = Self.key(of: source)
        if let cached = lock.withLock({ lookup(key) }) { return cached.tree }
        guard let tree = JavaSyntaxParser().parse(source) else { return nil }
        lock.withLock { insert(Entry(key: key, tree: tree, bytes: source.utf8.count)) }
        return tree
    }

    /// The tree for `source` and the stubs of its declarations as the file at `url`.
    func parsed(source: String, url: URL?) -> (tree: JavaSyntaxTree, stubs: JavaSourceFileStubs)? {
        let key = Self.key(of: source)
        let path = url?.standardizedFileURL.path ?? ""
        if let cached = lock.withLock({ lookup(key) }) {
            if let stubs = lock.withLock({ cached.stubsByPath[path] }) { return (cached.tree, stubs) }
            let stubs = Self.stubs(of: cached.tree, url: url)
            lock.withLock { cached.stubsByPath[path] = stubs }
            return (cached.tree, stubs)
        }
        guard let tree = JavaSyntaxParser().parse(source) else { return nil }
        let stubs = Self.stubs(of: tree, url: url)
        let entry = Entry(key: key, tree: tree, bytes: source.utf8.count)
        entry.stubsByPath[path] = stubs
        lock.withLock { insert(entry) }
        return (tree, stubs)
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
        while entries.count > maximumEntries || totalBytes > maximumBytes, entries.count > 1 {
            totalBytes -= entries.removeFirst().bytes
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
