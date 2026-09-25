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
