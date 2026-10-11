import Foundation

/// One span of a ``HexDocument`` piece table.
public struct HexPiece: Sendable, Equatable {
    public enum Origin: Sendable, Equatable {
        case original
        case added
    }

    public var origin: Origin
    public var offset: Int64
    public var length: Int64

    public init(origin: Origin, offset: Int64, length: Int64) {
        self.origin = origin
        self.offset = offset
        self.length = length
    }
}

/// Editable bytes over an original ``HexByteSource`` plus an append-only added buffer.
///
/// The value is copy-on-write. A snapshot shares the source and keeps its own pieces,
/// so a search or a save can run off the main actor without seeing later edits.
///
/// Compaction copies the logical bytes into the added buffer only when the piece count
/// is above 4,096 and the document is at most 32 MB. Larger files keep the piece list,
/// so a keystroke never reads the file into memory.
public struct HexDocument: Sendable {
    public static let compactionPieceLimit = 4_096
    public static let compactionSizeLimit: Int64 = 32 * 1024 * 1024

    final class Storage: @unchecked Sendable {
        var pieces: [HexPiece]
        var spans: [Int64]
        var total: Int64
        var added: ContiguousArray<UInt8>
        var original: any HexByteSource
        var undo = HexUndoStack()
        var identity: HexFileIdentity?

        init(original: any HexByteSource) {
            self.original = original
            self.pieces = []
            self.spans = []
            self.total = 0
            self.added = []
        }

        func copy() -> Storage {
            let copy = Storage(original: original)
            copy.pieces = pieces
            copy.spans = spans
            copy.total = total
            copy.added = added
            copy.undo = undo
            copy.identity = identity
            return copy
        }
    }

    var storage: Storage

    public init(source: any HexByteSource, identity: HexFileIdentity? = nil) {
        let storage = Storage(original: source)
        let count = max(0, source.count)
        if count > 0 {
            storage.pieces = [HexPiece(origin: .original, offset: 0, length: count)]
            storage.spans = [0]
            storage.total = count
        }
        storage.identity = identity
        self.storage = storage
    }

    public init(bytes: [UInt8]) {
        self.init(source: MemoryByteSource(bytes))
    }

    /// Bytes that are not the file on disk, already marked dirty, with an empty undo stack.
    public static func unsaved(_ bytes: [UInt8], changedBytes: Int64? = nil) -> HexDocument {
        let document = HexDocument(bytes: bytes)
        document.storage.undo.markAlreadyDirty(changedBytes: changedBytes ?? Int64(bytes.count))
        return document
    }

    public var count: Int64 { storage.total }
    public var isModified: Bool { storage.undo.isDirty }
    public var changedByteCount: Int64 { storage.undo.changedByteCount }
    public var canUndo: Bool { storage.undo.canUndo }
    public var canRedo: Bool { storage.undo.canRedo }
    public var pieceCount: Int { storage.pieces.count }
    public var identity: HexFileIdentity? { storage.identity }
    public var original: any HexByteSource { storage.original }

    /// A value the caller can hand to a background search or save.
    public func snapshot() -> HexDocument {
        HexDocument(storage: storage)
    }

    public func byte(at offset: Int64) -> UInt8? {
        guard offset >= 0, offset < storage.total else { return nil }
        var scratch = [UInt8](repeating: 0, count: 1)
        let n = scratch.withUnsafeMutableBytes { read(offset..<(offset + 1), into: $0) }
        return n == 1 ? scratch[0] : nil
    }

    @discardableResult
    public func read(_ range: Range<Int64>, into buffer: UnsafeMutableRawBufferPointer) -> Int {
        let available = HexByteRange.clampedCount(range, limit: storage.total, capacity: buffer.count)
        guard available > 0, let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        var copied = 0
        let start = range.lowerBound
        while copied < available {
            let absolute = start + Int64(copied)
            guard let index = pieceIndex(at: absolute) else { break }
            let piece = storage.pieces[index]
            let into = absolute - storage.spans[index]
            let take = min(Int(piece.length - into), available - copied)
            switch piece.origin {
            case .original:
                let file = (piece.offset + into)..<(piece.offset + into + Int64(take))
                let destination = UnsafeMutableRawBufferPointer(start: UnsafeMutableRawPointer(base.advanced(by: copied)), count: take)
                let filled = (try? storage.original.read(file, into: destination)) ?? 0
                if filled < take {
                    memset(base.advanced(by: copied + filled), 0, take - filled)
                }
            case .added:
                let addedStart = Int(piece.offset + into)
                storage.added.withUnsafeBytes { raw in
                    if let src = raw.baseAddress {
                        memcpy(base.advanced(by: copied), src.advanced(by: addedStart), take)
                    }
                }
            }
            copied += take
        }
        return copied
    }

    public func bytes(in range: Range<Int64>) -> [UInt8] {
        let available = HexByteRange.clampedCount(range, limit: storage.total, capacity: Int.max)
        guard available > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: available)
        let n = out.withUnsafeMutableBytes { read(range, into: $0) }
        if n < out.count { out.removeLast(out.count - n) }
        return out
    }

    /// Logical ranges whose bytes come from the added buffer.
    public func modifiedRanges() -> [Range<Int64>] {
        var ranges: [Range<Int64>] = []
        for (index, piece) in storage.pieces.enumerated() where piece.origin == .added && piece.length > 0 {
            let start = storage.spans[index]
            ranges.append(start..<(start + piece.length))
        }
        return ranges
    }

    public mutating func overwrite(
        at location: Int64,
        bytes: [UInt8],
        coalescable: Bool = false,
        now: ContinuousClock.Instant = .now
    ) {
        replace(at: location, removing: Int64(bytes.count), with: bytes, coalescable: coalescable, now: now)
    }

    public mutating func insert(
        at location: Int64,
        bytes: [UInt8],
        coalescable: Bool = false,
        now: ContinuousClock.Instant = .now
    ) {
        replace(at: location, removing: 0, with: bytes, coalescable: coalescable, now: now)
    }

    public mutating func delete(at location: Int64, count: Int64, now: ContinuousClock.Instant = .now) {
        replace(at: location, removing: count, with: [], now: now)
    }

    public mutating func fill(_ range: Range<Int64>, with byte: UInt8, now: ContinuousClock.Instant = .now) {
        let length = max(0, range.upperBound - range.lowerBound)
        guard length > 0 else { return }
        replace(at: range.lowerBound, removing: length, with: Array(repeating: byte, count: Int(length)), now: now)
    }

    public mutating func replace(
        at location: Int64,
        removing removeCount: Int64,
        with bytes: [UInt8],
        coalescable: Bool = false,
        now: ContinuousClock.Instant = .now
    ) {
        ensureUnique()
        let count = storage.total
        let start = min(max(0, location), count)
        let removing = min(max(0, removeCount), count - start)
        if removing == 0 && bytes.isEmpty { return }
        let previous = removing > 0 ? self.bytes(in: start..<(start + removing)) : []
        apply(at: start, removing: removing, with: bytes)
        storage.undo.record(
            location: start,
            removed: previous,
            inserted: bytes,
            coalescable: coalescable,
            now: now
        )
    }

    @discardableResult
    public mutating func undo() -> Bool {
        ensureUnique()
        guard let entry = storage.undo.popUndo() else { return false }
        apply(at: entry.location, removing: Int64(entry.inserted.count), with: entry.removed)
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        ensureUnique()
        guard let entry = storage.undo.popRedo() else { return false }
        apply(at: entry.location, removing: Int64(entry.removed.count), with: entry.inserted)
        return true
    }

    /// Forgets undo history and marks the buffer clean. Used after a successful save or a reload.
    public mutating func markSaved() {
        noteSaved(identity: storage.identity)
    }

    /// Marks the buffer clean and remembers the file identity a later save must match.
    public mutating func noteSaved(identity: HexFileIdentity?) {
        ensureUnique()
        storage.undo.clear()
        storage.identity = identity
    }

    /// Remembers a file identity without clearing unsaved edits.
    public mutating func noteFileIdentity(_ identity: HexFileIdentity?) {
        ensureUnique()
        storage.identity = identity
    }

    public func sharesStorage(with other: HexDocument) -> Bool {
        storage === other.storage
    }

    /// True when every undo step in `baseline` is still the prefix of this document's log.
    ///
    /// A dropped oldest step, an undo, or a coalesced rewrite of the last step makes this false.
    /// Those logs cannot be replayed onto the flattened file.
    public func undoLogExtends(_ baseline: HexDocument) -> Bool {
        let base = baseline.storage.undo.undo
        let live = storage.undo.undo
        guard live.count >= base.count else { return false }
        return zip(base, live).allSatisfy(==)
    }

    /// Bytes of `source` are the flattened `baseline`. When this document only appended undo
    /// steps after that snapshot, those steps are replayed on `source`.
    ///
    /// When the baseline log is not a prefix, this returns the live piece table unchanged.
    /// The caller must not have reopened the pre-rename descriptor: piece offsets still address that inode.
    public func rebased(onto source: any HexByteSource, identity: HexFileIdentity?, baseline: HexDocument) -> HexDocument {
        if storage === baseline.storage {
            return HexDocument(source: source, identity: identity)
        }
        guard undoLogExtends(baseline) else { return self }
        var result = HexDocument(source: source, identity: identity)
        let recorded = baseline.storage.undo.undo.count
        for entry in storage.undo.undo[recorded...] {
            result.replace(at: entry.location, removing: Int64(entry.removed.count), with: entry.inserted)
        }
        return result
    }

    private init(storage: Storage) {
        self.storage = storage
    }

    private mutating func ensureUnique() {
        if !isKnownUniquelyReferenced(&storage) {
            storage = storage.copy()
        }
    }

    private func pieceIndex(at offset: Int64) -> Int? {
        let spans = storage.spans
        guard !spans.isEmpty, offset >= 0, offset < storage.total else { return nil }
        var low = 0
        var high = spans.count
        while low + 1 < high {
            let mid = (low + high) / 2
            if spans[mid] <= offset { low = mid } else { high = mid }
        }
        return low
    }

    private mutating func apply(at location: Int64, removing: Int64, with bytes: [UInt8]) {
        let end = location + removing
        var rebuilt: [HexPiece] = []
        rebuilt.reserveCapacity(storage.pieces.count + 1)
        var cursor: Int64 = 0
        var didInsert = false
        let addedStart = Int64(storage.added.count)
        if !bytes.isEmpty {
            storage.added.append(contentsOf: bytes)
        }

        func insertNew() {
            guard !didInsert else { return }
            didInsert = true
            if !bytes.isEmpty {
                rebuilt.append(HexPiece(origin: .added, offset: addedStart, length: Int64(bytes.count)))
            }
        }

        if storage.pieces.isEmpty {
            insertNew()
            commit(rebuilt)
            return
        }

        for piece in storage.pieces {
            let pieceStart = cursor
            let pieceEnd = cursor + piece.length
            if pieceEnd <= location {
                rebuilt.append(piece)
                if pieceEnd == location { insertNew() }
                cursor = pieceEnd
                continue
            }
            if pieceStart >= end {
                if !didInsert { insertNew() }
                rebuilt.append(piece)
                cursor = pieceEnd
                continue
            }
            if pieceStart < location {
                var prefix = piece
                prefix.length = location - pieceStart
                if prefix.length > 0 { rebuilt.append(prefix) }
            }
            insertNew()
            if pieceEnd > end {
                var suffix = piece
                let cut = end - pieceStart
                suffix.offset += cut
                suffix.length -= cut
                if suffix.length > 0 { rebuilt.append(suffix) }
            }
            cursor = pieceEnd
        }
        if !didInsert { insertNew() }
        commit(merge(rebuilt))
    }

    private mutating func commit(_ pieces: [HexPiece]) {
        storage.pieces = pieces
        var spans: [Int64] = []
        spans.reserveCapacity(pieces.count)
        var total: Int64 = 0
        for piece in pieces {
            spans.append(total)
            total += piece.length
        }
        storage.spans = spans
        storage.total = total
        compactIfNeeded()
    }

    private func merge(_ pieces: [HexPiece]) -> [HexPiece] {
        var result: [HexPiece] = []
        result.reserveCapacity(pieces.count)
        for piece in pieces where piece.length > 0 {
            if var last = result.last, last.origin == piece.origin, last.offset + last.length == piece.offset {
                last.length += piece.length
                result[result.count - 1] = last
            } else {
                result.append(piece)
            }
        }
        return result
    }

    private mutating func compactIfNeeded() {
        guard storage.pieces.count > Self.compactionPieceLimit, storage.total <= Self.compactionSizeLimit, storage.total > 0 else {
            return
        }
        let count = Int(storage.total)
        var flat = [UInt8](repeating: 0, count: count)
        let n = flat.withUnsafeMutableBytes { read(0..<storage.total, into: $0) }
        flat.removeLast(max(0, count - n))
        storage.added = ContiguousArray(flat)
        storage.pieces = [HexPiece(origin: .added, offset: 0, length: Int64(flat.count))]
        storage.spans = [0]
        storage.total = Int64(flat.count)
    }
}
