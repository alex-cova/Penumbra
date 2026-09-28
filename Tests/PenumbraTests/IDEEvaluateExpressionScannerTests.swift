import XCTest
@testable import Umbra

final class IDEEvaluateExpressionScannerTests: XCTestCase {
    /// The expression for a caret at `|` in `text`.
    private func atCaret(_ text: String) -> String? {
        let caret = (text as NSString).range(of: "|").location
        let clean = text.replacingOccurrences(of: "|", with: "")
        return IDEEvaluateExpressionScanner.expression(in: clean, selection: NSRange(location: caret, length: 0))
    }

    func testTheSelectionWinsAsWritten() {
        let text = "int total = a + b;"
        let range = (text as NSString).range(of: "a + b")
        XCTAssertEqual(IDEEvaluateExpressionScanner.expression(in: text, selection: range), "a + b")
    }

    func testAMultiLineOrBlankSelectionIsRefused() {
        let text = "a\nb  "
        XCTAssertNil(IDEEvaluateExpressionScanner.expression(in: text, selection: NSRange(location: 0, length: 3)))
        XCTAssertNil(IDEEvaluateExpressionScanner.expression(in: text, selection: NSRange(location: 3, length: 2)))
    }

    func testANameAtTheCaret() {
        XCTAssertEqual(atCaret("int x = coun|ter + 1;"), "counter")
        XCTAssertEqual(atCaret("int x = |counter + 1;"), "counter")
        XCTAssertEqual(atCaret("int x = counter| + 1;"), "counter")
    }

    func testTheChainLeadingToTheNameIsIncluded() {
        XCTAssertEqual(atCaret("use(p.next.la|bel);"), "p.next.label")
        XCTAssertEqual(atCaret("use(this.cou|nter);"), "this.counter")
    }

    func testOnlyTheNameUpToTheCaretWordIsTaken() {
        // The caret is in `next`, so `.label` after it is not part of the answer.
        XCTAssertEqual(atCaret("use(p.ne|xt.label);"), "p.next")
    }

    func testIndexedChains() {
        XCTAssertEqual(atCaret("use(items[i].na|me);"), "items[i].name")
        XCTAssertEqual(atCaret("use(grid[a[0]].le|ngth);"), "grid[a[0]].length")
    }

    func testACallBreaksTheChain() {
        XCTAssertEqual(atCaret("use(make().val|ue);"), "value")
    }

    func testNothingUnderThePunctuationOrAKeyword() {
        XCTAssertNil(atCaret("foo(|);"))
        XCTAssertNil(atCaret("   |   "))
        XCTAssertNil(atCaret("re|turn x;"))
    }

    func testANumberLiteralIsAnExpression() {
        XCTAssertEqual(atCaret("int x = 4|2;"), "42")
    }
}
