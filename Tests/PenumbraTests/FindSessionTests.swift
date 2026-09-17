import XCTest
@testable import Penumbra

@MainActor
final class FindSessionTests: XCTestCase {
    private func searched(_ session: FindSession, query: String, in text: String, anchor: Int = 0) {
        session.query = query
        let outcome = FindSearchEngine.search(options: session.searchOptions(), in: text, anchorLocation: anchor)
        session.applySearchOutcome(outcome)
    }

    func testMatchCountLabelReflectsState() {
        let session = FindSession()
        XCTAssertEqual(session.matchCountLabel, "")

        searched(session, query: "zzz", in: "abc")
        XCTAssertEqual(session.matchCountLabel, "No matches")

        searched(session, query: "a", in: "a b a")
        XCTAssertEqual(session.matchCountLabel, "1 of 2")
        XCTAssertTrue(session.isComplete)
    }

    func testMatchCountLabelShowsPlusWhileScanIsIncomplete() {
        let session = FindSession()
        session.query = "a"
        session.applySearchOutcome(FindSearchOutcome(
            matchCount: 47,
            currentIndex: 0,
            currentRange: NSRange(location: 0, length: 1),
            highlightRanges: [NSRange(location: 0, length: 1)],
            errorMessage: nil,
            isComplete: false
        ))
        XCTAssertEqual(session.matchCountLabel, "1 of 47+")
        XCTAssertFalse(session.isComplete)
    }

    func testMatchCountLabelSurfacesTheErrorMessage() {
        let session = FindSession()
        session.useRegex = true
        searched(session, query: "(unclosed", in: "text")
        XCTAssertNotNil(session.errorMessage)
        XCTAssertEqual(session.matchCountLabel, session.errorMessage)
    }

    func testShowFindAndShowReplaceSetReplaceMode() {
        let session = FindSession()
        session.showFind()
        XCTAssertTrue(session.isPresented)
        XCTAssertFalse(session.isReplaceMode)

        session.showReplace()
        XCTAssertTrue(session.isReplaceMode)
    }

    func testHideClearsHighlightsAndPresentation() {
        let session = FindSession()
        searched(session, query: "a", in: "a b a")
        session.hide()
        XCTAssertFalse(session.isPresented)
        XCTAssertEqual(session.matchCount, 0)
        XCTAssertNil(session.currentRange)
    }

    func testSelectNextWrapsAroundToTheFirstMatch() {
        let session = FindSession()
        let text = "a b a"
        searched(session, query: "a", in: text)
        XCTAssertEqual(session.currentIndex, 0)

        session.selectNext(in: text)
        XCTAssertEqual(session.currentIndex, 1)

        session.selectNext(in: text)
        XCTAssertEqual(session.currentIndex, 0, "Should wrap back to the first match")
    }

    func testSelectPreviousWrapsAroundToTheLastMatch() {
        let session = FindSession()
        let text = "a b a"
        searched(session, query: "a", in: text)
        XCTAssertEqual(session.currentIndex, 0)

        session.selectPrevious(in: text)
        XCTAssertEqual(session.currentIndex, 1, "Should wrap back to the last match")
    }

    func testReplaceCurrentReplacesAndReturnsNewSelection() {
        let session = FindSession()
        let text = "foo bar foo"
        searched(session, query: "foo", in: text)
        session.replacement = "BAZ"

        let result = session.replaceCurrent(in: text)
        XCTAssertEqual(result?.text, "BAZ bar foo")
        XCTAssertEqual(result?.selection, NSRange(location: 0, length: 3))
    }

    func testReplaceCurrentReturnsNilWithoutACurrentMatch() {
        let session = FindSession()
        XCTAssertNil(session.replaceCurrent(in: "anything"))
    }

    func testReplaceAllReplacesEveryMatch() {
        let session = FindSession()
        let text = "foo bar foo"
        searched(session, query: "foo", in: text)
        session.replacement = "BAZ"

        let result = session.replaceAll(in: text)
        XCTAssertEqual(result, "BAZ bar BAZ")
    }

    func testMatchesSnapshotComparesQueryAndOptions() {
        let session = FindSession()
        session.query = "foo"
        session.matchCase = true
        let snapshot = FindSession.SearchSnapshot(query: "foo", matchCase: true, wholeWord: false, useRegex: false)
        XCTAssertTrue(session.matchesSnapshot(snapshot))

        session.query = "bar"
        XCTAssertFalse(session.matchesSnapshot(snapshot))
    }

    func testCappedHighlightRangesCentersWindowAroundCurrentIndex() {
        let matches = (0 ..< 20).map { NSRange(location: $0, length: 1) }
        let capped = FindSession.cappedHighlightRanges(matches: matches, currentIndex: 10, maxCount: 4)
        XCTAssertEqual(capped.count, 4)
        XCTAssertTrue(capped.contains(NSRange(location: 10, length: 1)))
    }

    func testFindRangesEnumeratesEveryMatch() throws {
        let ranges = try FindSession.findRanges(query: "a", in: "a b a b a", matchCase: false, wholeWord: false, useRegex: false)
        XCTAssertEqual(ranges.count, 3)
    }

    func testFindRangesThrowsOnInvalidRegex() {
        XCTAssertThrowsError(try FindSession.findRanges(query: "(unclosed", in: "text", matchCase: false, wholeWord: false, useRegex: true))
    }

    func testFindRangesWithZeroLengthRegexTerminates() throws {
        let ranges = try FindSession.findRanges(query: "a*", in: "bbb", matchCase: false, wholeWord: false, useRegex: true)
        XCTAssertFalse(ranges.isEmpty)
        XCTAssertEqual(Set(ranges.map(\.location)).count, ranges.count)
    }

    func testSelectNextAndPreviousOnSourceWrapAround() {
        let session = FindSession()
        let text = "a b a"
        let source = StringFindTextSource(text)
        searched(session, query: "a", in: text)
        XCTAssertEqual(session.currentIndex, 0)

        session.selectNext(in: source)
        XCTAssertEqual(session.currentIndex, 1)
        session.selectNext(in: source)
        XCTAssertEqual(session.currentIndex, 0)

        session.selectPrevious(in: source)
        XCTAssertEqual(session.currentIndex, 1)
    }

    func testFindRangesOnSourceEnumeratesEveryMatch() throws {
        let source = StringFindTextSource("a b a b a")
        let ranges = try FindSession.findRanges(
            query: "a",
            in: source,
            matchCase: false,
            wholeWord: false,
            useRegex: false
        )
        XCTAssertEqual(ranges.count, 3)
    }

    func testFindRangesAndSelectNextOnFileBackedSourceDoNotMaterialize() async throws {
        let original = "foo bar foo"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try original.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        let state = try await TextViewState.load(contentsOf: url)
        let snapshot = try XCTUnwrap(state.stringView.contentSnapshot())
        let before = state.stringView.materializeCount

        let ranges = try FindSession.findRanges(
            query: "foo",
            in: snapshot,
            matchCase: false,
            wholeWord: false,
            useRegex: false
        )
        XCTAssertEqual(ranges.count, 2)

        let session = FindSession()
        searched(session, query: "foo", in: original)
        session.selectNext(in: snapshot)
        XCTAssertEqual(session.currentIndex, 1)
        session.selectPrevious(in: snapshot)
        XCTAssertEqual(session.currentIndex, 0)

        XCTAssertEqual(state.stringView.materializeCount, before)
        XCTAssertEqual(state.stringView.materializeCount, 0)
    }
}
