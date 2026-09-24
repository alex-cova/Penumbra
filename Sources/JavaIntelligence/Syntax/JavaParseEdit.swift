import EditorIntelligence
import Foundation
import TreeSitter

/// One tree-sitter buffer edit derived from an EditorIntelligence ``TextEdit``.
struct JavaParseEdit {
    let rawValue: TSInputEdit

    static func utf8ByteOffset(forUTF16Offset offset: Int, in source: String) -> Int {
        let clamped = min(max(0, offset), source.utf16.count)
        let utf16Index = source.utf16.index(source.utf16.startIndex, offsetBy: clamped)
        return source.utf8.distance(from: source.utf8.startIndex, to: utf16Index)
    }

    static func point(forByteOffset offset: Int, in bytes: [UInt8]) -> TSPoint {
        var row: UInt32 = 0
        var lineStart = 0
        for index in 0..<min(offset, bytes.count) where bytes[index] == 10 {
            row += 1
            lineStart = index + 1
        }
        return TSPoint(row: row, column: UInt32(max(0, offset - lineStart)))
    }

    static func make(edit: TextEdit, in source: String) -> (edit: JavaParseEdit, newSource: String)? {
        let start = utf8ByteOffset(forUTF16Offset: edit.range.start.utf16Offset, in: source)
        let oldEnd = utf8ByteOffset(forUTF16Offset: edit.range.end.utf16Offset, in: source)
        guard start <= oldEnd else { return nil }
        let oldBytes = Array(source.utf8)
        let replacement = Array(edit.replacement.utf8)
        var newBytes = oldBytes
        newBytes.replaceSubrange(start..<oldEnd, with: replacement)
        let newEnd = start + replacement.count
        var raw = TSInputEdit(
            start_byte: UInt32(start),
            old_end_byte: UInt32(oldEnd),
            new_end_byte: UInt32(newEnd),
            start_point: point(forByteOffset: start, in: oldBytes),
            old_end_point: point(forByteOffset: oldEnd, in: oldBytes),
            new_end_point: point(forByteOffset: newEnd, in: newBytes)
        )
        let newSource = String(decoding: newBytes, as: UTF8.self)
        return (JavaParseEdit(rawValue: raw), newSource)
    }
}
