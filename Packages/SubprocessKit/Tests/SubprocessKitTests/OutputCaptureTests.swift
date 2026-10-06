import Foundation
import XCTest
@testable import SubprocessKit

final class OutputCaptureTests: XCTestCase {
    func testKeepsEverythingUnderTheLimits() {
        var output = OutputBuffer(.bounded(head: 10, tail: 10))
        output.append(Data("hello ".utf8))
        output.append(Data("world".utf8))
        XCTAssertEqual(output.captured.text, "hello world")
        XCTAssertEqual(output.omitted, 0)
    }

    func testDropsTheMiddleAndCountsIt() {
        var output = OutputBuffer(.bounded(head: 5, tail: 5))
        output.append(Data("AAAAA".utf8))
        output.append(Data("middle-part-".utf8))
        output.append(Data("ZZZZZ".utf8))
        let text = output.captured.text
        XCTAssertTrue(text.hasPrefix("AAAAA"))
        XCTAssertTrue(text.hasSuffix("ZZZZZ"))
        XCTAssertEqual(output.omitted, 12)
        XCTAssertTrue(text.contains("12 bytes omitted"))
    }

    func testATailOnlyCaptureKeepsTheEnd() {
        var output = OutputBuffer(.bounded(head: 0, tail: 4))
        output.append(Data("abcdefgh".utf8))
        XCTAssertEqual(output.captured.text, "\n[… 4 bytes omitted …]\nefgh")
        XCTAssertEqual(output.captured.data, Data("efgh".utf8))
    }

    func testAllKeepsEverythingWithoutAMarker() {
        var output = OutputBuffer(.all)
        for _ in 0..<100 { output.append(Data(repeating: 0x61, count: 1_000)) }
        XCTAssertEqual(output.captured.data.count, 100_000)
        XCTAssertEqual(output.omitted, 0)
        XCTAssertFalse(output.captured.text.contains("omitted"))
    }

    func testDiscardKeepsNothingAndCountsTheBytes() {
        var output = OutputBuffer(.discard)
        output.append(Data("abc".utf8))
        XCTAssertTrue(output.captured.isEmpty)
        XCTAssertEqual(output.omitted, 3)
    }
}
