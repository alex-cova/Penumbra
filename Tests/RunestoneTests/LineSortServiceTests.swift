import XCTest
@testable import Runestone

/// Pure "sort lines" edit computation (command palette / Find Action).
final class LineSortServiceTests: XCTestCase {
    private func makeService(_ text: String) -> LineSortService {
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        return LineSortService(stringView: stringView, lineManager: lineManager, lineEndingSymbol: "\n")
    }

    private func applied(_ text: String, rows: ClosedRange<Int>, descending: Bool = false) -> String? {
        let service = makeService(text)
        guard let operation = service.sortOperation(forRows: rows, descending: descending) else {
            return nil
        }
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: operation.range, with: operation.replacement)
        return mutable as String
    }

    func testSortsAscendingByDefault() {
        XCTAssertEqual(applied("banana\napple\ncherry", rows: 0...2), "apple\nbanana\ncherry")
    }

    func testSortsDescendingWhenRequested() {
        XCTAssertEqual(applied("banana\napple\ncherry", rows: 0...2, descending: true), "cherry\nbanana\napple")
    }

    func testIsCaseSensitive() {
        // Uppercase sorts before lowercase in default Unicode/ASCII ordering.
        XCTAssertEqual(applied("banana\nApple", rows: 0...1), "Apple\nbanana")
    }

    func testSingleRowIsANoOp() {
        let service = makeService("only line")
        XCTAssertNil(service.sortOperation(forRows: 0...0, descending: false))
    }

    func testPreservesAbsenceOfATrailingNewlineOnTheFinalLine() {
        // No trailing "\n" after "cherry" in the input; the sorted block must not gain one.
        let result = applied("banana\napple\ncherry", rows: 0...2)
        XCTAssertEqual(result, "apple\nbanana\ncherry")
        XCTAssertFalse(result?.hasSuffix("\n") ?? true)
    }

    func testPreservesATrailingNewlineWhenTheBlockIsNotTheEndOfTheDocument() {
        let result = applied("banana\napple\ncherry\nafter", rows: 0...2)
        // The block (rows 0...2) still ends with a newline since row 2 wasn't the document's
        // final, unterminated line.
        XCTAssertEqual(result, "apple\nbanana\ncherry\nafter")
    }

    func testOnlySortsTheBlockLeavingSurroundingLinesInPlace() {
        XCTAssertEqual(applied("z\nbanana\napple\ncherry\na", rows: 1...3), "z\napple\nbanana\ncherry\na")
    }

    func testStableRelativeOrderIsNotGuaranteedButDuplicatesAreAllPreserved() {
        let result = applied("b\na\nb\na", rows: 0...3)
        XCTAssertEqual(result, "a\na\nb\nb")
    }

    func testOutOfBoundsRowRangeReturnsNil() {
        let service = makeService("only line")
        XCTAssertNil(service.sortOperation(forRows: 0...5, descending: false))
    }
}
