import Foundation

/// The one changed region between two versions of a text, as the `TSInputEdit` tree-sitter needs to
/// reuse a tree for the new text (UTF-16 parsing: byte offsets and columns are twice the unit counts).
///
/// The region is everything between the longest common prefix and the longest common suffix, backed
/// off to scalar boundaries. It is not the edit the user made, only a region that contains it, and any
/// region that contains the real change is a correct edit for tree-sitter.
enum TextChangeRegion {
    static func edit(from old: String, to new: String) -> TreeSitterInputEdit? {
        var old = old
        var new = new
        return old.withUTF8 { oldBytes in
            new.withUTF8 { newBytes in
                edit(oldBytes: oldBytes, newBytes: newBytes)
            }
        }
    }

    private static func edit(oldBytes: UnsafeBufferPointer<UInt8>, newBytes: UnsafeBufferPointer<UInt8>) -> TreeSitterInputEdit? {
        let common = min(oldBytes.count, newBytes.count)
        var prefix = 0
        while prefix < common, oldBytes[prefix] == newBytes[prefix] { prefix += 1 }
        if prefix == oldBytes.count, prefix == newBytes.count { return nil }
        // Do not split a scalar: back off to the byte that starts the one containing the difference.
        while prefix > 0, isContinuation(at: prefix, in: oldBytes) || isContinuation(at: prefix, in: newBytes) { prefix -= 1 }
        var suffix = 0
        while suffix < common - prefix, oldBytes[oldBytes.count - 1 - suffix] == newBytes[newBytes.count - 1 - suffix] { suffix += 1 }
        while suffix > 0,
              isContinuation(at: oldBytes.count - suffix, in: oldBytes) || isContinuation(at: newBytes.count - suffix, in: newBytes) {
            suffix -= 1
        }
        let oldEnd = oldBytes.count - suffix
        let newEnd = newBytes.count - suffix

        let before = measure(oldBytes, 0 ..< prefix)
        let removed = measure(oldBytes, prefix ..< oldEnd)
        let added = measure(newBytes, prefix ..< newEnd)
        let startPoint = TreeSitterTextPoint(row: UInt32(before.newlines), column: UInt32(before.columnUnits * 2))
        func end(of region: (newlines: Int, units: Int, columnUnits: Int)) -> TreeSitterTextPoint {
            region.newlines == 0
                ? TreeSitterTextPoint(row: startPoint.row, column: UInt32((before.columnUnits + region.units) * 2))
                : TreeSitterTextPoint(row: startPoint.row + UInt32(region.newlines), column: UInt32(region.columnUnits * 2))
        }
        return TreeSitterInputEdit(
            startByte: ByteCount(before.units * 2),
            oldEndByte: ByteCount((before.units + removed.units) * 2),
            newEndByte: ByteCount((before.units + added.units) * 2),
            startPoint: startPoint,
            oldEndPoint: end(of: removed),
            newEndPoint: end(of: added)
        )
    }

    private static func isContinuation(at index: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        index < bytes.count && bytes[index] & 0xC0 == 0x80
    }

    /// Newlines, UTF-16 units, and the units after the last newline in `range` (all units when there
    /// is none) of well-formed UTF-8.
    private static func measure(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ range: Range<Int>
    ) -> (newlines: Int, units: Int, columnUnits: Int) {
        var newlines = 0
        var units = 0
        var column = 0
        for index in range {
            let byte = bytes[index]
            if byte & 0xC0 == 0x80 { continue }
            // A four-byte scalar is a surrogate pair.
            let width = byte >= 0xF0 ? 2 : 1
            units += width
            if byte == 0x0A {
                newlines += 1
                column = 0
            } else {
                column += width
            }
        }
        return (newlines, units, column)
    }
}
