import Foundation

public enum ResultStoreError: Error, Equatable, LocalizedError, Sendable {
    case closed
    case outOfRange(Int)
    case spillFailed(String)

    public var errorDescription: String? {
        switch self {
        case .closed: "The result was closed."
        case .outOfRange(let row): "Row \(row) is not in this result."
        case .spillFailed(let message): "Could not store the result on disk: \(message)"
        }
    }
}

/// The rows of one query result, held under a memory ceiling.
///
/// Rows arrive in order and are grouped into chunks of `chunkRowCount`. When the chunks in memory
/// exceed `memoryLimitBytes`, the oldest are written to a private temporary file (mode 0600) and
/// dropped from memory; a read of a spilled chunk loads it back. The file is removed when the
/// store is closed or released. Nothing else keeps rows: the grid, charts and export ask the
/// store for ranges.
///
/// This is bounded memory, not a lazy server cursor: whether rows are *pulled* on demand depends on
/// the engine (see ARCHITECTURE.md). The store makes the bound true either way.
public actor ResultStore {
    public static let chunkRowCount = 1024
    public static let defaultMemoryLimitBytes = 64 * 1024 * 1024

    /// Known when the server describes the result, which can be after the store exists.
    public private(set) var columns: [ResultColumn]
    /// Rows beyond this are refused and `limitReached` becomes true.
    public let rowLimit: Int?

    public private(set) var rowCount = 0
    public private(set) var isFinished = false
    public private(set) var limitReached = false

    public struct Snapshot: Equatable, Sendable {
        public let columns: [ResultColumn]
        public let rowCount: Int
    }

    public var snapshot: Snapshot { Snapshot(columns: columns, rowCount: rowCount) }

    private let memoryLimitBytes: Int
    private let chunkLimitBytes: Int
    private var chunks: [Chunk] = []
    private var tail: [[DatabaseValue]] = []
    private var tailBytes = 0
    private var residentChunkBytes = 0
    /// Chunk indices that are in memory, least recently used first.
    private var residentOrder: [Int] = []
    private var spill: SpillFile?
    private var isClosed = false

    private struct Chunk {
        var rows: [[DatabaseValue]]?
        var diskOffset: UInt64?
        var diskLength: Int = 0
        let firstRow: Int
        var bytes: Int
    }

    public struct Stats: Equatable, Sendable {
        public var rowCount: Int
        public var chunkCount: Int
        public var residentBytes: Int
        public var spilledBytes: Int
        public var spillFileExists: Bool
        /// Where the spill file is, if one was created. For diagnostics and tests.
        public var spillFilePath: String?
    }

    public init(
        columns: [ResultColumn],
        memoryLimitBytes: Int = ResultStore.defaultMemoryLimitBytes,
        rowLimit: Int? = nil
    ) {
        self.columns = columns
        self.memoryLimitBytes = max(0, memoryLimitBytes)
        self.chunkLimitBytes = min(8 * 1024 * 1024, max(64 * 1024, memoryLimitBytes / 4))
        self.rowLimit = rowLimit
    }

    public var stats: Stats {
        Stats(
            rowCount: rowCount,
            chunkCount: chunks.count + (tail.isEmpty ? 0 : 1),
            residentBytes: residentChunkBytes + tailBytes,
            spilledBytes: Int(spill?.length ?? 0),
            spillFileExists: spill.map { FileManager.default.fileExists(atPath: $0.url.path) } ?? false,
            spillFilePath: spill?.url.path
        )
    }

    /// Appends rows. Returns `false` when the store wants no more (the row limit is reached or it
    /// is finished or closed), which is the producer's signal to stop pulling from the server.
    @discardableResult
    public func append(_ rows: [[DatabaseValue]]) throws -> Bool {
        guard !isClosed else { throw ResultStoreError.closed }
        guard !isFinished, !limitReached else { return false }
        for row in rows {
            if let rowLimit, rowCount >= rowLimit {
                limitReached = true
                return false
            }
            let bytes = row.reduce(24) { $0 + $1.estimatedBytes }
            if !tail.isEmpty, tailBytes + bytes > chunkLimitBytes { try sealTail() }
            tail.append(row)
            tailBytes += bytes
            rowCount += 1
            if tail.count == Self.chunkRowCount || tailBytes >= chunkLimitBytes {
                try sealTail()
            }
        }
        if let rowLimit, rowCount >= rowLimit {
            limitReached = true
            return false
        }
        return true
    }

    public func setColumns(_ columns: [ResultColumn]) {
        self.columns = columns
    }

    /// Marks the result complete. Reads stay valid until `close()`.
    public func finish() {
        isFinished = true
    }

    public func row(at index: Int) throws -> [DatabaseValue] {
        guard let row = try rows(in: index..<(index + 1)).first else {
            throw ResultStoreError.outOfRange(index)
        }
        return row
    }

    /// The rows in `range`, clamped to what the store holds so far.
    public func rows(in range: Range<Int>) throws -> [[DatabaseValue]] {
        try mapRows(in: range) { $0 }
    }

    /// Projects a range one chunk at a time, so callers can retain lightweight display cells.
    public func mapRows<T: Sendable>(
        in range: Range<Int>, _ transform: @Sendable ([DatabaseValue]) -> T
    ) throws -> [T] {
        guard !isClosed else { throw ResultStoreError.closed }
        let lower = max(0, range.lowerBound)
        let upper = min(rowCount, range.upperBound)
        guard lower < upper else { return [] }
        var result: [T] = []
        result.reserveCapacity(upper - lower)
        var position = lower
        var chunkIndex = chunk(containing: lower)
        while position < upper {
            if chunkIndex < chunks.count {
                let rows = try load(chunkIndex)
                let offsetInChunk = position - chunks[chunkIndex].firstRow
                let end = min(rows.count, offsetInChunk + (upper - position))
                result.append(contentsOf: rows[offsetInChunk..<end].lazy.map(transform))
                position += end - offsetInChunk
                chunkIndex += 1
            } else {
                let offsetInChunk = position - (rowCount - tail.count)
                let end = min(tail.count, offsetInChunk + (upper - position))
                result.append(contentsOf: tail[offsetInChunk..<end].lazy.map(transform))
                position += end - offsetInChunk
            }
        }
        return result
    }

    /// Releases memory and deletes the spill file. Every later read throws `.closed`.
    public func close() {
        isClosed = true
        chunks = []
        tail = []
        tailBytes = 0
        residentChunkBytes = 0
        residentOrder = []
        spill = nil  // SpillFile.deinit removes the file
    }

    // MARK: - Chunks

    private func chunk(containing row: Int) -> Int {
        if row >= rowCount - tail.count { return chunks.count }
        var lower = 0
        var upper = chunks.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if chunks[middle].firstRow <= row { lower = middle + 1 } else { upper = middle }
        }
        return lower - 1
    }

    private func sealTail() throws {
        let chunk = Chunk(rows: tail, firstRow: rowCount - tail.count, bytes: tailBytes)
        chunks.append(chunk)
        let index = chunks.count - 1
        residentOrder.append(index)
        residentChunkBytes += tailBytes
        tail = []
        tailBytes = 0
        try enforceLimit(protecting: index)
    }

    private func load(_ index: Int) throws -> [[DatabaseValue]] {
        if let rows = chunks[index].rows {
            if let position = residentOrder.firstIndex(of: index), position != residentOrder.count - 1 {
                residentOrder.remove(at: position)
                residentOrder.append(index)
            }
            return rows
        }
        guard let offset = chunks[index].diskOffset, let spill else {
            throw ResultStoreError.spillFailed("chunk \(index) has no stored copy")
        }
        let data = try spill.read(offset: offset, length: chunks[index].diskLength)
        let rows: [[DatabaseValue]]
        do {
            rows = try Self.decoder.decode([[DatabaseValue]].self, from: data)
        } catch {
            throw ResultStoreError.spillFailed("\(error)")
        }
        chunks[index].rows = rows
        residentChunkBytes += chunks[index].bytes
        residentOrder.append(index)
        try enforceLimit(protecting: index)
        return rows
    }

    private func enforceLimit(protecting protected: Int) throws {
        while residentChunkBytes + tailBytes > memoryLimitBytes {
            guard let victim = residentOrder.first(where: { $0 != protected }) else { return }
            try evict(victim)
        }
    }

    private func evict(_ index: Int) throws {
        if chunks[index].diskOffset == nil {
            guard let rows = chunks[index].rows else { return }
            let data: Data
            do {
                data = try Self.encoder.encode(rows)
            } catch {
                throw ResultStoreError.spillFailed("\(error)")
            }
            if spill == nil { spill = try SpillFile() }
            chunks[index].diskOffset = try spill!.append(data)
            chunks[index].diskLength = data.count
        }
        chunks[index].rows = nil
        residentChunkBytes -= chunks[index].bytes
        residentOrder.removeAll { $0 == index }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        return decoder
    }()
}

/// A private temporary file. Created exclusively with mode 0600, removed on deinit. Only the
/// owning `ResultStore` touches it, from its own isolation, so it needs no locking.
private final class SpillFile {
    let url: URL
    private let handle: FileHandle
    private(set) var length: UInt64 = 0

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "umbra-results", isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ResultStoreError.spillFailed("\(error)")
        }
        url = directory.appendingPathComponent(UUID().uuidString + ".spill")
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw ResultStoreError.spillFailed(String(cString: strerror(errno)))
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    func append(_ data: Data) throws -> UInt64 {
        let offset = length
        do {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
        } catch {
            throw ResultStoreError.spillFailed("\(error)")
        }
        length += UInt64(data.count)
        return offset
    }

    func read(offset: UInt64, length: Int) throws -> Data {
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: length), data.count == length else {
                throw ResultStoreError.spillFailed("short read")
            }
            return data
        } catch let error as ResultStoreError {
            throw error
        } catch {
            throw ResultStoreError.spillFailed("\(error)")
        }
    }
}
