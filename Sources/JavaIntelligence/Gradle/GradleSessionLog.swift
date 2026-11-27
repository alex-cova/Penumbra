import Foundation

/// A sequential byte log and a fixed-width, stream-tagged index. Readers open independent
/// descriptors and only access ranges committed to both files.
public final class GradleSessionLog: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public fileprivate(set) var bytes: UInt64 = 0
        public fileprivate(set) var records: UInt64 = 0
    }

    public struct WriteFailure: LocalizedError, Sendable {
        public let stream: GradleOutputLine.Stream
        public let directory: URL
        public let reason: String

        public var errorDescription: String? {
            "Gradle log is incomplete. Writing \(stream == .stdout ? "stdout" : "stderr") failed: \(reason)"
        }
    }

    public let directory: URL
    private let removeOnClose: Bool
    private let raw: FileHandle
    private let index: FileHandle
    private let writeLock = NSLock()
    private let snapshotLock = NSLock()
    private var committed = Snapshot()
    private static let pageSize: UInt64 = 64 * 1024
    private let pages: NSCache<NSNumber, NSData> = {
        let cache = NSCache<NSNumber, NSData>()
        cache.countLimit = 128
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    public init(directory: URL, removeOnClose: Bool = false) throws {
        self.directory = directory
        self.removeOnClose = removeOnClose
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let rawURL = directory.appendingPathComponent("console.raw")
        let indexURL = directory.appendingPathComponent("console.index")
        try Data().write(to: rawURL, options: .withoutOverwriting)
        try Data().write(to: indexURL, options: .withoutOverwriting)
        raw = try FileHandle(forWritingTo: rawURL)
        index = try FileHandle(forWritingTo: indexURL)
    }

    /// Reopens a finished or interrupted log at the last fully indexed byte.
    public init(reading directory: URL) throws {
        self.directory = directory
        removeOnClose = false
        raw = try FileHandle(forReadingFrom: directory.appendingPathComponent("console.raw"))
        index = try FileHandle(forReadingFrom: directory.appendingPathComponent("console.index"))
        let recordCount = try index.seekToEnd() / 17
        if recordCount > 0 {
            try index.seek(toOffset: (recordCount - 1) * 17 + 8)
            guard let bytes = try index.read(upToCount: 8), bytes.count == 8 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let end = bytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
            guard end <= (try raw.seekToEnd()) else { throw CocoaError(.fileReadCorruptFile) }
            committed = Snapshot(bytes: end, records: recordCount)
        }
    }

    deinit {
        try? raw.close()
        try? index.close()
        if removeOnClose { try? FileManager.default.removeItem(at: directory) }
    }

    public var snapshot: Snapshot { snapshotLock.withLock { committed } }

    public func append(_ data: Data, stream: GradleOutputLine.Stream) throws {
        guard !data.isEmpty else { return }
        try writeLock.withLock {
            do {
                let current = snapshot
                let end = current.bytes + UInt64(data.count)
                var record = Data()
                for value in [current.bytes, end] {
                    var littleEndian = value.littleEndian
                    withUnsafeBytes(of: &littleEndian) { record.append(contentsOf: $0) }
                }
                record.append(stream == .stdout ? 0 : 1)
                try raw.write(contentsOf: data)
                try index.write(contentsOf: record)
                snapshotLock.withLock {
                    committed = Snapshot(bytes: end, records: current.records + 1)
                }
            } catch {
                throw WriteFailure(stream: stream, directory: directory, reason: error.localizedDescription)
            }
        }
    }

    /// Returns a bounded window using an absolute byte offset and a binary search on disk.
    public func read(_ range: Range<UInt64>) throws -> [(GradleOutputLine.Stream, Data)] {
        let snapshot = snapshot
        let lower = min(range.lowerBound, snapshot.bytes)
        let upper = min(range.upperBound, snapshot.bytes)
        guard lower < upper else { return [] }
        guard upper - lower <= 256 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let payload = try FileHandle(forReadingFrom: directory.appendingPathComponent("console.raw"))
        let records = try FileHandle(forReadingFrom: directory.appendingPathComponent("console.index"))
        defer { try? payload.close(); try? records.close() }

        func record(at row: UInt64) throws -> (start: UInt64, end: UInt64, stream: GradleOutputLine.Stream) {
            try records.seek(toOffset: row * 17)
            guard let bytes = try records.read(upToCount: 17), bytes.count == 17 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return bytes.withUnsafeBytes {
                (UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self)),
                 UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)),
                 $0[16] == 0 ? .stdout : .stderr)
            }
        }

        var start = UInt64.zero
        var end = snapshot.records
        while start < end {
            let middle = start + (end - start) / 2
            if try record(at: middle).end <= lower { start = middle + 1 } else { end = middle }
        }
        let window = try rawWindow(lower..<upper, file: payload, committed: snapshot.bytes)
        var chunks: [(GradleOutputLine.Stream, Data)] = []
        for row in start..<snapshot.records {
            let item = try record(at: row)
            guard item.start < upper else { break }
            let start = Int(max(lower, item.start) - lower)
            let end = Int(min(upper, item.end) - lower)
            chunks.append((item.stream, window.subdata(in: start..<end)))
        }
        return chunks
    }

    private func rawWindow(_ range: Range<UInt64>, file: FileHandle, committed: UInt64) throws -> Data {
        var window = Data()
        window.reserveCapacity(Int(range.count))
        var position = range.lowerBound
        while position < range.upperBound {
            let start = position - (position % Self.pageSize)
            let key = NSNumber(value: start)
            let page: Data
            if let saved = pages.object(forKey: key) {
                page = saved as Data
            } else {
                try file.seek(toOffset: start)
                let size = Int(min(committed - start, Self.pageSize))
                guard let data = try file.read(upToCount: size), data.count == size else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if size == Self.pageSize { pages.setObject(data as NSData, forKey: key, cost: size) }
                page = data
            }
            let end = min(range.upperBound, start + UInt64(page.count))
            window.append(page[Int(position - start)..<Int(end - start)])
            position = end
        }
        return window
    }

    /// Searches a snapshot with overlap so matches can straddle read boundaries.
    public func find(_ text: String, from start: UInt64 = 0) throws -> Range<UInt64>? {
        let needle = Data(text.utf8)
        guard !needle.isEmpty, needle.count <= 4096 else { return nil }
        let end = snapshot.bytes
        let file = try FileHandle(forReadingFrom: directory.appendingPathComponent("console.raw"))
        defer { try? file.close() }
        var offset = min(start, end)
        var overlap = Data()
        try file.seek(toOffset: offset)
        while offset < end {
            try Task.checkCancellation()
            let match: Range<UInt64>? = try autoreleasepool {
                guard let data = try file.read(upToCount: Int(min(256 * 1024, end - offset))), !data.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let window = overlap + data
                if let match = window.range(of: needle) {
                    let base = offset - UInt64(overlap.count)
                    return (base + UInt64(match.lowerBound))..<(base + UInt64(match.upperBound))
                }
                overlap = Data(window.suffix(needle.count - 1))
                offset += UInt64(data.count)
                return nil
            }
            if let match { return match }
        }
        return nil
    }

    /// Exports the merged bytes exactly as recorded, without decoding or loading the file at once.
    public func export(to destination: URL) throws {
        let source = try FileHandle(forReadingFrom: directory.appendingPathComponent("console.raw"))
        defer { try? source.close() }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID()).gradle-export")
        defer { try? FileManager.default.removeItem(at: staging) }
        try Data().write(to: staging, options: .withoutOverwriting)
        let output = try FileHandle(forWritingTo: staging)
        defer { try? output.close() }
        var remaining = snapshot.bytes
        while remaining > 0 {
            try Task.checkCancellation()
            remaining -= try autoreleasepool {
                guard let data = try source.read(upToCount: Int(min(remaining, 256 * 1024))), !data.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try output.write(contentsOf: data)
                return UInt64(data.count)
            }
        }
        try output.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }
}
