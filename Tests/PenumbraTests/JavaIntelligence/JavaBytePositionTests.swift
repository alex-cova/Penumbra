import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// `JavaUTF8Offsets.position(ofByte:in:)` replaced three copies of "decode the prefix as a `String` and count
/// its `Character`s", which cost 7 ms (20,000 lines) to 44 ms (120,000) per position and ran several
/// times per `.` typed. The originals are kept here as the oracle for text where they were right (LF
/// line ends); CRLF has its own expectation, because they counted a `"\r\n"` grapheme as no line.
final class JavaBytePositionTests: XCTestCase {
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private func generated(_ generator: inout Generator, crlf: Bool, maxPieces: Int = 60) -> String {
        let breaks = crlf ? ["\r\n"] : ["\n"]
        let pieces = ["a", "foo", " ", "  ", "é", "日本", "😀", "x.y(", ")", ";"] + breaks + breaks
        return (0..<Int.random(in: 0...maxPieces, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined()
    }

    /// Scalar-aligned byte offsets of `text`.
    private func offsets(_ text: String) -> [Int] {
        var result: [Int] = []
        var bytes = 0
        for scalar in text.unicodeScalars {
            result.append(bytes)
            bytes += String(scalar).utf8.count
        }
        result.append(bytes)
        return result
    }

    // The original of `JavaCompletionProvider.commandItems`'s `position(ofByte:)`.
    private func originalCommandPosition(_ bytes: [UInt8], _ offset: Int) -> TextPosition {
        let prefix = String(decoding: bytes[0..<min(max(0, offset), bytes.count)], as: UTF8.self)
        let ns = prefix as NSString
        let line = prefix.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let lineStart = (ns.range(of: "\n", options: .backwards).location)
        let column = lineStart == NSNotFound ? ns.length : ns.length - (lineStart + 1)
        return TextPosition(line: line, column: column, utf16Offset: ns.length)
    }

    // The original of `JavaPostfixTemplates.position(ofByte:)`.
    private func originalPostfixPosition(_ bytes: [UInt8], _ offset: Int) -> TextPosition {
        let prefix = String(decoding: bytes[0..<min(offset, bytes.count)], as: UTF8.self)
        let utf16 = (prefix as NSString).length
        var line = 0
        var lineStart = prefix.startIndex
        for index in prefix.indices where prefix[index] == "\n" {
            line += 1
            lineStart = prefix.index(after: index)
        }
        return TextPosition(line: line, column: prefix[lineStart...].utf16.count, utf16Offset: utf16)
    }

    private func position(_ bytes: [UInt8], _ offset: Int) -> TextPosition {
        let found = bytes.withUnsafeBufferPointer { JavaUTF8Offsets.position(ofByte: offset, in: $0) }
        return TextPosition(line: found.line, column: found.column, utf16Offset: found.utf16Offset)
    }

    private func assertSame(_ a: TextPosition, _ b: TextPosition, _ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.line, b.line, "line: \(message())", file: file, line: line)
        XCTAssertEqual(a.column, b.column, "column: \(message())", file: file, line: line)
        XCTAssertEqual(a.utf16Offset, b.utf16Offset, "utf16Offset: \(message())", file: file, line: line)
    }

    func testMatchesTheOriginalsOnLFText() {
        var generator = Generator(state: 0xA051)
        for _ in 0..<600 {
            let text = generated(&generator, crlf: false)
            let bytes = Array(text.utf8)
            for offset in offsets(text) {
                let fast = position(bytes, offset)
                assertSame(fast, originalCommandPosition(bytes, offset), "command, offset \(offset) in \(text.debugDescription)")
                assertSame(fast, originalPostfixPosition(bytes, offset), "postfix, offset \(offset) in \(text.debugDescription)")
            }
        }
    }

    /// CRLF: every `\n` is a line, the column counts from after it, and the UTF-16 offset counts the `\r`.
    func testCRLFCountsEveryLineBreak() {
        var generator = Generator(state: 0xC21F)
        for _ in 0..<400 {
            let text = generated(&generator, crlf: true)
            let bytes = Array(text.utf8)
            for offset in offsets(text) {
                let prefix = String(decoding: bytes[0..<offset], as: UTF8.self)
                let expectedLine = bytes[0..<offset].filter { $0 == 0x0A }.count
                // On UTF-16 units, not `Character`s: the grapheme "\r\n" is not "\n".
                let units = Array(prefix.utf16)
                let lastBreak = units.lastIndex(of: 0x0A)
                let expectedColumn = lastBreak.map { units.count - ($0 + 1) } ?? units.count
                let found = position(bytes, offset)
                XCTAssertEqual(found.line, expectedLine, "line at \(offset) in \(text.debugDescription)")
                XCTAssertEqual(found.column, expectedColumn, "column at \(offset) in \(text.debugDescription)")
                XCTAssertEqual(found.utf16Offset, prefix.utf16.count, "UTF-16 offset at \(offset) in \(text.debugDescription)")
            }
        }
    }

    /// 32-byte blocks of ASCII are skipped; non-ASCII scalars in, before and after a block, and offsets on either side of one.
    func testLongTextAcrossBlockEdges() {
        var generator = Generator(state: 0xB10C)
        for _ in 0..<40 {
            var text = ""
            for _ in 0..<Int.random(in: 1...10, using: &generator) {
                text += String(repeating: "a", count: Int.random(in: 0...120, using: &generator))
                text += ["é", "日", "😀", "\n", "\r\n"].randomElement(using: &generator)!
            }
            let bytes = Array(text.utf8)
            for offset in offsets(text) {
                let prefix = String(decoding: bytes[0..<offset], as: UTF8.self)
                let found = position(bytes, offset)
                XCTAssertEqual(found.utf16Offset, prefix.utf16.count, "offset \(offset)")
                XCTAssertEqual(found.line, bytes[0..<offset].filter { $0 == 0x0A }.count, "line at \(offset)")
            }
        }
    }

    func testOffsetsOutsideTheTextAreClamped() {
        let bytes = Array("ab\ncd".utf8)
        assertSame(position(bytes, -3), TextPosition(line: 0, column: 0, utf16Offset: 0), "negative")
        assertSame(position(bytes, 999), TextPosition(line: 1, column: 2, utf16Offset: 5), "past the end")
        assertSame(position([], 0), TextPosition(line: 0, column: 0, utf16Offset: 0), "empty")
    }

    /// The import inserter's own conversion now goes through the helper and must keep answering as it did.
    func testImportInserterPositionStillAgrees() {
        var generator = Generator(state: 0x17E5)
        for _ in 0..<200 {
            let text = generated(&generator, crlf: Bool.random(using: &generator))
            let bytes = Array(text.utf8)
            for offset in offsets(text) {
                assertSame(JavaImportInserter.textPosition(forByteOffset: offset, in: bytes), position(bytes, offset), "offset \(offset)")
            }
        }
    }

    func testPositionMemoComputesEachOffsetOnce() {
        let bytes = Array("class A {\n  void m() {\n    user.\n  }\n}\n".utf8)
        let memo = JavaBytePositions(bytes: bytes)
        for offset in [10, 22, 33, 10, 22] {
            assertSame(memo.position(ofByte: offset), position(bytes, offset), "offset \(offset)")
        }
    }
}
