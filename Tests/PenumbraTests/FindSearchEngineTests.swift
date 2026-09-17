import XCTest
@testable import Penumbra

final class FindSearchEngineTests: XCTestCase {
    func testLiteralSearchCountsAllMatchesCaseInsensitiveByDefault() {
        let options = FindSearchOptions(query: "foo")
        let outcome = FindSearchEngine.search(options: options, in: "foo Foo FOO bar", anchorLocation: 0)
        XCTAssertEqual(outcome.matchCount, 3)
        XCTAssertEqual(outcome.currentIndex, 0)
        XCTAssertEqual(outcome.currentRange, NSRange(location: 0, length: 3))
    }

    func testMatchCaseTrueMakesSearchCaseSensitive() {
        let options = FindSearchOptions(query: "foo", matchCase: true)
        let outcome = FindSearchEngine.search(options: options, in: "foo Foo FOO", anchorLocation: 0)
        XCTAssertEqual(outcome.matchCount, 1)
    }

    func testAnchorPicksTheFirstMatchAtOrAfterTheAnchorLocation() {
        // Matches "aa" at locations 0, 3, and 6. Anchored at 4, the match at 3 is before the
        // anchor and should be skipped in favor of the next one at 6.
        let text = "aa aa aa"
        let options = FindSearchOptions(query: "aa")
        let outcome = FindSearchEngine.search(options: options, in: text, anchorLocation: 4)
        XCTAssertEqual(outcome.currentIndex, 2)
        XCTAssertEqual(outcome.currentRange, NSRange(location: 6, length: 2))
    }

    func testAnchorPastAllMatchesWrapsToTheFirstMatch() {
        let text = "aa bb"
        let options = FindSearchOptions(query: "aa")
        let outcome = FindSearchEngine.search(options: options, in: text, anchorLocation: 100)
        XCTAssertEqual(outcome.currentIndex, 0)
        XCTAssertEqual(outcome.currentRange, NSRange(location: 0, length: 2))
    }

    /// Confirms the scan loop itself checks `Task.isCancelled` (PERFORMANCE_AUDIT.md Phase 3,
    /// "cancellation") rather than only relying on the caller to discard a completed result — a
    /// stale search over a huge document should stop scanning, not just have its answer ignored.
    /// `task.cancel()` runs synchronously right after the task is created, before the task's body
    /// (which does no `await` of its own before calling into `FindSearchEngine`) has a chance to
    /// start, so this reliably exercises the mid-scan cancellation path rather than racing it.
    func testLiteralSearchStopsScanningOnceCancelled() async {
        let text = String(repeating: "needle ", count: 100_000)
        let options = FindSearchOptions(query: "needle")
        let task = Task {
            FindSearchEngine.search(options: options, in: text, anchorLocation: 0)
        }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .empty)
    }

    func testRegexSearchStopsScanningOnceCancelled() async {
        let text = String(repeating: "needle ", count: 100_000)
        let options = FindSearchOptions(query: "nee.le", useRegex: true)
        let task = Task {
            FindSearchEngine.search(options: options, in: text, anchorLocation: 0)
        }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .empty)
    }

    func testEmptyQueryReturnsEmptyOutcome() {
        let outcome = FindSearchEngine.search(options: FindSearchOptions(query: ""), in: "anything", anchorLocation: 0)
        XCTAssertEqual(outcome, .empty)
    }

    func testSearchProgressReportsIncompleteOutcomesThenACompleteResult() {
        let text = String(repeating: "needle ", count: 200)
        let options = FindSearchOptions(query: "needle")
        let partials = ProgressBox()
        let outcome = FindSearchEngine.search(options: options, in: text, anchorLocation: 0) { partial in
            partials.values.append(partial)
        }
        XCTAssertFalse(partials.values.isEmpty, "first match should emit a progress snapshot")
        XCTAssertTrue(partials.values.allSatisfy { !$0.isComplete })
        XCTAssertTrue(partials.values.allSatisfy { $0.matchCount > 0 })
        XCTAssertTrue(outcome.isComplete)
        XCTAssertEqual(outcome.matchCount, 200)
        XCTAssertGreaterThanOrEqual(outcome.matchCount, partials.values.last?.matchCount ?? 0)
    }

    func testRegexSearchProgressReportsIncompleteOutcomes() {
        let text = String(repeating: "needle ", count: 80)
        let options = FindSearchOptions(query: "nee.le", useRegex: true)
        let partials = ProgressBox()
        let outcome = FindSearchEngine.search(options: options, in: text, anchorLocation: 0) { partial in
            partials.values.append(partial)
        }
        XCTAssertFalse(partials.values.isEmpty)
        XCTAssertTrue(partials.values.allSatisfy { !$0.isComplete })
        XCTAssertTrue(outcome.isComplete)
        XCTAssertEqual(outcome.matchCount, 80)
    }

    func testCancelledSearchStillReturnsEmptyEvenWithProgressCallback() async {
        let text = String(repeating: "needle ", count: 100_000)
        let options = FindSearchOptions(query: "needle")
        let task = Task {
            FindSearchEngine.search(options: options, in: text, anchorLocation: 0, onProgress: { _ in })
        }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .empty)
        XCTAssertTrue(outcome.isComplete)
    }

    func testNoMatchesReturnsEmptyOutcome() {
        let outcome = FindSearchEngine.search(options: FindSearchOptions(query: "zzz"), in: "abc", anchorLocation: 0)
        XCTAssertEqual(outcome, .empty)
    }

    func testWholeWordDoesNotMatchInsideALongerWord() {
        let options = FindSearchOptions(query: "cat", wholeWord: true)
        let outcome = FindSearchEngine.search(options: options, in: "cat category cat", anchorLocation: 0)
        XCTAssertEqual(outcome.matchCount, 2)
    }

    func testRegexSearchMatchesPattern() {
        let options = FindSearchOptions(query: "[0-9]+", useRegex: true)
        let outcome = FindSearchEngine.search(options: options, in: "abc 123 def 456", anchorLocation: 0)
        XCTAssertEqual(outcome.matchCount, 2)
        XCTAssertEqual(outcome.currentRange, NSRange(location: 4, length: 3))
    }

    func testRegexCaretMatchesEachLine() {
        let options = FindSearchOptions(query: "^", useRegex: true)
        let outcome = FindSearchEngine.search(options: options, in: "a\nb\nc", anchorLocation: 0)
        XCTAssertEqual(outcome.matchCount, 3)
        XCTAssertEqual(outcome.currentRange, NSRange(location: 0, length: 0))
    }

    func testReplacementTextExpandsCaptureGroups() throws {
        let options = FindSearchOptions(query: #"(\w+)=(\w+)"#, useRegex: true)
        let text = try FindSearchEngine.replacementText(
            options: options,
            in: "a=b",
            matching: NSRange(location: 0, length: 3),
            replacement: "$2=$1"
        )
        XCTAssertEqual(text, "b=a")
    }

    func testInvalidRegexSurfacesAnErrorMessageInsteadOfCrashingOrSilentlyEmpty() {
        let options = FindSearchOptions(query: "(unclosed", useRegex: true)
        let outcome = FindSearchEngine.search(options: options, in: "text", anchorLocation: 0)
        XCTAssertNotNil(outcome.errorMessage)
        XCTAssertEqual(outcome.matchCount, 0)
    }

    func testFindNextAdvancesPastCurrentMatch() {
        let options = FindSearchOptions(query: "a")
        let next = FindSearchEngine.findNext(options: options, in: "a b a", after: 1)
        XCTAssertEqual(next, NSRange(location: 4, length: 1))
    }

    func testFindNextReturnsNilWhenNothingAfterLocation() {
        let options = FindSearchOptions(query: "a")
        XCTAssertNil(FindSearchEngine.findNext(options: options, in: "a b", after: 3))
    }

    func testFindPreviousReturnsLastMatchBeforeLocation() {
        let options = FindSearchOptions(query: "a")
        let previous = FindSearchEngine.findPrevious(options: options, in: "a b a b a", before: 8)
        XCTAssertEqual(previous, NSRange(location: 4, length: 1))
    }

    func testHighlightRangesAreWindowedAroundTheCurrentMatch() {
        let text = String(repeating: "a", count: 300)
        let options = FindSearchOptions(query: "a")
        let outcome = FindSearchEngine.search(options: options, in: text, anchorLocation: 150, maxHighlights: 10)
        XCTAssertEqual(outcome.matchCount, 300)
        XCTAssertEqual(outcome.highlightRanges.count, 10)
    }

    func testReplaceAllLiteral() throws {
        let result = try FindSearchEngine.replaceAll(options: FindSearchOptions(query: "foo"), in: "foo bar foo", replacement: "baz")
        XCTAssertEqual(result, "baz bar baz")
    }

    func testReplaceAllRegexSupportsCaptureGroupTemplates() throws {
        let options = FindSearchOptions(query: "(\\w+)@(\\w+)", useRegex: true)
        let result = try FindSearchEngine.replaceAll(options: options, in: "user@host", replacement: "$2:$1")
        XCTAssertEqual(result, "host:user")
    }

    func testReplaceAllThrowsOnInvalidRegex() {
        let options = FindSearchOptions(query: "(unclosed", useRegex: true)
        XCTAssertThrowsError(try FindSearchEngine.replaceAll(options: options, in: "text", replacement: "x"))
    }

    func testReplaceAllMatchesLiteralReturnsPerMatchRanges() throws {
        let options = FindSearchOptions(query: "foo")
        let matches = try FindSearchEngine.replaceAllMatches(options: options, in: "foo bar foo", replacement: "baz")
        XCTAssertEqual(matches, [
            FindReplaceMatch(range: NSRange(location: 0, length: 3), replacementText: "baz"),
            FindReplaceMatch(range: NSRange(location: 8, length: 3), replacementText: "baz")
        ])
    }

    func testReplaceAllMatchesExpandsVSCodeCaptureGroups() throws {
        let options = FindSearchOptions(query: "(\\w+)@(\\w+)", useRegex: true)
        let matches = try FindSearchEngine.replaceAllMatches(
            options: options,
            in: "user@host",
            replacement: "$2:$1"
        )
        XCTAssertEqual(matches, [
            FindReplaceMatch(range: NSRange(location: 0, length: 9), replacementText: "host:user")
        ])
    }

    func testReplaceAllMatchesAppliesUppercaseModifier() throws {
        let options = FindSearchOptions(query: "hello (world)", useRegex: true)
        let matches = try FindSearchEngine.replaceAllMatches(
            options: options,
            in: "hello world",
            replacement: #"\u$1"#
        )
        XCTAssertEqual(matches, [
            FindReplaceMatch(range: NSRange(location: 0, length: 11), replacementText: "World")
        ])
    }

    func testReplaceAllMatchesStopsScanningOnceCancelled() async {
        let text = String(repeating: "needle ", count: 100_000)
        let options = FindSearchOptions(query: "needle")
        let task = Task {
            try FindSearchEngine.replaceAllMatches(options: options, in: text, replacement: "x")
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled replace-all should throw CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - SearchQuery bridging

    func testFindSearchOptionsFromSearchQueryMapsFullWordAndRegularExpression() {
        let fullWord = SearchQuery(text: "foo", matchMethod: .fullWord, isCaseSensitive: true)
        let options = FindSearchOptions(fullWord)
        XCTAssertEqual(options.query, "foo")
        XCTAssertTrue(options.matchCase)
        XCTAssertTrue(options.wholeWord)
        XCTAssertFalse(options.useRegex)

        let regex = SearchQuery(text: "f.o", matchMethod: .regularExpression)
        XCTAssertTrue(FindSearchOptions(regex).useRegex)
    }

    func testFindSearchOptionsFromSearchQueryCollapsesStartsAndEndsWithToContains() {
        let startsWith = SearchQuery(text: "foo", matchMethod: .startsWith)
        let options = FindSearchOptions(startsWith)
        XCTAssertFalse(options.wholeWord)
        XCTAssertFalse(options.useRegex)
    }

    func testFindSearchOptionsToSearchQueryRoundTrips() {
        let options = FindSearchOptions(query: "foo", matchCase: true, wholeWord: true, useRegex: false)
        let query = options.searchQuery
        XCTAssertEqual(query.text, "foo")
        XCTAssertEqual(query.matchMethod, .fullWord)
        XCTAssertTrue(query.isCaseSensitive)
    }

    func testLiteralWindowConstants() {
        XCTAssertEqual(FindSearchEngine.literalWindowUTF16, 64 * 1024)
        XCTAssertEqual(FindSearchEngine.regexWindowUTF16, 1_048_576)
        XCTAssertEqual(FindSearchEngine.regexOverlapUTF16, 64 * 1024)
        XCTAssertEqual(FindSearchEngine.literalCaseInsensitiveOverlapUTF16("ß"), 16)
        XCTAssertEqual(FindSearchEngine.literalCaseInsensitiveOverlapUTF16(String(repeating: "a", count: 10)), 30)
    }

    func testSourceOverloadAgreesWithStringForLiteral() {
        let text = "foo Foo FOO bar"
        let options = FindSearchOptions(query: "foo")
        let fromString = FindSearchEngine.search(options: options, in: text, anchorLocation: 0)
        let fromSource = FindSearchEngine.search(options: options, in: StringFindTextSource(text), anchorLocation: 0)
        XCTAssertEqual(fromString, fromSource)
        XCTAssertEqual(
            FindSearchEngine.findNext(options: options, in: text, after: 1),
            FindSearchEngine.findNext(options: options, in: StringFindTextSource(text), after: 1)
        )
        XCTAssertEqual(
            FindSearchEngine.findPrevious(options: options, in: text, before: 8),
            FindSearchEngine.findPrevious(options: options, in: StringFindTextSource(text), before: 8)
        )
    }

    func testSourceOverloadRegexOnContiguousStringStillWorks() {
        let source = StringFindTextSource("abc 123 def 456")
        let outcome = FindSearchEngine.search(
            options: FindSearchOptions(query: "[0-9]+", useRegex: true),
            in: source,
            anchorLocation: 0
        )
        XCTAssertNil(outcome.errorMessage)
        XCTAssertEqual(outcome.matchCount, 2)
        XCTAssertEqual(outcome.currentRange, NSRange(location: 4, length: 3))
    }

    func testRegexOnNonContiguousSourceWindowsWithoutContiguousString() throws {
        let source = RecordingFindTextSource(string: String(repeating: "needle ", count: 1_000))
        let regex = FindSearchOptions(query: "nee.le", useRegex: true)
        let outcome = FindSearchEngine.search(options: regex, in: source, anchorLocation: 0)
        XCTAssertNil(outcome.errorMessage)
        XCTAssertEqual(outcome.matchCount, 1_000)
        XCTAssertEqual(outcome.currentRange, NSRange(location: 0, length: 6))
        XCTAssertGreaterThan(source.substringCallCount, 0)

        let wholeWord = FindSearchEngine.search(
            options: FindSearchOptions(query: "needle", wholeWord: true),
            in: source,
            anchorLocation: 0
        )
        XCTAssertNil(wholeWord.errorMessage)
        XCTAssertEqual(wholeWord.matchCount, 1_000)

        XCTAssertEqual(
            FindSearchEngine.findNext(options: regex, in: source, after: 0),
            NSRange(location: 0, length: 6)
        )
        XCTAssertEqual(
            FindSearchEngine.findPrevious(options: regex, in: source, before: source.utf16Length),
            NSRange(location: source.utf16Length - 7, length: 6)
        )
        let matches = try FindSearchEngine.replaceAllMatches(options: regex, in: source, replacement: "x")
        XCTAssertEqual(matches.count, 1_000)
        let expanded = try FindSearchEngine.replacementText(
            options: regex,
            in: source,
            matching: NSRange(location: 0, length: 6),
            replacement: "$0"
        )
        XCTAssertEqual(expanded, "needle")
        XCTAssertNil(source.contiguousNSString)
    }
}

private final class RecordingFindTextSource: FindTextSource, @unchecked Sendable {
    let string: String
    private(set) var substringCallCount = 0

    init(string: String) {
        self.string = string
    }

    var utf16Length: Int {
        (string as NSString).length
    }

    var contiguousNSString: NSString? { nil }

    func substring(utf16Offset: Int, length: Int) -> String {
        substringCallCount += 1
        let ns = string as NSString
        let location = max(0, utf16Offset)
        let take = max(0, min(length, ns.length - location))
        guard take > 0 else {
            return ""
        }
        return ns.substring(with: NSRange(location: location, length: take))
    }
}

private final class ProgressBox: @unchecked Sendable {
    var values: [FindSearchOutcome] = []
}
