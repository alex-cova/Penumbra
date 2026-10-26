import XCTest
@testable import Umbra

/// CSV/TSV text becomes a table: quoting, line breaks, padding, delimiter detection and the row cap.
final class IDECSVTableTests: XCTestCase {
    func testPlainRecordsWithHeader() {
        let table = IDECSVTable.parse("a,b,c\n1,2,3\n4,5,6\n", delimiter: ",")
        XCTAssertEqual(table.header, ["a", "b", "c"])
        XCTAssertEqual(table.rows, [["1", "2", "3"], ["4", "5", "6"]])
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertEqual(table.sourceLines, [1, 2])
        XCTAssertFalse(table.isTruncated)
    }

    func testQuotedFieldsHoldDelimitersQuotesAndLineBreaks() {
        let text = "name,note\n\"Smith, J\",\"said \"\"hi\"\"\"\n\"multi\nline\",x\nlast,y"
        let table = IDECSVTable.parse(text, delimiter: ",")
        XCTAssertEqual(table.rows[0], ["Smith, J", "said \"hi\""])
        XCTAssertEqual(table.rows[1], ["multi\nline", "x"])
        XCTAssertEqual(table.rows[2], ["last", "y"])
        // The record after a multi-line field starts on the buffer's line 4, not 3.
        XCTAssertEqual(table.sourceLines, [1, 2, 4])
    }

    func testCRLFAndLoneCarriageReturn() {
        let table = IDECSVTable.parse("a,b\r\n1,2\r3,4\r\n", delimiter: ",")
        XCTAssertEqual(table.rows, [["1", "2"], ["3", "4"]])
    }

    func testBlankLinesAndTrailingNewlineAddNoRows() {
        let table = IDECSVTable.parse("a,b\n\n1,2\n\n\n", delimiter: ",")
        XCTAssertEqual(table.rows, [["1", "2"]])
    }

    func testRaggedRowsArePaddedToTheWidest() {
        let table = IDECSVTable.parse("a\n1,2,3\n4\n", delimiter: ",")
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertEqual(table.header, ["a", "", ""])
        XCTAssertEqual(table.rows, [["1", "2", "3"], ["4", "", ""]])
    }

    func testEmptyAndHeaderOnly() {
        XCTAssertEqual(IDECSVTable.parse("", delimiter: ","), .empty)
        let headerOnly = IDECSVTable.parse("a,b", delimiter: ",")
        XCTAssertEqual(headerOnly.header, ["a", "b"])
        XCTAssertTrue(headerOnly.rows.isEmpty)
    }

    func testEmptyQuotedFieldIsARecordNotABlankLine() {
        let table = IDECSVTable.parse("a\n\"\"\n", delimiter: ",")
        XCTAssertEqual(table.rows, [[""]])
    }

    func testNonASCIIText() {
        let table = IDECSVTable.parse("ciudad,país\nMálaga,España\n東京,日本", delimiter: ",")
        XCTAssertEqual(table.rows, [["Málaga", "España"], ["東京", "日本"]])
    }

    func testDelimiterDetection() {
        XCTAssertEqual(IDECSVTable.delimiter(forIdentifier: "csv", sample: "a,b,c\n"), ",")
        XCTAssertEqual(IDECSVTable.delimiter(forIdentifier: "csv", sample: "a;b;c\n1,5;2;3"), ";")
        XCTAssertEqual(IDECSVTable.delimiter(forIdentifier: "csv", sample: "\"a;b\",c\n"), ",")
        XCTAssertEqual(IDECSVTable.delimiter(forIdentifier: "csv", sample: "abc"), ",")
        XCTAssertEqual(IDECSVTable.delimiter(forIdentifier: "tsv", sample: "a,b\tc"), "\t")
    }

    func testTabSeparated() {
        let table = IDECSVTable.parse("a\tb\n1,5\t2\n", delimiter: "\t")
        XCTAssertEqual(table.rows, [["1,5", "2"]])
    }

    func testRowCapTruncates() {
        let rows = IDECSVTable.maximumRows + 10
        let text = "n\n" + (0..<rows).map(String.init).joined(separator: "\n")
        let table = IDECSVTable.parse(text, delimiter: ",")
        XCTAssertTrue(table.isTruncated)
        XCTAssertEqual(table.rows.count, IDECSVTable.maximumRows)
        XCTAssertEqual(table.rows.last, [String(IDECSVTable.maximumRows - 1)])
    }

    func testLanguageIdentifierKnowsCSVAndTSV() {
        XCTAssertEqual(IDELanguageSupport.displayName(forIdentifier: "csv"), "CSV")
        XCTAssertEqual(IDELanguageSupport.displayName(forIdentifier: "tsv"), "TSV")
    }
}
