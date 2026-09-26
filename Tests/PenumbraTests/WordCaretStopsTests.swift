import XCTest
@testable import Penumbra

final class WordCaretStopsTests: XCTestCase {
    private func forwardStops(_ text: String, camelHumps: Bool = false) -> [Int] {
        let units = Array(text.utf16)
        var stops: [Int] = []
        var offset = 0
        while offset < units.count {
            offset = WordCaretStops.nextStop(in: units, from: offset, camelHumps: camelHumps)
            stops.append(offset)
        }
        return stops
    }

    private func backwardStops(_ text: String, camelHumps: Bool = false) -> [Int] {
        let units = Array(text.utf16)
        var stops: [Int] = []
        var offset = units.count
        while offset > 0 {
            offset = WordCaretStops.previousStop(in: units, from: offset, camelHumps: camelHumps)
            stops.append(offset)
        }
        return stops
    }

    func testPunctuationRunsAreWords() {
        XCTAssertEqual(forwardStops("foo.bar(baz)"), [3, 4, 7, 8, 11, 12])
        XCTAssertEqual(backwardStops("foo.bar(baz)"), [11, 8, 7, 4, 3, 0])
    }

    func testWhitespaceIsSkipped() {
        XCTAssertEqual(forwardStops("  x = y;"), [3, 5, 7, 8])
        XCTAssertEqual(backwardStops("  x = y;"), [7, 6, 4, 2, 0])
    }

    func testCamelHumps() {
        XCTAssertEqual(forwardStops("getHTTPResponse"), [15])
        XCTAssertEqual(forwardStops("getHTTPResponse", camelHumps: true), [3, 7, 15])
        XCTAssertEqual(backwardStops("getHTTPResponse", camelHumps: true), [7, 3, 0])
    }

    func testUnderscoreAndDollarSeparateHumpsOnlyWithCamelHumps() {
        XCTAssertEqual(forwardStops("snake_case"), [10])
        XCTAssertEqual(forwardStops("snake_case", camelHumps: true), [5, 10])
        XCTAssertEqual(forwardStops("$var"), [4])
        // `$` only starts a hump (IntelliJ's `isHumpBound`), so it matters going backward.
        XCTAssertEqual(backwardStops("$var"), [0])
        XCTAssertEqual(backwardStops("$var", camelHumps: true), [1, 0])
    }

    func testRepeatedPunctuationIsOneWord() {
        XCTAssertEqual(forwardStops("a -> b"), [1, 4, 6])
    }

    func testSurrogatePairIsNeverSplit() {
        let text = "a😀b c"
        let stops = forwardStops(text)
        XCTAssertEqual(stops, [4, 6])
    }
}
