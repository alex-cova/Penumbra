import Foundation

struct PieceNodeID: RedBlackTreeNodeID {
    let id = UUID()
}

final class PieceNodeData {
    var piece: PieceTree.Piece
    var nodeTotalLineFeedCount: Int

    init(_ piece: PieceTree.Piece) {
        self.piece = piece
        self.nodeTotalLineFeedCount = piece.lineFeedCount
    }
}

final class PieceChildrenUpdater: RedBlackTreeChildrenUpdater<PieceNodeID, Int, PieceNodeData> {
    override func updateAfterChangingChildren(of node: Node) -> Bool {
        var lineFeeds = node.data.piece.lineFeedCount
        if let left = node.left {
            lineFeeds += left.data.nodeTotalLineFeedCount
        }
        if let right = node.right {
            lineFeeds += right.data.nodeTotalLineFeedCount
        }
        if lineFeeds != node.data.nodeTotalLineFeedCount {
            node.data.nodeTotalLineFeedCount = lineFeeds
            return true
        }
        return false
    }
}

typealias PieceNode = RedBlackTreeNode<PieceNodeID, Int, PieceNodeData>
typealias PieceNodeTree = RedBlackTree<PieceNodeID, Int, PieceNodeData>

/// Immutable copy of piece-tree buffers for EIP ranged reads off the editor thread.
struct PieceTreeContentSnapshot: Sendable, FindTextSource {
    struct PieceCopy: Sendable {
        var sourceIsOriginal: Bool
        var utf8Offset: Int
        var utf8Length: Int
        var utf16Length: Int
        var originalUTF16Start: Int
    }

    let original: FileMapping?
    let addBuffer: Data
    let pieces: [PieceCopy]
    let originalCheckpoints: [UTF8DocumentScanner.Checkpoint]
    let utf16Length: Int
    let utf8Length: Int

    var contiguousNSString: NSString? { nil }

    func substring(utf16Offset: Int, length: Int) -> String {
        let location = max(0, utf16Offset)
        let take = max(0, min(length, utf16Length - location))
        guard take > 0 else {
            return ""
        }
        let units = utf16Units(in: NSRange(location: location, length: take))
        return String(utf16CodeUnits: units, count: units.count)
    }

    func prefetch(utf16Range: NSRange) {
        guard let original else {
            return
        }
        let location = max(0, utf16Range.location)
        let length = min(max(utf16Range.length, 0), max(0, utf16Length - location))
        guard length > 0 else {
            return
        }
        var remainingCap = PieceTree.prefetchByteCap
        var cursor = location
        let end = location + length
        var utf16 = 0
        for piece in pieces {
            if remainingCap <= 0 || cursor >= end {
                break
            }
            let pieceEnd = utf16 + piece.utf16Length
            if piece.sourceIsOriginal, cursor < pieceEnd, end > utf16 {
                let local = max(cursor, utf16) - utf16
                let take = min(end, pieceEnd) - (utf16 + local)
                if take > 0 {
                    withUTF8(of: piece) { bytes in
                        let utf8Start = piece.utf8Offset + utf8Offset(in: piece, localUTF16: local, bytes: bytes)
                        let utf8End = piece.utf8Offset + utf8EndOffset(in: piece, localUTF16: local + take, bytes: bytes)
                        let count = min(max(utf8End - utf8Start, 0), remainingCap)
                        if count > 0 {
                            original.prefetch(byteOffset: utf8Start, count: count)
                            remainingCap -= count
                        }
                    }
                    cursor += take
                }
            } else if cursor < pieceEnd {
                cursor = pieceEnd
            }
            utf16 = pieceEnd
        }
    }

    private func utf16Units(in range: NSRange) -> [unichar] {
        var result: [unichar] = []
        result.reserveCapacity(max(range.length, 0))
        var remaining = range.length
        var location = range.location
        var utf16 = 0
        for piece in pieces {
            let pieceEnd = utf16 + piece.utf16Length
            if location < pieceEnd && remaining > 0 {
                let local = location - utf16
                let take = min(remaining, piece.utf16Length - local)
                withUTF8(of: piece) { bytes in
                    appendUTF16Units(of: piece, localUTF16: local, take: take, bytes: bytes, into: &result)
                }
                remaining -= take
                location += take
            }
            utf16 = pieceEnd
            if remaining <= 0 {
                break
            }
        }
        return result
    }

    private func appendUTF16Units(
        of piece: PieceCopy,
        localUTF16: Int,
        take: Int,
        bytes: UnsafeRawBufferPointer,
        into result: inout [unichar]
    ) {
        if !piece.sourceIsOriginal || originalCheckpoints.isEmpty {
            UTF8DocumentScanner.appendUTF16Units(from: bytes, utf16Offset: localUTF16, length: take, into: &result)
            return
        }
        let targetUTF16 = piece.originalUTF16Start + localUTF16
        var startUTF8 = piece.utf8Offset
        var baseUTF16 = piece.originalUTF16Start
        if let checkpoint = lastCheckpoint(utf16Offset: targetUTF16),
           checkpoint.utf8Offset >= piece.utf8Offset,
           checkpoint.utf16Offset <= targetUTF16 {
            startUTF8 = checkpoint.utf8Offset
            baseUTF16 = checkpoint.utf16Offset
        }
        let limit = piece.utf8Offset + piece.utf8Length
        let extraBytes = UnsafeRawBufferPointer(
            start: bytes.baseAddress.map { $0 + (startUTF8 - piece.utf8Offset) },
            count: max(limit - startUTF8, 0)
        )
        UTF8DocumentScanner.appendUTF16Units(
            from: extraBytes,
            utf16Offset: targetUTF16 - baseUTF16,
            length: take,
            into: &result
        )
    }

    private func utf8Offset(in piece: PieceCopy, localUTF16: Int, bytes: UnsafeRawBufferPointer) -> Int {
        resolveUTF8Offset(in: piece, localUTF16: localUTF16, bytes: bytes, end: false)
    }

    private func utf8EndOffset(in piece: PieceCopy, localUTF16: Int, bytes: UnsafeRawBufferPointer) -> Int {
        resolveUTF8Offset(in: piece, localUTF16: localUTF16, bytes: bytes, end: true)
    }

    private func resolveUTF8Offset(
        in piece: PieceCopy,
        localUTF16: Int,
        bytes: UnsafeRawBufferPointer,
        end: Bool
    ) -> Int {
        if localUTF16 <= 0 {
            return 0
        }
        if localUTF16 >= piece.utf16Length {
            return piece.utf8Length
        }
        if !piece.sourceIsOriginal || originalCheckpoints.isEmpty {
            if end {
                return UTF8DocumentScanner.utf8EndOffset(forUTF16Offset: localUTF16, in: bytes)
            }
            return UTF8DocumentScanner.utf8Offset(forUTF16Offset: localUTF16, in: bytes)
        }
        let targetUTF16 = piece.originalUTF16Start + localUTF16
        var startUTF8 = piece.utf8Offset
        var utf16 = piece.originalUTF16Start
        if let checkpoint = lastCheckpoint(utf16Offset: targetUTF16),
           checkpoint.utf8Offset >= piece.utf8Offset,
           checkpoint.utf16Offset <= targetUTF16 {
            startUTF8 = checkpoint.utf8Offset
            utf16 = checkpoint.utf16Offset
        }
        let limit = piece.utf8Offset + piece.utf8Length
        let extraBytes = UnsafeRawBufferPointer(
            start: bytes.baseAddress.map { $0 + (startUTF8 - piece.utf8Offset) },
            count: max(limit - startUTF8, 0)
        )
        let relative = targetUTF16 - utf16
        let extra = end
            ? UTF8DocumentScanner.utf8EndOffset(forUTF16Offset: relative, in: extraBytes)
            : UTF8DocumentScanner.utf8Offset(forUTF16Offset: relative, in: extraBytes)
        return (startUTF8 + extra) - piece.utf8Offset
    }

    private func lastCheckpoint(utf16Offset: Int) -> UTF8DocumentScanner.Checkpoint? {
        guard !originalCheckpoints.isEmpty else {
            return nil
        }
        var low = 0
        var high = originalCheckpoints.count
        while low < high {
            let mid = (low + high) / 2
            if originalCheckpoints[mid].utf16Offset <= utf16Offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let index = low - 1
        guard index >= 0 else {
            return originalCheckpoints.first
        }
        return originalCheckpoints[index]
    }

    func withUTF8<T>(of piece: PieceCopy, _ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        if piece.sourceIsOriginal {
            guard let original, let base = original.baseAddress else {
                return try body(UnsafeRawBufferPointer(start: nil, count: 0))
            }
            return try body(UnsafeRawBufferPointer(start: base + piece.utf8Offset, count: piece.utf8Length))
        }
        return try addBuffer.withUnsafeBytes { raw in
            let start = raw.baseAddress.map { $0 + piece.utf8Offset }
            return try body(UnsafeRawBufferPointer(start: start, count: piece.utf8Length))
        }
    }
}

/// VS Code-style piece tree: read-only original UTF-8 mapping + append-only add buffer.
///
/// Pieces live in an order-statistics red-black tree keyed by UTF-16 length. Sequential
/// typing at one caret extends the last add-buffer piece without splitting.
final class PieceTree {
    enum Source: Sendable {
        case original
        case add
    }

    struct Piece {
        var source: Source
        var utf8Offset: Int
        var utf8Length: Int
        var utf16Length: Int
        /// UTF-16 offset of this piece's first unit in the original mapping. 0 for add-buffer pieces.
        var originalUTF16Start: Int
        var lineFeedCount: Int
    }

    static let prefetchByteCap = 256 * 1024

    private var original: FileMapping?
    private var addBuffer = Data()
    private let tree: PieceNodeTree
    private var originalCheckpoints: [UTF8DocumentScanner.Checkpoint]
    private(set) var utf16Length = 0
    private var cachedNode: PieceNode?
    private var cachedPieceUTF16Start = 0
    /// Resume point for the last forward `.add`-buffer UTF-16→UTF-8 offset resolution — see
    /// ``addBufferUTF8Offset(in:localUTF16:bytes:)``.
    private var addBufferOffsetCursor: (pieceUTF8Offset: Int, localUTF16: Int, utf8Offset: Int)?
    private(set) var materializeCount = 0
    var addBufferByteCount: Int {
        addBuffer.count
    }

    var isEmpty: Bool {
        utf16Length == 0
    }

    var byteCount: ByteCount {
        ByteCount(utf16Length: utf16Length)
    }

    var pieceCount: Int {
        utf16Length == 0 ? 0 : tree.root.nodeTotalCount
    }

    var lastPrefetchByteCount: Int {
        original?.lastPrefetchByteCount ?? 0
    }

    var isFileMapped: Bool {
        original != nil
    }

    init() {
        original = nil
        originalCheckpoints = []
        let empty = Piece(
            source: .add,
            utf8Offset: 0,
            utf8Length: 0,
            utf16Length: 0,
            originalUTF16Start: 0,
            lineFeedCount: 0
        )
        tree = PieceNodeTree(minimumValue: 0, rootValue: 0, rootData: PieceNodeData(empty))
        tree.childrenUpdater = PieceChildrenUpdater()
    }

    /// In-memory document: all text lives in the add buffer (no file mapping).
    convenience init(string: String) {
        self.init()
        if !string.isEmpty {
            replaceText(in: NSRange(location: 0, length: 0), with: string)
        }
    }

    /// One original piece covering `mapping` after an optional UTF-8 BOM.
    init(mapping: FileMapping, scan: UTF8DocumentScanner.Scan? = nil) {
        self.original = mapping
        let raw = mapping.bytes()
        let stripped = UTF8DocumentScanner.stripBOM(from: raw)
        let bomBytes = raw.count - stripped.count
        let resolved = scan ?? UTF8DocumentScanner.scan(stripped)
        originalCheckpoints = resolved.checkpoints.map { checkpoint in
            UTF8DocumentScanner.Checkpoint(
                utf8Offset: checkpoint.utf8Offset + bomBytes,
                utf16Offset: checkpoint.utf16Offset,
                lineCount: checkpoint.lineCount
            )
        }
        let empty = Piece(
            source: .add,
            utf8Offset: 0,
            utf8Length: 0,
            utf16Length: 0,
            originalUTF16Start: 0,
            lineFeedCount: 0
        )
        tree = PieceNodeTree(minimumValue: 0, rootValue: 0, rootData: PieceNodeData(empty))
        tree.childrenUpdater = PieceChildrenUpdater()
        if stripped.count > 0 {
            let piece = Piece(
                source: .original,
                utf8Offset: bomBytes,
                utf8Length: stripped.count,
                utf16Length: resolved.utf16Length,
                originalUTF16Start: 0,
                lineFeedCount: resolved.lineFeedCount
            )
            replaceRoot(with: piece)
        }
        utf16Length = resolved.utf16Length
    }

    func lineMetrics() -> [LineMetric] {
        guard let original else {
            return [LineMetric(totalLength: 0, delimiterLength: 0)]
        }
        let stripped = UTF8DocumentScanner.stripBOM(from: original.bytes())
        return UTF8DocumentScanner.lineMetrics(in: stripped)
    }

    func replaceText(in range: NSRange, with string: String) {
        let location = max(0, range.location)
        let length = max(0, min(range.length, max(0, utf16Length - location)))
        deleteUTF16(location: location, length: length)
        if !string.isEmpty {
            insert(string, atUTF16: location)
        }
    }

    func substring(in range: NSRange) -> String? {
        guard range.location >= 0, range.upperBound <= utf16Length else {
            return nil
        }
        if range.length == 0 {
            return ""
        }
        let units = utf16Units(in: range)
        return String(utf16CodeUnits: units, count: units.count)
    }

    func character(at location: Int) -> Character? {
        guard location >= 0, location < utf16Length else {
            return nil
        }
        if let scalar = Unicode.Scalar(utf16Unit(at: location)) {
            return Character(scalar)
        }
        return nil
    }

    func unichar(at location: Int) -> unichar? {
        guard location >= 0, location < utf16Length else {
            return nil
        }
        return utf16Unit(at: location)
    }

    func bytes(in range: ByteRange) -> StringViewBytesResult? {
        guard range.lowerBound.value >= 0, range.upperBound <= byteCount else {
            return nil
        }
        let utf16Range = NSRange(location: range.location.utf16Length, length: range.length.utf16Length)
        let units = utf16Units(in: utf16Range)
        let byteLength = units.count * 2
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: max(byteLength, 1))
        if byteLength > 0 {
            units.withUnsafeBytes { raw in
                buffer.update(from: raw.bindMemory(to: Int8.self).baseAddress!, count: byteLength)
            }
        }
        return StringViewBytesResult(bytes: UnsafePointer(buffer), length: ByteCount(byteLength))
    }

    func rangeOfNextNewLine(startingAt location: Int) -> NSRange? {
        var index = max(0, location)
        var pendingCR = false
        while index < utf16Length {
            guard let node = nodeContaining(index) else {
                break
            }
            let piece = node.data.piece
            let pieceStart = cachedPieceUTF16Start
            if !pendingCR, piece.lineFeedCount == 0 {
                index = pieceStart + piece.utf16Length
                continue
            }
            let unit = utf16Unit(at: index)
            if pendingCR {
                if unit == 0x000A {
                    return NSRange(location: index - 1, length: 2)
                }
                return NSRange(location: index - 1, length: 1)
            }
            if unit == 0x000A || unit == 0x0085 || unit == 0x2028 || unit == 0x2029 {
                return NSRange(location: index, length: 1)
            }
            if unit == 0x000D {
                pendingCR = true
            }
            index += 1
        }
        if pendingCR {
            return NSRange(location: utf16Length - 1, length: 1)
        }
        return nil
    }

    func paragraphStart(before location: Int) -> Int {
        if location <= 0 {
            return 0
        }
        if let unit = unichar(at: location - 1), Self.isNewlineUTF16(unit) {
            return location
        }
        let searchLength = location - 1
        guard searchLength > 0 else {
            return 0
        }
        let found = rangeOfCharacter(
            from: .newlines,
            options: .backwards,
            range: NSRange(location: 0, length: searchLength)
        )
        if found.location == NSNotFound {
            return 0
        }
        return found.location + found.length
    }

    func rangeOfCharacter(from set: CharacterSet, options: NSString.CompareOptions, range: NSRange) -> NSRange {
        let location = max(0, range.location)
        let end = min(utf16Length, max(location, NSMaxRange(range)))
        guard location < end else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let backwards = options.contains(.backwards)
        let window = 4_096
        if backwards {
            var cursor = end
            while cursor > location {
                let sliceStart = max(location, cursor - window)
                let sliceLength = cursor - sliceStart
                guard let text = substring(in: NSRange(location: sliceStart, length: sliceLength)) else {
                    break
                }
                let ns = text as NSString
                let found = ns.rangeOfCharacter(from: set, options: options, range: NSRange(location: 0, length: ns.length))
                if found.location != NSNotFound {
                    return NSRange(location: sliceStart + found.location, length: found.length)
                }
                cursor = sliceStart
            }
            return NSRange(location: NSNotFound, length: 0)
        }
        var cursor = location
        while cursor < end {
            let take = min(window, end - cursor)
            guard let text = substring(in: NSRange(location: cursor, length: take)) else {
                break
            }
            let ns = text as NSString
            let found = ns.rangeOfCharacter(from: set, options: options, range: NSRange(location: 0, length: ns.length))
            if found.location != NSNotFound {
                return NSRange(location: cursor + found.location, length: found.length)
            }
            cursor += take
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    private static func isNewlineUTF16(_ unit: unichar) -> Bool {
        unit == 0x000A || unit == 0x000D || unit == 0x0085 || unit == 0x2028 || unit == 0x2029
    }

    func rangeOfComposedCharacterSequence(at location: Int) -> NSRange {
        let capped = min(max(location, 0), max(utf16Length - 1, 0))
        guard utf16Length > 0 else {
            return NSRange(location: 0, length: 0)
        }
        var radius = 16
        while true {
            let windowStart = max(0, capped - radius)
            let windowEnd = min(utf16Length, capped + radius)
            let window = NSRange(location: windowStart, length: max(windowEnd - windowStart, 0))
            guard window.length > 0, let text = substring(in: window) else {
                return NSRange(location: capped, length: 1)
            }
            let local = capped - windowStart
            let composed = (text as NSString).customRangeOfComposedCharacterSequence(at: local)
            let hitsStart = composed.location == 0 && windowStart > 0
            let hitsEnd = NSMaxRange(composed) == window.length && windowEnd < utf16Length
            if (!hitsStart && !hitsEnd) || radius >= utf16Length {
                return NSRange(location: windowStart + composed.location, length: composed.length)
            }
            radius *= 2
        }
    }

    func enumerateSubstrings(
        in range: NSRange,
        options: NSString.EnumerationOptions,
        using block: @escaping (String?, NSRange, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        guard range.length > 0, let text = substring(in: range) else {
            return
        }
        let ns = text as NSString
        let local = NSRange(location: 0, length: ns.length)
        ns.enumerateSubstrings(in: local, options: options) { substring, substringRange, enclosingRange, stop in
            let shifted = NSRange(location: range.location + substringRange.location, length: substringRange.length)
            let shiftedEnclosing = NSRange(
                location: range.location + enclosingRange.location,
                length: enclosingRange.length
            )
            block(substring, shifted, shiftedEnclosing, stop)
        }
    }

    func prefetch(utf16Range: NSRange) {
        guard let original else {
            return
        }
        let location = max(0, utf16Range.location)
        let length = min(max(utf16Range.length, 0), max(0, utf16Length - location))
        guard length > 0 else {
            return
        }
        var remainingCap = Self.prefetchByteCap
        var cursor = location
        let end = location + length
        while cursor < end, remainingCap > 0, let node = nodeContaining(cursor) {
            let piece = node.data.piece
            let pieceStart = cachedPieceUTF16Start
            if piece.source == .original {
                let local = cursor - pieceStart
                let take = min(end - cursor, piece.utf16Length - local)
                let utf8Start = piece.utf8Offset + utf8Offset(in: piece, localUTF16: local)
                let utf8End = piece.utf8Offset + utf8EndOffset(in: piece, localUTF16: local + take)
                let count = min(max(utf8End - utf8Start, 0), remainingCap)
                if count > 0 {
                    original.prefetch(byteOffset: utf8Start, count: count)
                    remainingCap -= count
                }
                cursor += take
            } else {
                cursor = pieceStart + piece.utf16Length
            }
        }
    }

    func materializeNSString() -> NSMutableString {
        materializeCount += 1
        if utf16Length == 0 {
            return NSMutableString()
        }
        let units = utf16Units(in: NSRange(location: 0, length: utf16Length))
        return NSMutableString(string: String(utf16CodeUnits: units, count: units.count))
    }

    func contentSnapshot() -> PieceTreeContentSnapshot {
        var copies: [PieceTreeContentSnapshot.PieceCopy] = []
        copies.reserveCapacity(max(pieceCount, 1))
        if utf16Length > 0 {
            var node = tree.root.leftMost
            let last = tree.root.rightMost
            while true {
                let piece = node.data.piece
                copies.append(PieceTreeContentSnapshot.PieceCopy(
                    sourceIsOriginal: piece.source == .original,
                    utf8Offset: piece.utf8Offset,
                    utf8Length: piece.utf8Length,
                    utf16Length: piece.utf16Length,
                    originalUTF16Start: piece.originalUTF16Start
                ))
                if node === last {
                    break
                }
                node = node.next
            }
        }
        return PieceTreeContentSnapshot(
            original: original,
            addBuffer: addBuffer,
            pieces: copies,
            originalCheckpoints: originalCheckpoints,
            utf16Length: utf16Length,
            utf8Length: copies.reduce(0) { $0 + $1.utf8Length }
        )
    }

    /// Replace original+delta with a single original piece covering `mapping`.
    /// Caller guarantees `mapping` bytes equal the concatenation of the current pieces.
    func compact(mapping: FileMapping, footer: DocumentWriteFooter) {
        RunestoneSignposts.interval("PieceTree.compact") {
            original = mapping
            originalCheckpoints = footer.checkpoints
            addBuffer = Data()
            let piece = Piece(
                source: .original,
                utf8Offset: 0,
                utf8Length: footer.utf8Length,
                utf16Length: footer.utf16Length,
                originalUTF16Start: 0,
                lineFeedCount: footer.lineFeedCount
            )
            replaceRoot(with: piece)
            utf16Length = footer.utf16Length
        }
    }

    // MARK: - Edits

    private func insert(_ string: String, atUTF16 location: Int) {
        let utf8 = Array(string.utf8)
        guard !utf8.isEmpty else {
            return
        }
        if utf8.count > UTF8DocumentScanner.checkpointStride {
            var offset = 0
            var at = location
            while offset < utf8.count {
                var end = min(offset + UTF8DocumentScanner.checkpointStride, utf8.count)
                while end < utf8.count, utf8[end] & 0xC0 == 0x80 {
                    end += 1
                }
                if end < utf8.count, end > offset, utf8[end - 1] == 0x0D, utf8[end] == 0x0A {
                    end += 1
                }
                let chunk = String(decoding: utf8[offset..<end], as: UTF8.self)
                insertSmall(chunk, atUTF16: at)
                at += (chunk as NSString).length
                offset = end
            }
            return
        }
        insertSmall(string, atUTF16: location)
    }

    private func insertSmall(_ string: String, atUTF16 location: Int) {
        let utf8 = Array(string.utf8)
        let utf16 = (string as NSString).length
        guard !utf8.isEmpty else {
            return
        }
        let lineFeeds = utf8.withUnsafeBytes { UTF8DocumentScanner.lineFeedCount(in: $0) }
        if let extendNode = extendableAddNode(endingAtUTF16: location),
           extendNode.data.piece.utf8Length + utf8.count <= UTF8DocumentScanner.checkpointStride {
            addBuffer.append(contentsOf: utf8)
            extendNode.data.piece.utf8Length += utf8.count
            extendNode.data.piece.utf16Length += utf16
            extendNode.data.piece.lineFeedCount += lineFeeds
            extendNode.value = extendNode.data.piece.utf16Length
            tree.updateAfterChangingChildren(of: extendNode)
            utf16Length += utf16
            return
        }
        let addOffset = addBuffer.count
        addBuffer.append(contentsOf: utf8)
        let newPiece = Piece(
            source: .add,
            utf8Offset: addOffset,
            utf8Length: utf8.count,
            utf16Length: utf16,
            originalUTF16Start: 0,
            lineFeedCount: lineFeeds
        )
        if utf16Length == 0 {
            replaceRoot(with: newPiece)
            utf16Length = utf16
            return
        }
        switch split(atUTF16: location) {
        case .end:
            _ = tree.insertNode(value: utf16, data: PieceNodeData(newPiece), after: tree.root.rightMost)
        case .node(let node):
            _ = tree.insertNode(value: utf16, data: PieceNodeData(newPiece), before: node)
        }
        utf16Length += utf16
        invalidateCache()
    }

    private func deleteUTF16(location: Int, length: Int) {
        guard length > 0, utf16Length > 0 else {
            return
        }
        let end = location + length
        _ = split(atUTF16: location)
        _ = split(atUTF16: end)
        var remaining = length
        while remaining > 0, utf16Length > 0 {
            guard let node = nodeContaining(location) else {
                break
            }
            let pieceLength = node.value
            guard pieceLength > 0, pieceLength <= remaining else {
                break
            }
            if tree.root.nodeTotalCount == 1 {
                replaceRoot(with: Piece(
                    source: .add,
                    utf8Offset: 0,
                    utf8Length: 0,
                    utf16Length: 0,
                    originalUTF16Start: 0,
                    lineFeedCount: 0
                ))
                utf16Length = 0
                remaining = 0
                break
            }
            tree.remove(node)
            invalidateCache()
            utf16Length -= pieceLength
            remaining -= pieceLength
        }
    }

    private enum SplitPoint {
        case node(PieceNode)
        case end
    }

    /// Split so a piece boundary exists at `utf16Offset`. Returns the node that starts there, or `.end`.
    @discardableResult
    private func split(atUTF16 utf16Offset: Int) -> SplitPoint {
        if utf16Offset <= 0 {
            return .node(tree.root.leftMost)
        }
        if utf16Offset >= utf16Length {
            return .end
        }
        guard let node = nodeContaining(utf16Offset) else {
            return .end
        }
        let pieceStart = cachedPieceUTF16Start
        if utf16Offset == pieceStart {
            return .node(node)
        }
        let piece = node.data.piece
        let localUTF16 = utf16Offset - pieceStart
        let localUTF8 = withUTF8(of: piece) { bytes in
            let position = UTF8DocumentScanner.utf8Position(forUTF16Offset: localUTF16, in: bytes)
            if position.skip > 0 {
                return UTF8DocumentScanner.utf8EndOffset(forUTF16Offset: localUTF16, in: bytes)
            }
            return position.utf8Offset
        }
        let actualLeftUTF16 = withUTF8(of: piece) { bytes in
            let slice = UnsafeRawBufferPointer(rebasing: bytes[..<min(localUTF8, bytes.count)])
            return UTF8DocumentScanner.utf16Length(ofUTF8: slice)
        }
        if actualLeftUTF16 <= 0 {
            return .node(node)
        }
        if actualLeftUTF16 >= piece.utf16Length {
            if node === tree.root.rightMost {
                return .end
            }
            return .node(node.next)
        }
        let leftFeeds = lineFeedCount(in: piece, utf8Length: localUTF8)
        let left = Piece(
            source: piece.source,
            utf8Offset: piece.utf8Offset,
            utf8Length: localUTF8,
            utf16Length: actualLeftUTF16,
            originalUTF16Start: piece.originalUTF16Start,
            lineFeedCount: leftFeeds
        )
        let right = Piece(
            source: piece.source,
            utf8Offset: piece.utf8Offset + localUTF8,
            utf8Length: piece.utf8Length - localUTF8,
            utf16Length: piece.utf16Length - actualLeftUTF16,
            originalUTF16Start: piece.source == .original
                ? piece.originalUTF16Start + actualLeftUTF16
                : 0,
            lineFeedCount: piece.lineFeedCount - leftFeeds
        )
        node.data.piece = left
        node.value = left.utf16Length
        tree.updateAfterChangingChildren(of: node)
        let rightNode = tree.insertNode(value: right.utf16Length, data: PieceNodeData(right), after: node)
        invalidateCache()
        return .node(rightNode)
    }

    private func extendableAddNode(endingAtUTF16 location: Int) -> PieceNode? {
        guard location > 0, location <= utf16Length else {
            return nil
        }
        guard let node = nodeContaining(location - 1) else {
            return nil
        }
        let piece = node.data.piece
        let pieceEnd = cachedPieceUTF16Start + piece.utf16Length
        guard pieceEnd == location,
              piece.source == .add,
              piece.utf8Offset + piece.utf8Length == addBuffer.count else {
            return nil
        }
        return node
    }

    private func replaceRoot(with piece: Piece) {
        tree.reset(rootValue: piece.utf16Length, rootData: PieceNodeData(piece))
        tree.childrenUpdater = PieceChildrenUpdater()
        tree.root.data.nodeTotalLineFeedCount = piece.lineFeedCount
        invalidateCache()
    }

    // MARK: - Reads

    @discardableResult
    private func nodeContaining(_ location: Int) -> PieceNode? {
        guard location >= 0, location < utf16Length else {
            return nil
        }
        if let cached = cachedNode {
            let start = cachedPieceUTF16Start
            if location >= start && location < start + cached.value {
                return cached
            }
        }
        guard let node = tree.node(containingLocation: location) else {
            return nil
        }
        cachedNode = node
        cachedPieceUTF16Start = node.location
        return node
    }

    private func utf16Unit(at location: Int) -> unichar {
        let units = utf16Units(in: NSRange(location: location, length: 1))
        return units.first ?? 0
    }

    private func utf16Units(in range: NSRange) -> [unichar] {
        var result: [unichar] = []
        result.reserveCapacity(max(range.length, 0))
        var remaining = range.length
        var location = range.location
        while remaining > 0, let node = nodeContaining(location) {
            let pieceStart = cachedPieceUTF16Start
            let piece = node.data.piece
            let local = location - pieceStart
            let take = min(remaining, piece.utf16Length - local)
            appendUTF16Units(of: piece, localUTF16: local, take: take, into: &result)
            remaining -= take
            location += take
        }
        return result
    }

    private func appendUTF16Units(
        of piece: Piece,
        localUTF16: Int,
        take: Int,
        into result: inout [unichar]
    ) {
        withUTF8(of: piece) { bytes in
            if piece.source == .add || originalCheckpoints.isEmpty {
                UTF8DocumentScanner.appendUTF16Units(from: bytes, utf16Offset: localUTF16, length: take, into: &result)
                return
            }
            let targetUTF16 = piece.originalUTF16Start + localUTF16
            var startUTF8 = piece.utf8Offset
            var baseUTF16 = piece.originalUTF16Start
            if let checkpoint = lastCheckpoint(utf16Offset: targetUTF16),
               checkpoint.utf8Offset >= piece.utf8Offset,
               checkpoint.utf16Offset <= targetUTF16 {
                startUTF8 = checkpoint.utf8Offset
                baseUTF16 = checkpoint.utf16Offset
            }
            let limit = piece.utf8Offset + piece.utf8Length
            let extraBytes = UnsafeRawBufferPointer(
                start: bytes.baseAddress.map { $0 + (startUTF8 - piece.utf8Offset) },
                count: max(limit - startUTF8, 0)
            )
            UTF8DocumentScanner.appendUTF16Units(
                from: extraBytes,
                utf16Offset: targetUTF16 - baseUTF16,
                length: take,
                into: &result
            )
        }
    }

    private func utf8Offset(in piece: Piece, localUTF16: Int) -> Int {
        resolveUTF8Offset(in: piece, localUTF16: localUTF16, end: false)
    }

    private func utf8EndOffset(in piece: Piece, localUTF16: Int) -> Int {
        resolveUTF8Offset(in: piece, localUTF16: localUTF16, end: true)
    }

    private func resolveUTF8Offset(in piece: Piece, localUTF16: Int, end: Bool) -> Int {
        if localUTF16 <= 0 {
            return 0
        }
        if localUTF16 >= piece.utf16Length {
            return piece.utf8Length
        }
        if piece.source == .add || originalCheckpoints.isEmpty {
            return withUTF8(of: piece) { bytes in
                if end {
                    return addBufferUTF8EndOffset(in: piece, localUTF16: localUTF16, bytes: bytes)
                }
                return addBufferUTF8Offset(in: piece, localUTF16: localUTF16, bytes: bytes)
            }
        }
        guard let original, let base = original.baseAddress else {
            return 0
        }
        let targetUTF16 = piece.originalUTF16Start + localUTF16
        var startUTF8 = piece.utf8Offset
        var utf16 = piece.originalUTF16Start
        if let checkpoint = lastCheckpoint(utf16Offset: targetUTF16),
           checkpoint.utf8Offset >= piece.utf8Offset,
           checkpoint.utf16Offset <= targetUTF16 {
            startUTF8 = checkpoint.utf8Offset
            utf16 = checkpoint.utf16Offset
        }
        let limit = piece.utf8Offset + piece.utf8Length
        let bytes = UnsafeRawBufferPointer(start: base + startUTF8, count: max(limit - startUTF8, 0))
        let relative = targetUTF16 - utf16
        let extra = end
            ? UTF8DocumentScanner.utf8EndOffset(forUTF16Offset: relative, in: bytes)
            : UTF8DocumentScanner.utf8Offset(forUTF16Offset: relative, in: bytes)
        return (startUTF8 + extra) - piece.utf8Offset
    }

    /// `.add`-buffer pieces carry no ``originalCheckpoints`` (those only exist for the `.original`,
    /// file-mapped piece), so this used to always resolve `localUTF16` by scanning `bytes` from
    /// byte 0 — cheap for one call, but `TreeSitterLanguageLayer.parseUsingReader()`'s tree-sitter
    /// reader requests strictly increasing byte ranges while parsing a whole document, so every one
    /// of the O(n) chunk reads rescanned from the start: O(n²) total for a single full-document
    /// parse (measured: ~20s to open a 700 KB file once it crossed `StringView`'s piece-tree
    /// threshold, vs. ~35ms for the same content just under it). Caching the last forward position
    /// and resuming from there makes that dominant, monotonically-increasing access pattern
    /// amortized O(n); a backward seek or a different piece just falls back to scanning from 0.
    private func addBufferUTF8Offset(in piece: Piece, localUTF16: Int, bytes: UnsafeRawBufferPointer) -> Int {
        addBufferUTF8Offset(in: piece, localUTF16: localUTF16, bytes: bytes, end: false)
    }

    private func addBufferUTF8EndOffset(in piece: Piece, localUTF16: Int, bytes: UnsafeRawBufferPointer) -> Int {
        addBufferUTF8Offset(in: piece, localUTF16: localUTF16, bytes: bytes, end: true)
    }

    private func addBufferUTF8Offset(
        in piece: Piece,
        localUTF16: Int,
        bytes: UnsafeRawBufferPointer,
        end: Bool
    ) -> Int {
        if let cursor = addBufferOffsetCursor,
           cursor.pieceUTF8Offset == piece.utf8Offset,
           cursor.localUTF16 <= localUTF16,
           cursor.utf8Offset <= bytes.count {
            let resumeBytes = UnsafeRawBufferPointer(rebasing: bytes[cursor.utf8Offset...])
            let extra = end
                ? UTF8DocumentScanner.utf8EndOffset(forUTF16Offset: localUTF16 - cursor.localUTF16, in: resumeBytes)
                : UTF8DocumentScanner.utf8Offset(forUTF16Offset: localUTF16 - cursor.localUTF16, in: resumeBytes)
            let result = cursor.utf8Offset + extra
            if !end {
                addBufferOffsetCursor = (piece.utf8Offset, localUTF16, result)
            }
            return result
        }
        let result = end
            ? UTF8DocumentScanner.utf8EndOffset(forUTF16Offset: localUTF16, in: bytes)
            : UTF8DocumentScanner.utf8Offset(forUTF16Offset: localUTF16, in: bytes)
        if piece.source == .add, !end {
            addBufferOffsetCursor = (piece.utf8Offset, localUTF16, result)
        }
        return result
    }

    private func lineFeedCount(in piece: Piece, utf8Length: Int) -> Int {
        if utf8Length <= 0 {
            return 0
        }
        if utf8Length >= piece.utf8Length {
            return piece.lineFeedCount
        }
        if piece.source == .original, !originalCheckpoints.isEmpty {
            return originalLineFeedCount(utf8Start: piece.utf8Offset, utf8Length: utf8Length)
        }
        return withUTF8(of: piece) { bytes in
            let slice = UnsafeRawBufferPointer(start: bytes.baseAddress, count: min(utf8Length, bytes.count))
            return UTF8DocumentScanner.lineFeedCount(in: slice)
        }
    }

    private func originalLineFeedCount(utf8Start: Int, utf8Length: Int) -> Int {
        let utf8End = utf8Start + utf8Length
        let startCheckpoint = lastCheckpoint(utf8Offset: utf8Start)
        let endCheckpoint = lastCheckpoint(utf8Offset: utf8End)
        let startBase = startCheckpoint?.utf8Offset ?? 0
        let endBase = endCheckpoint?.utf8Offset ?? 0
        let startLines = startCheckpoint?.lineCount ?? 0
        let endLines = endCheckpoint?.lineCount ?? 0
        let beforeStart = scanLineFeeds(utf8Start: startBase, utf8End: utf8Start)
        let beforeEnd = scanLineFeeds(utf8Start: endBase, utf8End: utf8End)
        return max(0, (endLines - startLines) - beforeStart + beforeEnd)
    }

    private func scanLineFeeds(utf8Start: Int, utf8End: Int) -> Int {
        guard utf8End > utf8Start, let original, let base = original.baseAddress else {
            return 0
        }
        let bytes = UnsafeRawBufferPointer(start: base + utf8Start, count: utf8End - utf8Start)
        return UTF8DocumentScanner.lineFeedCount(in: bytes)
    }

    private func lastCheckpoint(utf16Offset: Int) -> UTF8DocumentScanner.Checkpoint? {
        lastCheckpoint(where: { $0.utf16Offset <= utf16Offset })
    }

    private func lastCheckpoint(utf8Offset: Int) -> UTF8DocumentScanner.Checkpoint? {
        lastCheckpoint(where: { $0.utf8Offset <= utf8Offset })
    }

    private func lastCheckpoint(where predicate: (UTF8DocumentScanner.Checkpoint) -> Bool) -> UTF8DocumentScanner.Checkpoint? {
        guard !originalCheckpoints.isEmpty else {
            return nil
        }
        var low = 0
        var high = originalCheckpoints.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(originalCheckpoints[mid]) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let index = low - 1
        guard index >= 0 else {
            return originalCheckpoints.first
        }
        return originalCheckpoints[index]
    }

    func withUTF8<T>(of piece: Piece, _ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        switch piece.source {
        case .original:
            guard let original, let base = original.baseAddress else {
                return try body(UnsafeRawBufferPointer(start: nil, count: 0))
            }
            return try body(UnsafeRawBufferPointer(start: base + piece.utf8Offset, count: piece.utf8Length))
        case .add:
            return try addBuffer.withUnsafeBytes { raw in
                let start = raw.baseAddress.map { $0 + piece.utf8Offset }
                return try body(UnsafeRawBufferPointer(start: start, count: piece.utf8Length))
            }
        }
    }

    private func invalidateCache() {
        cachedNode = nil
        cachedPieceUTF16Start = 0
        addBufferOffsetCursor = nil
    }
}
