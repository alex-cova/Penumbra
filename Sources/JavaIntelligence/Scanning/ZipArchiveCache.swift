import Foundation

/// Archives that navigation reads one entry from, kept open between requests.
///
/// Opening a `ZipArchive` parses its whole central directory into a dictionary: about 4 ms for
/// the JDK's `src.zip` (some 30,000 entries), and ⌘-click and ⌘-hover each paid it again to read
/// one file. The file stays memory-mapped, so what is kept is the entry table.
///
/// A lookup compares the file's size and modification date with the ones the archive was opened
/// at and opens it again when they differ, so a rebuilt jar is never read through a stale table.
final class ZipArchiveCache: @unchecked Sendable {
    static let shared = ZipArchiveCache()

    private struct Stamp: Equatable {
        let size: Int64
        let seconds: Int
        let nanoseconds: Int
    }

    private struct Entry {
        let path: String
        let stamp: Stamp
        let archive: ZipArchive
    }

    private let lock = NSLock()
    /// Least recently used first.
    private var entries: [Entry] = []
    private let capacity: Int

    init(capacity: Int = 6) {
        self.capacity = capacity
    }

    var count: Int { lock.withLock { entries.count } }

    /// The archive at `url`, opened now only when it is not kept or the file changed.
    func archive(at url: URL) -> ZipArchive? {
        let path = url.standardizedFileURL.path
        guard let stamp = Self.stamp(of: path) else { return nil }
        if let cached = lock.withLock({ lookup(path: path, stamp: stamp) }) { return cached }
        guard let archive = try? ZipArchive(url: url) else { return nil }
        lock.withLock {
            entries.removeAll { $0.path == path }
            entries.append(Entry(path: path, stamp: stamp, archive: archive))
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        }
        return archive
    }

    func removeAll() {
        lock.withLock { entries.removeAll() }
    }

    private func lookup(path: String, stamp: Stamp) -> ZipArchive? {
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return nil }
        let entry = entries.remove(at: index)
        guard entry.stamp == stamp else { return nil }
        entries.append(entry)
        return entry.archive
    }

    private static func stamp(of path: String) -> Stamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Stamp(size: Int64(info.st_size), seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }
}
