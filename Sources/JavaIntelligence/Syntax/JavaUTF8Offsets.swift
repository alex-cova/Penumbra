import Foundation
import EditorIntelligence
import LanguageSyntax

/// Conversion between the editor's UTF-16 offsets and UTF-8 byte offsets (what tree-sitter uses),
/// done on the bytes themselves.
///
/// Swift's own route (`String.utf16.index(_:offsetBy:)`, `NSString` access) is O(1) for an ASCII
/// string and builds a UTF-16 breadcrumb table for any other, which is O(n) per new string: one
/// `é` in a comment at the top of a 120,000-line file made a completion request nine times slower.
/// This scans instead: ASCII runs 32 bytes at a time, other scalars one by one, about 20 GB/s on
/// ASCII text, and it needs no table and no allocation.
enum JavaUTF8Offsets {
    /// The byte offset of the scalar that starts at UTF-16 offset `target`. An offset past the end
    /// gives `bytes.count`; one that falls inside a surrogate pair gives the start of that scalar.
    static func byteOffset(forUTF16Offset target: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Int {
        scan(forUTF16Offset: target, in: bytes).byteOffset
    }

    /// ``byteOffset(forUTF16Offset:in:)`` and how many UTF-16 units were passed to get there: fewer than
    /// `target` when the text ends first, or when `target` is inside a surrogate pair.
    static func scan(forUTF16Offset target: Int, in bytes: UnsafeBufferPointer<UInt8>) -> (byteOffset: Int, utf16Units: Int) {
        guard target > 0, let base = bytes.baseAddress else { return (0, 0) }
        let raw = UnsafeRawPointer(base)
        let count = bytes.count
        let highBits: UInt64 = 0x8080_8080_8080_8080
        var units = 0
        var index = 0
        while index < count, units < target {
            // Four words of ASCII are 32 units, as long as they cannot overshoot the target.
            if count - index >= 32, target - units >= 32 {
                let a = raw.loadUnaligned(fromByteOffset: index, as: UInt64.self)
                let b = raw.loadUnaligned(fromByteOffset: index + 8, as: UInt64.self)
                let c = raw.loadUnaligned(fromByteOffset: index + 16, as: UInt64.self)
                let d = raw.loadUnaligned(fromByteOffset: index + 24, as: UInt64.self)
                if (a | b | c | d) & highBits == 0 {
                    index += 32
                    units += 32
                    continue
                }
            }
            let byte = base[index]
            let width: Int
            let scalarUnits: Int
            if byte < 0x80 { width = 1; scalarUnits = 1 }
            else if byte < 0xE0 { width = 2; scalarUnits = 1 }
            else if byte < 0xF0 { width = 3; scalarUnits = 1 }
            else { width = 4; scalarUnits = 2 }
            if units + scalarUnits > target { break }
            index += width
            units += scalarUnits
        }
        return (min(index, count), units)
    }

    /// The byte offset reached by going back `units` UTF-16 units from `offset`. Stops at 0, and at
    /// the start of the scalar when `units` ends inside a surrogate pair.
    static func byteOffset(movingBackUTF16Units units: Int, from offset: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var index = min(max(0, offset), bytes.count)
        var remaining = units
        while remaining > 0, index > 0 {
            var start = index - 1
            while start > 0, bytes[start] & 0xC0 == 0x80 { start -= 1 }
            let scalarUnits = bytes[start] >= 0xF0 ? 2 : 1
            if scalarUnits > remaining { break }
            remaining -= scalarUnits
            index = start
        }
        return index
    }

    /// How many UTF-16 units the scalars of `bytes[from..<to]` take (both bounds at scalar starts). A
    /// scalar is one unit, or two when it needs four UTF-8 bytes. ASCII runs are skipped 32 bytes at a time.
    static func utf16Length(of bytes: UnsafeBufferPointer<UInt8>, from: Int, to: Int) -> Int {
        guard from < to, let base = bytes.baseAddress else { return 0 }
        let raw = UnsafeRawPointer(base)
        let highBits: UInt64 = 0x8080_8080_8080_8080
        var units = 0
        var index = from
        while index < to {
            if to - index >= 32 {
                let a = raw.loadUnaligned(fromByteOffset: index, as: UInt64.self)
                let b = raw.loadUnaligned(fromByteOffset: index + 8, as: UInt64.self)
                let c = raw.loadUnaligned(fromByteOffset: index + 16, as: UInt64.self)
                let d = raw.loadUnaligned(fromByteOffset: index + 24, as: UInt64.self)
                if (a | b | c | d) & highBits == 0 {
                    units += 32
                    index += 32
                    continue
                }
            }
            let byte = base[index]
            if byte & 0xC0 != 0x80 { units += byte >= 0xF0 ? 2 : 1 }
            index += 1
        }
        return units
    }

    /// The line (`\n` bytes before it), the UTF-16 column on that line and the UTF-16 offset of a byte
    /// offset, from the bytes. Reading the prefix as a `String` and counting its `Character`s cost 7 ms
    /// at 20,000 lines and 44 ms at 120,000 for each position, several per request, and missed a CRLF
    /// line break (the grapheme `"\r\n"` is not `"\n"`).
    static func position(ofByte offset: Int, in bytes: UnsafeBufferPointer<UInt8>) -> (line: Int, column: Int, utf16Offset: Int) {
        let end = min(max(0, offset), bytes.count)
        let line = ParseEdit.newlineCount(in: bytes, from: 0, to: end)
        var lineStart = end
        while lineStart > 0, bytes[lineStart - 1] != 0x0A { lineStart -= 1 }
        let column = utf16Length(of: bytes, from: lineStart, to: end)
        // The offset is the lines before this one, counted only when there are any.
        let utf16Offset = line == 0 ? column : utf16Length(of: bytes, from: 0, to: lineStart) + column
        return (line, column, utf16Offset)
    }
}

/// Positions of byte offsets in one request's text, each worked out once. The postfix templates ask
/// for the same two positions for every template they build.
final class JavaBytePositions {
    private let bytes: [UInt8]
    private var known: [Int: TextPosition] = [:]

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    func position(ofByte offset: Int) -> TextPosition {
        if let cached = known[offset] { return cached }
        let found = bytes.withUnsafeBufferPointer { JavaUTF8Offsets.position(ofByte: offset, in: $0) }
        let position = TextPosition(line: found.line, column: found.column, utf16Offset: found.utf16Offset)
        known[offset] = position
        return position
    }
}
