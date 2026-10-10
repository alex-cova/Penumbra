import EditorIntelligence
import Foundation

/// UTF-8 bytes of one TypeScript buffer and the line starts that turn tree-sitter's byte offsets
/// into UTF-16 positions. Built in one pass so a later lookup is a binary search plus one line.
struct TypeScriptText: Sendable {
    let source: String
    let utf8: [UInt8]
    let utf16Length: Int
    private let lineStarts: [(byte: Int, utf16: Int)]

    init(_ source: String) {
        self.source = source
        utf8 = Array(source.utf8)
        let ns = source as NSString
        let length = ns.length
        var byte = 0
        var utf16 = 0
        var lines: [(byte: Int, utf16: Int)] = [(0, 0)]
        while utf16 < length {
            let unit = ns.character(at: utf16)
            if unit == 0x0D {
                let crlf = utf16 + 1 < length && ns.character(at: utf16 + 1) == 0x0A
                utf16 += crlf ? 2 : 1
                byte += crlf ? 2 : 1
                lines.append((byte, utf16))
            } else if unit == 0x0A {
                utf16 += 1
                byte += 1
                lines.append((byte, utf16))
            } else if unit >= 0xD800 && unit <= 0xDBFF {
                utf16 += 2
                byte += 4
            } else if unit < 0x80 {
                utf16 += 1
                byte += 1
            } else if unit < 0x800 {
                utf16 += 1
                byte += 2
            } else {
                utf16 += 1
                byte += 3
            }
        }
        utf16Length = length
        lineStarts = lines
    }

    func text(bytes: Range<Int>) -> String {
        let lower = max(0, min(bytes.lowerBound, utf8.count))
        let upper = max(lower, min(bytes.upperBound, utf8.count))
        return String(decoding: utf8[lower..<upper], as: UTF8.self)
    }

    func position(atByte byte: Int) -> TextPosition {
        let byte = max(0, min(byte, utf8.count))
        let lineIndex = lineIndex(byte: byte)
        let line = lineStarts[lineIndex]
        let utf16 = utf16Offset(onLine: line, byte: byte)
        return TextPosition(line: lineIndex, column: utf16 - line.utf16, utf16Offset: utf16)
    }

    func position(utf16: Int) -> TextPosition {
        position(atByte: byteOffset(utf16: utf16))
    }

    func byteOffset(utf16 target: Int) -> Int {
        let target = max(0, min(target, utf16Length))
        let lineIndex = lineIndex(utf16: target)
        let line = lineStarts[lineIndex]
        return byteOffset(onLine: line, utf16: target)
    }

    func range(bytes: Range<Int>) -> EditorIntelligence.TextRange {
        EditorIntelligence.TextRange(start: position(atByte: bytes.lowerBound), end: position(atByte: bytes.upperBound))
    }

    func utf16Range(bytes: Range<Int>) -> Range<Int> {
        let start = position(atByte: bytes.lowerBound).utf16Offset
        let end = position(atByte: bytes.upperBound).utf16Offset
        return start..<max(start, end)
    }

    /// The line holding `offset`, without its line break, and the identifier's column on that line.
    func lineContents(containingUTF16 offset: Int) -> (text: String, line: Int, column: Int) {
        let clamped = max(0, min(offset, utf16Length))
        let lineIndex = lineIndex(utf16: clamped)
        let start = lineStarts[lineIndex].utf16
        let endBound = lineIndex + 1 < lineStarts.count ? lineStarts[lineIndex + 1].utf16 : utf16Length
        let ns = source as NSString
        var end = endBound
        if end > start {
            let last = ns.character(at: end - 1)
            if last == 0x0A {
                end -= 1
                if end > start && ns.character(at: end - 1) == 0x0D { end -= 1 }
            } else if last == 0x0D {
                end -= 1
            }
        }
        let text = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
        return (text, lineIndex, clamped - start)
    }

    private func lineIndex(byte: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid].byte <= byte { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func lineIndex(utf16: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid].utf16 <= utf16 { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func utf16Offset(onLine line: (byte: Int, utf16: Int), byte target: Int) -> Int {
        let ns = source as NSString
        var byte = line.byte
        var utf16 = line.utf16
        while byte < target && utf16 < utf16Length {
            let (units, bytes) = step(ns.character(at: utf16), at: utf16, ns: ns)
            if byte + bytes > target { break }
            byte += bytes
            utf16 += units
        }
        return utf16
    }

    private func byteOffset(onLine line: (byte: Int, utf16: Int), utf16 target: Int) -> Int {
        let ns = source as NSString
        var byte = line.byte
        var utf16 = line.utf16
        while utf16 < target && utf16 < utf16Length {
            let (units, bytes) = step(ns.character(at: utf16), at: utf16, ns: ns)
            utf16 += units
            byte += bytes
        }
        return byte
    }

    private func step(_ unit: unichar, at utf16: Int, ns: NSString) -> (units: Int, bytes: Int) {
        if unit == 0x0D {
            let crlf = utf16 + 1 < ns.length && ns.character(at: utf16 + 1) == 0x0A
            return (crlf ? 2 : 1, crlf ? 2 : 1)
        }
        if unit == 0x0A { return (1, 1) }
        if unit >= 0xD800 && unit <= 0xDBFF { return (2, 4) }
        if unit < 0x80 { return (1, 1) }
        if unit < 0x800 { return (1, 2) }
        return (1, 3)
    }
}
