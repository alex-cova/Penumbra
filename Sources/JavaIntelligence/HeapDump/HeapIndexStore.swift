import Darwin
import Foundation

/// Where object indexes live and whether one is current: one folder per dump under `root`,
/// named from the dump's path, size, modification time and inode. An index is used only when it
/// is complete, of this format, and was built from the same file; anything else is deleted.
public struct HeapIndexStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func directory(for dump: URL) throws -> URL {
        let stamp = try HeapIndexMeta.DumpStamp(dump)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(stamp.path)|\(stamp.size)|\(stamp.modified)|\(stamp.inode)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        let name = dump.deletingPathExtension().lastPathComponent.prefix(40)
        return root.appendingPathComponent("\(name)-\(String(hash, radix: 16))", isDirectory: true)
    }

    /// The finished index of `dump`, or nil. A partial or stale folder for it is removed.
    public func openExisting(for dump: URL) -> HeapIndex? {
        guard let directory = try? directory(for: dump),
              FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let complete = directory.appendingPathComponent(HeapIndexBuilder.Files.complete)
        guard FileManager.default.fileExists(atPath: complete.path),
              let data = try? Data(contentsOf: directory.appendingPathComponent(HeapIndexBuilder.Files.meta)),
              let meta = try? JSONDecoder().decode(HeapIndexMeta.self, from: data),
              meta.formatVersion == HeapIndexBuilder.formatVersion,
              let stamp = try? HeapIndexMeta.DumpStamp(dump), meta.dump == stamp,
              let index = try? HeapIndex.open(directory: directory, dump: dump) else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        markUsed(directory)
        return index
    }

    // MARK: - Cleanup

    /// Default cap on all indexes together, before the least recently used go.
    public static let defaultMaximumBytes: Int64 = 30 << 30
    /// A folder without the `complete` marker this long untouched is a build that died.
    public static let abandonedBuildAge: TimeInterval = 6 * 3600
    static let lastUsedFile = "last-used"

    public struct SweepResult: Sendable, Equatable {
        public var removed: [URL] = []
        public var freedBytes: Int64 = 0
    }

    /// Removes what no dump can use again: indexes whose dump was deleted, moved or changed (the
    /// folder name follows the dump, so nothing would ever open them), indexes of another format,
    /// and builds that died. Then, while everything left is over `maximumBytes`, the least recently
    /// used index goes. `keeping` (the folders of open tabs) is never removed.
    @discardableResult
    public func sweep(maximumBytes: Int64 = defaultMaximumBytes, keeping: Set<URL> = [], now: Date = Date()) -> SweepResult {
        let fm = FileManager.default
        let keep = Set(keeping.map(\.standardizedFileURL.path))
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return SweepResult() }
        var result = SweepResult()
        var survivors: [(url: URL, bytes: Int64, lastUsed: Date)] = []
        func remove(_ url: URL, _ bytes: Int64) {
            guard (try? fm.removeItem(at: url)) != nil else { return }
            result.removed.append(url)
            result.freedBytes += bytes
        }
        for name in names {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  !keep.contains(folder.standardizedFileURL.path) else { continue }
            let bytes = Self.size(of: folder)
            let modified = Self.modificationDate(of: folder)
            guard fm.fileExists(atPath: folder.appendingPathComponent(HeapIndexBuilder.Files.complete).path) else {
                if now.timeIntervalSince(modified) > Self.abandonedBuildAge { remove(folder, bytes) }
                continue
            }
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(HeapIndexBuilder.Files.meta)),
                  let meta = try? JSONDecoder().decode(HeapIndexMeta.self, from: data),
                  meta.formatVersion == HeapIndexBuilder.formatVersion,
                  let stamp = try? HeapIndexMeta.DumpStamp(URL(fileURLWithPath: meta.dump.path)), stamp == meta.dump else {
                remove(folder, bytes)
                continue
            }
            let used = Self.modificationDate(of: folder.appendingPathComponent(Self.lastUsedFile))
            survivors.append((folder, bytes, max(used, meta.createdAt)))
        }
        var total = survivors.reduce(Int64(0)) { $0 + $1.bytes } + keeping.reduce(Int64(0)) { $0 + Self.size(of: $1) }
        for candidate in survivors.sorted(by: { $0.lastUsed < $1.lastUsed }) where total > maximumBytes {
            remove(candidate.url, candidate.bytes)
            total -= candidate.bytes
        }
        return result
    }

    /// Records that an index was opened, for the least-recently-used order.
    func markUsed(_ directory: URL) {
        try? Data().write(to: directory.appendingPathComponent(Self.lastUsedFile))
    }

    static func modificationDate(of url: URL) -> Date {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
    }

    public func build(
        dump: URL, layout: HeapObjectLayout,
        progress: @escaping @Sendable (HeapIndexBuilder.Progress) -> Void = { _ in }
    ) async throws -> HeapIndex {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = try await HeapIndexBuilder.build(dump: dump, into: try directory(for: dump), layout: layout, progress: progress)
        markUsed(index.directory)
        return index
    }

    public func delete(for dump: URL) {
        guard let directory = try? directory(for: dump) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Free space on the volume holding `url` (or its nearest existing parent).
    public static func availableBytes(at url: URL) -> Int64? {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate = candidate.deletingLastPathComponent()
        }
        let values = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Bytes of the files in `directory`.
    public static func size(of directory: URL) -> Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.reduce(Int64(0)) { total, name in
            var info = stat()
            guard stat(directory.appendingPathComponent(name).path, &info) == 0 else { return total }
            return total + Int64(info.st_blocks) * 512
        }
    }

    /// What a build of the dump `overview` describes needs at its peak.
    public static func estimatedPeakBytes(for overview: HeapDumpOverview) -> Int64 {
        HeapIndexBuilder.estimatedPeakBytes(objectCount: overview.objectCount, referenceSlots: overview.referenceSlots)
    }
}
