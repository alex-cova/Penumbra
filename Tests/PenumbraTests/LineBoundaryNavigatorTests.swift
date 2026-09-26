import XCTest
@testable import Penumbra

final class LineBoundaryNavigatorTests: XCTestCase {
    /// `"    foo  "` at document offset 0.
    private let indented = LineBoundaryNavigator.Line(start: 0, contentEnd: 9, firstNonWhitespace: 4, lastNonWhitespaceEnd: 7)
    /// `"    "` at document offset 0.
    private let blank = LineBoundaryNavigator.Line(start: 0, contentEnd: 4, firstNonWhitespace: nil, lastNonWhitespaceEnd: nil)

    func testHomeGoesToFirstNonWhitespaceThenToColumnZero() {
        XCTAssertEqual(LineBoundaryNavigator.homeTarget(caret: 6, line: indented, fragmentStart: 0), 4)
        XCTAssertEqual(LineBoundaryNavigator.homeTarget(caret: 4, line: indented, fragmentStart: 0), 0)
        XCTAssertEqual(LineBoundaryNavigator.homeTarget(caret: 0, line: indented, fragmentStart: 0), 4)
    }

    func testHomeInsideIndentationGoesToColumnZero() {
        XCTAssertEqual(LineBoundaryNavigator.homeTarget(caret: 2, line: indented, fragmentStart: 0), 0)
    }

    func testHomeOnBlankLineTogglesBetweenColumnZeroAndIndentEnd() {
        XCTAssertEqual(LineBoundaryNavigator.homeTarget(caret: 0, line: blank, fragmentStart: 0), 4)
        XCTAssertEqual(LineBoundaryNavigator.homeTarget(caret: 4, line: blank, fragmentStart: 0), 0)
        XCTAssertEqual(LineBoundaryNavigator.homeTarget(caret: 2, line: blank, fragmentStart: 0), 0)
    }

    func testHomeOnWrappedRowGoesToRowStartThenToLineCode() {
        let wrapped = LineBoundaryNavigator.Line(start: 0, contentEnd: 60, firstNonWhitespace: 4, lastNonWhitespaceEnd: 60)
        XCTAssertEqual(LineBoundaryNavigator.homeTarget(caret: 25, line: wrapped, fragmentStart: 20), 20)
        XCTAssertEqual(LineBoundaryNavigator.homeTarget(caret: 20, line: wrapped, fragmentStart: 20), 4)
    }

    func testEndStopsBeforeTrailingWhitespaceFirst() {
        XCTAssertEqual(LineBoundaryNavigator.endTarget(caret: 0, line: indented, fragmentEnd: 9), 7)
        XCTAssertEqual(LineBoundaryNavigator.endTarget(caret: 7, line: indented, fragmentEnd: 9), 9)
    }

    func testEndWithoutTrailingWhitespaceGoesToLineEnd() {
        let line = LineBoundaryNavigator.Line(start: 10, contentEnd: 13, firstNonWhitespace: 10, lastNonWhitespaceEnd: 13)
        XCTAssertEqual(LineBoundaryNavigator.endTarget(caret: 10, line: line, fragmentEnd: 13), 13)
    }

    func testEndOnBlankLineGoesToLineEnd() {
        XCTAssertEqual(LineBoundaryNavigator.endTarget(caret: 0, line: blank, fragmentEnd: 4), 4)
    }

    func testEndOnEarlierWrappedRowGoesToRowEnd() {
        XCTAssertEqual(LineBoundaryNavigator.endTarget(caret: 0, line: indented, fragmentEnd: 5), 5)
    }
}
