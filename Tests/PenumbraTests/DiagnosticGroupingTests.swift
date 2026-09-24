import XCTest
import EditorIntelligence

final class DiagnosticGroupingTests: XCTestCase {
    private func diagnostic(_ severity: DiagnosticSeverity, _ message: String, line: Int, column: Int = 0) -> Diagnostic {
        let position = TextPosition(line: line, column: column, utf16Offset: 0)
        return Diagnostic(severity: severity, message: message, range: EditorIntelligence.TextRange(start: position, end: position), source: "Test")
    }

    private let a = URL(fileURLWithPath: "/proj/A.java")
    private let b = URL(fileURLWithPath: "/proj/B.java")

    func testFilesSortedByPathAndRowsBySeverityThenPosition() {
        let files = DiagnosticGrouping.files(from: [[
            b: [diagnostic(.warning, "w", line: 1)],
            a: [
                diagnostic(.warning, "late warning", line: 9),
                diagnostic(.error, "late error", line: 8),
                diagnostic(.error, "early error", line: 2),
            ],
        ]])
        XCTAssertEqual(files.map(\.url), [a, b])
        XCTAssertEqual(files[0].rows.map(\.diagnostic.message), ["early error", "late error", "late warning"])
    }

    func testMergingSetsDropsDuplicatesWithFreshUUIDs() {
        let first = [a: [diagnostic(.error, "boom", line: 3, column: 4)]]
        let second = [a: [diagnostic(.error, "boom", line: 3, column: 4)]] // same content, different UUID
        let files = DiagnosticGrouping.files(from: [first, second])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].rows.count, 1)
    }

    func testSeverityFilterOmitsEmptyFiles() {
        let files = DiagnosticGrouping.files(
            from: [[a: [diagnostic(.warning, "w", line: 0)], b: [diagnostic(.error, "e", line: 0)]]],
            severities: [.error]
        )
        XCTAssertEqual(files.map(\.url), [b])
    }

    func testCounts() {
        let files = DiagnosticGrouping.files(from: [[
            a: [diagnostic(.error, "e1", line: 0), diagnostic(.error, "e2", line: 1), diagnostic(.warning, "w", line: 2)],
            b: [diagnostic(.hint, "h", line: 0)],
        ]])
        let counts = DiagnosticGrouping.counts(in: files)
        XCTAssertEqual(counts.errors, 2)
        XCTAssertEqual(counts.warnings, 1)
    }

    func testRowIdentityIsStableAcrossRuns() {
        let one = ProblemRow(url: a, diagnostic: diagnostic(.error, "boom", line: 1, column: 2))
        let two = ProblemRow(url: a, diagnostic: diagnostic(.error, "boom", line: 1, column: 2))
        XCTAssertEqual(one.id, two.id)
    }
}

final class ProblemLocatorTests: XCTestCase {
    private func range(_ l1: Int, _ c1: Int, _ l2: Int, _ c2: Int) -> EditorIntelligence.TextRange {
        EditorIntelligence.TextRange(start: TextPosition(line: l1, column: c1, utf16Offset: -1), end: TextPosition(line: l2, column: c2, utf16Offset: -1))
    }

    func testResolvesLineAndColumnIgnoringProviderOffset() {
        let text = "class A {\n  int x;\n}\n"
        // "x" on line 1 (0-based), column 6.
        let result = ProblemLocator.nsRange(for: range(1, 6, 1, 7), in: text)
        XCTAssertEqual((text as NSString).substring(with: result), "x")
    }

    func testHandlesCRLFAndClampsColumnToLineEnd() {
        let text = "ab\r\ncd\r\nef"
        let result = ProblemLocator.nsRange(for: range(1, 0, 1, 99), in: text)
        XCTAssertEqual((text as NSString).substring(with: result), "cd")
    }

    func testCountsUTF16ColumnsForSurrogatePairs() {
        let text = "😀 x"
        let result = ProblemLocator.nsRange(for: range(0, 3, 0, 4), in: text)
        XCTAssertEqual((text as NSString).substring(with: result), "x")
    }

    func testLineBeyondEndClampsToTextEnd() {
        let text = "one\ntwo"
        let result = ProblemLocator.nsRange(for: range(9, 0, 9, 0), in: text)
        XCTAssertEqual(result, NSRange(location: 7, length: 0))
    }
}
