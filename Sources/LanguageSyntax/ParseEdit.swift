import EditorIntelligence
import Foundation
import TreeSitter

/// One tree-sitter buffer edit derived from an EditorIntelligence ``TextEdit``.
public struct ParseEdit {
    package let rawValue: TSInputEdit

    /// Where the edit starts, and where the replaced and the replacing text end, in UTF-8 bytes.
    package var startByte: Int { Int(rawValue.start_byte) }
    package var oldEndByte: Int { Int(rawValue.old_end_byte) }
    package var newEndByte: Int { Int(rawValue.new_end_byte) }

    package static func utf8ByteOffset(forUTF16Offset offset: Int, in source: String) -> Int {
        let clamped = min(max(0, offset), source.utf16.count)
        let utf16Index = source.utf16.index(source.utf16.startIndex, offsetBy: clamped)
        return source.utf8.distance(from: source.utf8.startIndex, to: utf16Index)
    }

    /// The row and column (in bytes) of `offset`. One counting pass over the bytes before it, then a
    /// short backward scan for the start of its line.
    package static func point(forByteOffset offset: Int, in bytes: [UInt8]) -> TSPoint {
        bytes.withUnsafeBufferPointer { buffer in
            let end = max(0, min(offset, buffer.count))
            let rows = newlineCount(in: buffer, from: 0, to: end)
            let lineStart = rows == 0 ? 0 : lastLineStart(in: buffer, from: 0, before: end)
            return TSPoint(row: UInt32(rows), column: UInt32(max(0, offset - lineStart)))
        }
    }

    /// The original `point(forByteOffset:in:)`, one byte at a time from zero. The oracle for ``point(forByteOffset:in:)``.
    package static func referencePoint(forByteOffset offset: Int, in bytes: [UInt8]) -> TSPoint {
        var row: UInt32 = 0
        var lineStart = 0
        for index in 0..<min(offset, bytes.count) where bytes[index] == 10 {
            row += 1
            lineStart = index + 1
        }
        return TSPoint(row: row, column: UInt32(max(0, offset - lineStart)))
    }

    // MARK: - Scanning

    /// Block size of the `memcmp` passes. Large enough that libc's vectorized compare does the work,
    /// small enough that finding the first difference inside the failing block stays cheap.
    private static let compareBlock = 4096

    /// Bytes at the start that `a` and `b` share, up to `limit`.
    package static func commonPrefixLength(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>, limit: Int) -> Int {
        guard limit > 0, let pa = a.baseAddress, let pb = b.baseAddress else { return 0 }
        var index = 0
        while limit - index >= compareBlock, memcmp(pa + index, pb + index, compareBlock) == 0 {
            index += compareBlock
        }
        while index < limit, pa[index] == pb[index] { index += 1 }
        return index
    }

    /// Bytes at the end that `a` and `b` share, up to `limit`.
    package static func commonSuffixLength(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>, limit: Int) -> Int {
        guard limit > 0, let pa = a.baseAddress, let pb = b.baseAddress else { return 0 }
        var length = 0
        while limit - length >= compareBlock,
              memcmp(pa + (a.count - length - compareBlock), pb + (b.count - length - compareBlock), compareBlock) == 0 {
            length += compareBlock
        }
        while length < limit, pa[a.count - 1 - length] == pb[b.count - 1 - length] { length += 1 }
        return length
    }

    /// How many `\n` lie in `buffer[from..<to]`.
    ///
    /// Eight bytes at a time. XOR with `0x0A` turns each newline into a zero byte, and the test
    /// below sets the top bit of a byte exactly when that byte is zero (no false positives from
    /// carries, unlike the shorter `(x - 0x01..) & ~x & 0x80..` form), so a popcount is the count.
    /// A one-byte-at-a-time loop here ran at about 1.3 GB/s: it is the only part of `diff` that
    /// reads the whole prefix, and it was most of the cost of a 120,000-line file.
    package static func newlineCount(in buffer: UnsafeBufferPointer<UInt8>, from: Int, to: Int) -> Int {
        guard from < to, let base = buffer.baseAddress else { return 0 }
        let raw = UnsafeRawPointer(base)
        let newlines: UInt64 = 0x0A0A_0A0A_0A0A_0A0A
        let low7: UInt64 = 0x7F7F_7F7F_7F7F_7F7F
        @inline(__always) func zeroBytes(at offset: Int) -> Int {
            let x = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self) ^ newlines
            return (~(((x & low7) &+ low7) | x | low7)).nonzeroBitCount
        }
        var count = 0
        var index = from
        while to - index >= 32 {
            count &+= zeroBytes(at: index) &+ zeroBytes(at: index + 8) &+ zeroBytes(at: index + 16) &+ zeroBytes(at: index + 24)
            index += 32
        }
        while to - index >= 8 {
            count &+= zeroBytes(at: index)
            index += 8
        }
        while index < to {
            count &+= base[index] == 10 ? 1 : 0
            index += 1
        }
        return count
    }

    /// The index just after the last `\n` in `buffer[from..<end]` (`from` when there is none).
    private static func lastLineStart(in buffer: UnsafeBufferPointer<UInt8>, from: Int, before end: Int) -> Int {
        var index = end
        while index > from {
            if buffer[index - 1] == 10 { return index }
            index -= 1
        }
        return from
    }

    /// `start` moved over `buffer[from..<to]`.
    private static func advance(_ start: TSPoint, over buffer: UnsafeBufferPointer<UInt8>, from: Int, to: Int) -> TSPoint {
        let rows = newlineCount(in: buffer, from: from, to: to)
        if rows == 0 { return TSPoint(row: start.row, column: start.column + UInt32(to - from)) }
        return TSPoint(row: start.row + UInt32(rows), column: UInt32(to - lastLineStart(in: buffer, from: from, before: to)))
    }

    /// The single edit that turns `old` into `new`: everything between their common prefix and
    /// common suffix. `nil` when they are equal.
    ///
    /// The shared prefix is scanned once with blocked `memcmp`, as is the suffix. The prefix is
    /// common to both texts, so its row and column are found once and the old and new end points
    /// are that point advanced over only the changed bytes, instead of three scans from byte zero.
    /// ``referenceDiff(from:to:)`` is the original and the oracle.
    package static func diff(from old: [UInt8], to new: [UInt8]) -> ParseEdit? {
        if usesReferenceImplementation { return referenceDiff(from: old, to: new) }
        return old.withUnsafeBufferPointer { oldBuffer in
            new.withUnsafeBufferPointer { newBuffer in
                let limit = min(oldBuffer.count, newBuffer.count)
                let prefix = commonPrefixLength(oldBuffer, newBuffer, limit: limit)
                if prefix == oldBuffer.count, prefix == newBuffer.count { return nil }
                let suffix = commonSuffixLength(oldBuffer, newBuffer, limit: limit - prefix)
                let oldEnd = oldBuffer.count - suffix
                let newEnd = newBuffer.count - suffix
                let rows = newlineCount(in: oldBuffer, from: 0, to: prefix)
                let lineStart = rows == 0 ? 0 : lastLineStart(in: oldBuffer, from: 0, before: prefix)
                let startPoint = TSPoint(row: UInt32(rows), column: UInt32(prefix - lineStart))
                return ParseEdit(rawValue: TSInputEdit(
                    start_byte: UInt32(prefix),
                    old_end_byte: UInt32(oldEnd),
                    new_end_byte: UInt32(newEnd),
                    start_point: startPoint,
                    old_end_point: advance(startPoint, over: oldBuffer, from: prefix, to: oldEnd),
                    new_end_point: advance(startPoint, over: newBuffer, from: prefix, to: newEnd)
                ))
            }
        }
    }

    /// `UMBRA_PARSE_EDIT_REFERENCE=1` runs the original implementation: the way to rule this code out if
    /// an incremental parse is ever suspected, and how the release harness measures before and after.
    private static let usesReferenceImplementation = ProcessInfo.processInfo.environment["UMBRA_PARSE_EDIT_REFERENCE"] == "1"

    /// The original `diff`, unchanged: scan from both ends, then three row/column points from byte
    /// zero. Kept as the oracle the optimized ``diff(from:to:)`` is tested against and as the
    /// reference the release harness times it against.
    package static func referenceDiff(from old: [UInt8], to new: [UInt8]) -> ParseEdit? {
        guard old != new else { return nil }
        var prefix = 0
        let limit = min(old.count, new.count)
        while prefix < limit, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let oldEnd = old.count - suffix
        let newEnd = new.count - suffix
        return ParseEdit(rawValue: TSInputEdit(
            start_byte: UInt32(prefix),
            old_end_byte: UInt32(oldEnd),
            new_end_byte: UInt32(newEnd),
            start_point: referencePoint(forByteOffset: prefix, in: old),
            old_end_point: referencePoint(forByteOffset: oldEnd, in: old),
            new_end_point: referencePoint(forByteOffset: newEnd, in: new)
        ))
    }

    /// Row and column of the three points, for tests that should not import the C module.
    package var points: (start: [Int], oldEnd: [Int], newEnd: [Int]) {
        let raw = rawValue
        return (
            [Int(raw.start_point.row), Int(raw.start_point.column)],
            [Int(raw.old_end_point.row), Int(raw.old_end_point.column)],
            [Int(raw.new_end_point.row), Int(raw.new_end_point.column)]
        )
    }

    /// ``point(forByteOffset:in:)`` as `[row, column]`.
    package static func position(forByteOffset offset: Int, in bytes: [UInt8]) -> [Int] {
        let p = point(forByteOffset: offset, in: bytes)
        return [Int(p.row), Int(p.column)]
    }

    /// ``referencePoint(forByteOffset:in:)`` as `[row, column]`.
    package static func referencePosition(forByteOffset offset: Int, in bytes: [UInt8]) -> [Int] {
        let p = referencePoint(forByteOffset: offset, in: bytes)
        return [Int(p.row), Int(p.column)]
    }

    /// Whether both describe the same edit: bytes and the three points.
    package func isEqual(to other: ParseEdit) -> Bool {
        let a = rawValue, b = other.rawValue
        return a.start_byte == b.start_byte && a.old_end_byte == b.old_end_byte && a.new_end_byte == b.new_end_byte
            && a.start_point.row == b.start_point.row && a.start_point.column == b.start_point.column
            && a.old_end_point.row == b.old_end_point.row && a.old_end_point.column == b.old_end_point.column
            && a.new_end_point.row == b.new_end_point.row && a.new_end_point.column == b.new_end_point.column
    }

    package static func make(edit: TextEdit, in source: String) -> (edit: ParseEdit, newSource: String)? {
        let start = utf8ByteOffset(forUTF16Offset: edit.range.start.utf16Offset, in: source)
        let oldEnd = utf8ByteOffset(forUTF16Offset: edit.range.end.utf16Offset, in: source)
        guard start <= oldEnd else { return nil }
        let oldBytes = Array(source.utf8)
        let replacement = Array(edit.replacement.utf8)
        var newBytes = oldBytes
        newBytes.replaceSubrange(start..<oldEnd, with: replacement)
        let newEnd = start + replacement.count
        let raw = TSInputEdit(
            start_byte: UInt32(start),
            old_end_byte: UInt32(oldEnd),
            new_end_byte: UInt32(newEnd),
            start_point: point(forByteOffset: start, in: oldBytes),
            old_end_point: point(forByteOffset: oldEnd, in: oldBytes),
            new_end_point: point(forByteOffset: newEnd, in: newBytes)
        )
        let newSource = String(decoding: newBytes, as: UTF8.self)
        return (ParseEdit(rawValue: raw), newSource)
    }
}
