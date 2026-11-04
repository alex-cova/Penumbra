@testable import Penumbra
import XCTest

final class UTF8DocumentScannerTests: XCTestCase {
    /// ASCII runs longer than the eight-byte fast path, broken by 2-, 3- and 4-byte scalars.
    private let sample = "let value = 42 // héllo wörld\n" + "→ arrow and 😀 emoji then plain ascii text again\n"
        + String(repeating: "abcdefgh", count: 5) + "ñ" + String(repeating: "x", count: 17) + "🎉end"

    func testAppendUTF16UnitsMatchesStringForEveryRange() {
        let units = Array(sample.utf16)
        let bytes = Array(sample.utf8)
        bytes.withUnsafeBytes { buffer in
            for start in stride(from: 0, to: units.count, by: 3) {
                for length in [1, 2, 7, 8, 9, 31, units.count - start] where start + length <= units.count {
                    var result: [unichar] = []
                    UTF8DocumentScanner.appendUTF16Units(from: buffer, utf16Offset: start, length: length, into: &result)
                    XCTAssertEqual(result, Array(units[start ..< start + length]), "start \(start) length \(length)")
                }
            }
        }
    }

    func testUTF8OffsetMatchesStringIndices() {
        let utf8 = Array(sample.utf8)
        utf8.withUnsafeBytes { buffer in
            var utf16 = 0
            for index in sample.unicodeScalars.indices {
                let expected = sample.utf8.distance(from: sample.utf8.startIndex, to: index)
                XCTAssertEqual(UTF8DocumentScanner.utf8Offset(forUTF16Offset: utf16, in: buffer), expected)
                utf16 += sample.unicodeScalars[index].utf16.count
            }
            XCTAssertEqual(UTF8DocumentScanner.utf8Offset(forUTF16Offset: utf16, in: buffer), utf8.count)
        }
    }
}

extension UTF8DocumentScannerTests {
    func testSingleUnitReadMatchesTheStringForEveryOffset() {
        let sample = "let value = 42 // héllo wörld\n→ arrow and 😀 emoji 🎉 then ascii abcdefgh abcdefgh ñ"
        let units = Array(sample.utf16)
        Array(sample.utf8).withUnsafeBytes { buffer in
            for offset in 0 ..< units.count {
                XCTAssertEqual(UTF8DocumentScanner.utf16Unit(from: buffer, utf16Offset: offset), units[offset], "offset \(offset)")
            }
            XCTAssertNil(UTF8DocumentScanner.utf16Unit(from: buffer, utf16Offset: units.count))
            XCTAssertNil(UTF8DocumentScanner.utf16Unit(from: buffer, utf16Offset: -1))
        }
    }

    /// Bytes `String(bytes:encoding:.utf8)` rejects append nothing through the range API, so the
    /// single-unit read answers nil for them as well.
    func testSingleUnitReadRejectsWhatTheRangeReadRejects() {
        let invalid: [[UInt8]] = [
            [0x80], [0xC0, 0x80], [0xC3], [0xE2, 0x86], [0xE0, 0x80, 0x80], [0xED, 0xA0, 0x80],
            [0xF0, 0x80, 0x80, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xF8, 0x80, 0x80, 0x80], [0xFF], [0xC3, 0x28]
        ]
        for bytes in invalid {
            bytes.withUnsafeBytes { buffer in
                var range: [unichar] = []
                UTF8DocumentScanner.appendUTF16Units(from: buffer, utf16Offset: 0, length: 2, into: &range)
                XCTAssertNil(UTF8DocumentScanner.utf16Unit(from: buffer, utf16Offset: 0), "\(bytes)")
                var single: [unichar] = []
                UTF8DocumentScanner.appendUTF16Units(from: buffer, utf16Offset: 0, length: 1, into: &single)
                XCTAssertTrue(single.isEmpty, "\(bytes)")
                XCTAssertTrue(range.isEmpty || bytes == [0xC3, 0x28], "\(bytes)")
            }
        }
    }
}
