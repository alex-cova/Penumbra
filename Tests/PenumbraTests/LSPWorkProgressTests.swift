import JSONRPC
import LanguageServerProtocol
import XCTest
@testable import EditorIntelligenceLSP

final class LSPWorkProgressTests: XCTestCase {
    private func progress(_ token: String, _ fields: [String: JSONValue]) -> ProgressParams {
        ProgressParams(token: .optionB(token), value: .hash(fields))
    }

    func testBeginReportAndEndFollowOneToken() {
        var tracker = LSPWorkProgressTracker()
        XCTAssertTrue(tracker.apply(progress("index", ["kind": .string("begin"), "title": .string("Indexing"), "percentage": .number(0)])))
        XCTAssertEqual(tracker.active.map(\.summary), ["Indexing (0%)"])

        XCTAssertTrue(tracker.apply(progress("index", ["kind": .string("report"), "message": .string("3/10"), "percentage": .number(30)])))
        XCTAssertEqual(tracker.active.map(\.summary), ["Indexing: 3/10 (30%)"])

        XCTAssertTrue(tracker.apply(progress("index", ["kind": .string("end")])))
        XCTAssertTrue(tracker.active.isEmpty)
    }

    func testAReportKeepsWhatItDoesNotMention() {
        var tracker = LSPWorkProgressTracker()
        _ = tracker.apply(progress("a", ["kind": .string("begin"), "title": .string("Preparing"), "message": .string("Foo"), "percentage": .number(10)]))
        _ = tracker.apply(progress("a", ["kind": .string("report"), "percentage": .number(55)]))
        XCTAssertEqual(tracker.active.first?.message, "Foo")
        XCTAssertEqual(tracker.active.first?.percentage, 55)
    }

    func testTwoTokensRunSideBySideInTheOrderTheyBegan() {
        var tracker = LSPWorkProgressTracker()
        _ = tracker.apply(progress("a", ["kind": .string("begin"), "title": .string("First")]))
        _ = tracker.apply(ProgressParams(token: .optionA(7), value: .hash(["kind": .string("begin"), "title": .string("Second")])))
        XCTAssertEqual(tracker.active.map(\.title), ["First", "Second"])
        _ = tracker.apply(progress("a", ["kind": .string("end")]))
        XCTAssertEqual(tracker.active.map(\.title), ["Second"])
        XCTAssertEqual(tracker.active.first?.token, "7")
    }

    func testNothingFollowsAnEndAndNoiseChangesNothing() {
        var tracker = LSPWorkProgressTracker()
        XCTAssertFalse(tracker.apply(progress("gone", ["kind": .string("report"), "percentage": .number(5)])), "a report for an unknown token")
        XCTAssertFalse(tracker.apply(progress("gone", ["kind": .string("end")])), "an end for an unknown token")
        XCTAssertFalse(tracker.apply(ProgressParams(token: .optionB("x"), value: nil)), "no value")
        XCTAssertFalse(tracker.apply(progress("x", ["kind": .string("unknown")])))
        XCTAssertFalse(tracker.apply(progress("x", ["title": .string("no kind")])))
        XCTAssertTrue(tracker.active.isEmpty)
    }

    func testARepeatedReportIsNotAChange() {
        var tracker = LSPWorkProgressTracker()
        _ = tracker.apply(progress("a", ["kind": .string("begin"), "title": .string("Indexing"), "percentage": .number(40)]))
        XCTAssertFalse(tracker.apply(progress("a", ["kind": .string("report"), "percentage": .number(40)])))
    }

    func testPercentagesAreClampedToAWholeNumberRange() {
        var tracker = LSPWorkProgressTracker()
        _ = tracker.apply(progress("a", ["kind": .string("begin"), "title": .string("T"), "percentage": .number(140.4)]))
        XCTAssertEqual(tracker.active.first?.percentage, 100)
        _ = tracker.apply(progress("a", ["kind": .string("report"), "percentage": .number(-3)]))
        XCTAssertEqual(tracker.active.first?.percentage, 0)
        _ = tracker.apply(progress("a", ["kind": .string("report"), "percentage": .number(.nan)]))
        XCTAssertEqual(tracker.active.first?.percentage, 0, "a NaN keeps the last good value")
    }
}
