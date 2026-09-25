import Foundation
@testable import Penumbra
import PenumbraLanguages
import XCTest

/// `CaptureWindow.captures(overlapping:)` must equal the plain filter it replaced, order included
/// (a later capture paints over an earlier one).
final class CaptureWindowTests: XCTestCase {
    func testIndexedLookupMatchesFilterForEveryLineAndOddRanges() {
        var lines: [String] = ["package demo;", "", "import java.util.*;", ""]
        for index in 0 ..< 60 {
            lines += [
                "/** Doc \(index). */",
                "@Deprecated public class C\(index)<T extends Comparable<T>> {",
                "    private static final String NAME = \"c\(index)\"; // trailing",
                "    int f(int x) { return x * \(index) + NAME.length(); }",
                "}",
                ""
            ]
        }
        let source = lines.joined(separator: "\n")
        let stringView = StringView(string: source)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let mode = TreeSitterInternalLanguageMode(
            language: TreeSitterLanguage.java.internalLanguage,
            languageProvider: nil,
            stringView: stringView,
            lineManager: lineManager
        )
        mode.parse()
        let whole = ByteRange(location: ByteCount(0), length: stringView.byteCount)
        let captures = mode.captures(in: whole)
        XCTAssertGreaterThan(captures.count, 500)
        let window = CaptureWindow(range: whole, captures: captures)

        var ranges: [ByteRange] = []
        for row in 0 ..< lineManager.lineCount {
            let line = lineManager.line(atRow: row)
            ranges.append(ByteRange(location: line.data.startByte, length: line.data.byteCount))
        }
        let total = whole.length.value
        for start in stride(from: 0, to: total, by: 97) {
            for length in [0, 1, 2, 31, 400] {
                ranges.append(ByteRange(location: ByteCount(start), length: ByteCount(min(length, total - start))))
            }
        }
        ranges.append(whole)
        for range in ranges {
            let expected = captures.filter { $0.byteRange.overlaps(range) }
            let actual = window.captures(overlapping: range)
            XCTAssertEqual(actual.map(\.byteRange), expected.map(\.byteRange), "range \(range)")
            XCTAssertEqual(actual.map(\.name), expected.map(\.name), "range \(range)")
        }
    }
}
