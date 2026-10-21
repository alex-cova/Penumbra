import EditorIntelligence
import Foundation
import XCTest
@testable import JavaIntelligence

/// `JavaNavigationText` converts between UTF-16 offsets, UTF-8 offsets and line/column for every
/// definition hit. These compare it with the plain `NSString` walk it replaced, over text with
/// every kind of line break and characters outside the BMP.
final class JavaNavigationTextTests: XCTestCase {
    private let samples = [
        "",
        "class A {}",
        "a\nb\n\nc",
        "a\r\nb\rc\n\rd\r\n",
        "é = \"日本語\";\nint x = 1;\n",
        "emoji 😀 and 🇪🇸 then\r\nnext 😀😀\n",
        "\r",
        "\r\n\r\n"
    ]

    func testPositionMatchesTheNSStringWalkAtEveryOffset() {
        for sample in samples {
            let length = (sample as NSString).length
            for offset in -1 ... length + 1 {
                XCTAssertEqual(
                    JavaNavigationText.position(utf16Offset: offset, in: sample),
                    reference(utf16Offset: offset, in: sample),
                    "offset \(offset) in \(sample.debugDescription)"
                )
            }
        }
    }

    func testTextRangeMatchesTwoIndependentPositions() {
        for sample in samples {
            let bytes = Array(sample.utf8)
            let boundaries = (0 ... bytes.count).filter { $0 == bytes.count || bytes[$0] & 0xC0 != 0x80 }
            for lower in boundaries {
                for upper in boundaries where upper >= lower {
                    let range = JavaNavigationText.textRange(for: lower ..< upper, in: sample)
                    let expectedStart = reference(utf16Offset: utf16Offset(ofByte: lower, in: sample), in: sample)
                    let expectedEnd = reference(utf16Offset: utf16Offset(ofByte: upper, in: sample), in: sample)
                    XCTAssertEqual(range.start, expectedStart, "start \(lower) in \(sample.debugDescription)")
                    XCTAssertEqual(range.end, expectedEnd, "end \(upper) in \(sample.debugDescription)")
                }
            }
        }
    }

    func testUTF8ByteOffsetMatchesThePrefixCount() {
        for sample in samples {
            let ns = sample as NSString
            for offset in -1 ... ns.length + 1 {
                let clamped = max(0, min(offset, ns.length))
                // A split surrogate pair has no UTF-8 offset of its own.
                if clamped > 0, clamped < ns.length,
                   UTF16.isLeadSurrogate(ns.character(at: clamped - 1)) { continue }
                XCTAssertEqual(
                    JavaNavigationText.utf8ByteOffset(forUTF16Offset: offset, in: sample),
                    ns.substring(with: NSRange(location: 0, length: clamped)).utf8.count,
                    "offset \(offset) in \(sample.debugDescription)"
                )
            }
        }
    }

    private func utf16Offset(ofByte byte: Int, in sample: String) -> Int {
        String(decoding: Array(sample.utf8)[..<byte], as: UTF8.self).utf16.count
    }

    /// The implementation `position(utf16Offset:in:)` replaced.
    private func reference(utf16Offset: Int, in source: String) -> TextPosition {
        let ns = source as NSString
        let clamped = max(0, min(utf16Offset, ns.length))
        var line = 0
        var column = 0
        var index = 0
        while index < clamped {
            let unit = ns.character(at: index)
            if unit == 10 {
                line += 1
                column = 0
            } else if unit == 13 {
                line += 1
                column = 0
                if index + 1 < clamped && ns.character(at: index + 1) == 10 {
                    index += 1
                }
            } else {
                column += 1
            }
            index += 1
        }
        return TextPosition(line: line, column: column, utf16Offset: clamped)
    }
}
