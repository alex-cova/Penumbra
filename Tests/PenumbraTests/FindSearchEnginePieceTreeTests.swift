import XCTest
@testable import Penumbra

final class FindSearchEnginePieceTreeTests: XCTestCase {
    override func tearDown() {
        FindSearchEngine.debugLiteralWindowUTF16 = nil
        FindSearchEngine.debugLiteralWindowSubstringUTF16Lengths = nil
        super.tearDown()
    }

    func testLiteralSearchAfterMiddleEditAgreesWithStringAndDoesNotMaterialize() async throws {
        let original = String(repeating: "hello world\n", count: 40)
        let view = try await loadFileBacked(original)
        view.replaceText(in: NSRange(location: 20, length: 0), with: "NEEDLE")
        let expected = try XCTUnwrap(view.substring(in: NSRange(location: 0, length: view.length)))
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let before = view.materializeCount

        let options = FindSearchOptions(query: "NEEDLE", matchCase: true)
        let outcome = FindSearchEngine.search(options: options, in: snapshot, anchorLocation: 0)
        let stringOutcome = FindSearchEngine.search(options: options, in: expected, anchorLocation: 0)
        XCTAssertEqual(outcome.matchCount, 1)
        XCTAssertEqual(outcome.currentRange, NSRange(location: 20, length: 6))
        XCTAssertEqual(outcome.matchCount, stringOutcome.matchCount)
        XCTAssertEqual(outcome.currentRange, stringOutcome.currentRange)

        let ci = FindSearchEngine.search(
            options: FindSearchOptions(query: "needle"),
            in: snapshot,
            anchorLocation: 0
        )
        XCTAssertEqual(ci.matchCount, 1)
        XCTAssertEqual(ci.currentRange, NSRange(location: 20, length: 6))

        XCTAssertEqual(
            FindSearchEngine.findNext(options: options, in: snapshot, after: 21),
            nil
        )
        XCTAssertEqual(
            FindSearchEngine.findNext(options: options, in: snapshot, after: 20),
            NSRange(location: 20, length: 6)
        )
        XCTAssertEqual(
            FindSearchEngine.findPrevious(options: options, in: snapshot, before: 26),
            NSRange(location: 20, length: 6)
        )
        XCTAssertNil(FindSearchEngine.findPrevious(options: options, in: snapshot, before: 20))
        XCTAssertEqual(view.materializeCount, before)
    }

    func testMatchStartingInUniqueAndEndingInRightPad() async throws {
        let unique = FindSearchEngine.literalWindowUTF16
        let query = "NEEDLE"
        let prefixLen = unique - 3
        let text = String(repeating: "a", count: prefixLen) + query + "zzzz"
        let view = try await loadFileBacked(text)
        let before = view.materializeCount
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let options = FindSearchOptions(query: query, matchCase: true)
        let outcome = FindSearchEngine.search(options: options, in: snapshot, anchorLocation: 0)
        XCTAssertEqual(outcome.matchCount, 1)
        XCTAssertEqual(outcome.currentRange, NSRange(location: prefixLen, length: query.utf16.count))
        XCTAssertEqual(
            FindSearchEngine.search(options: options, in: text, anchorLocation: 0).currentRange,
            outcome.currentRange
        )
        XCTAssertEqual(view.materializeCount, before)
    }

    func testCaseInsensitiveMatchStartingInUniqueAndEndingInRightPad() async throws {
        let unique = FindSearchEngine.literalWindowUTF16
        let query = "Needle"
        let prefixLen = unique - 2
        let text = String(repeating: "a", count: prefixLen) + query + "zzzz"
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let options = FindSearchOptions(query: "needle")
        let outcome = FindSearchEngine.search(options: options, in: snapshot, anchorLocation: 0)
        XCTAssertEqual(outcome.matchCount, 1)
        XCTAssertEqual(outcome.currentRange, NSRange(location: prefixLen, length: query.utf16.count))
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testEmojiExactlyOnUniqueBoundary() async throws {
        let unique = FindSearchEngine.literalWindowUTF16
        let emoji = "😀"
        let text = String(repeating: "a", count: unique) + emoji + "tail"
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let options = FindSearchOptions(query: emoji, matchCase: true)
        let outcome = FindSearchEngine.search(options: options, in: snapshot, anchorLocation: 0)
        XCTAssertEqual(outcome.matchCount, 1)
        XCTAssertEqual(outcome.currentRange, NSRange(location: unique, length: (emoji as NSString).length))
        XCTAssertEqual(
            FindSearchEngine.findNext(options: options, in: snapshot, after: unique - 1),
            outcome.currentRange
        )
        XCTAssertEqual(
            FindSearchEngine.findPrevious(options: options, in: snapshot, before: snapshot.utf16Length),
            outcome.currentRange
        )
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testEmojiStraddlingUniqueCutIsCountedOnce() async throws {
        let unique = FindSearchEngine.literalWindowUTF16
        let emoji = "😀"
        let emojiLength = (emoji as NSString).length
        let text = String(repeating: "a", count: unique - 1) + emoji + "tail"
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let options = FindSearchOptions(query: emoji, matchCase: true)
        let expected = NSRange(location: unique - 1, length: emojiLength)
        let outcome = FindSearchEngine.search(options: options, in: snapshot, anchorLocation: 0)
        XCTAssertEqual(outcome.matchCount, 1)
        XCTAssertEqual(outcome.currentRange, expected)
        XCTAssertEqual(FindSearchEngine.findNext(options: options, in: snapshot, after: unique - 1), expected)
        XCTAssertNil(FindSearchEngine.findNext(options: options, in: snapshot, after: unique))
        XCTAssertEqual(FindSearchEngine.findPrevious(options: options, in: snapshot, before: unique), expected)
        XCTAssertNil(FindSearchEngine.findPrevious(options: options, in: snapshot, before: unique - 1))
        let matches = try FindSearchEngine.replaceAllMatches(options: options, in: snapshot, replacement: "x")
        XCTAssertEqual(matches.map(\.range), [expected])
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testHighSurrogateAtSearchRegionEndStillDecodesFollowingPair() async throws {
        let unique = 8
        FindSearchEngine.debugLiteralWindowUTF16 = unique
        FindSearchEngine.debugLiteralWindowSubstringUTF16Lengths = []
        let emoji = "😀"
        // 1-unit query ⇒ rightPad == 1; 😀 starts at unique+1 == first-window searchEnd.
        // extend-1 must request unique+2 units so the window includes the high rather than
        // ending on an unpaired high / omitting the pair.
        let text = String(repeating: "a", count: unique + 1) + emoji + "xyz"
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let aMatches = FindSearchEngine.search(
            options: FindSearchOptions(query: "a", matchCase: true),
            in: snapshot,
            anchorLocation: 0
        )
        XCTAssertEqual(aMatches.matchCount, unique + 1)
        let lengths = try XCTUnwrap(FindSearchEngine.debugLiteralWindowSubstringUTF16Lengths)
        XCTAssertEqual(lengths.first, unique + 2)
        let firstWindow = snapshot.substring(utf16Offset: 0, length: unique + 2) as NSString
        XCTAssertEqual(firstWindow.length, unique + 2)
        XCTAssertTrue((0xD800...0xDBFF).contains(firstWindow.character(at: unique + 1)))
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testCRLFOnTheUniqueCut() async throws {
        let unique = FindSearchEngine.literalWindowUTF16
        let text = String(repeating: "a", count: unique - 1) + "\r\n" + "tail"
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let options = FindSearchOptions(query: "\r\n", matchCase: true)
        let outcome = FindSearchEngine.search(options: options, in: snapshot, anchorLocation: 0)
        XCTAssertEqual(outcome.matchCount, 1)
        XCTAssertEqual(outcome.currentRange, NSRange(location: unique - 1, length: 2))
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testSmallWindowHookStraddlesUniqueAndRightPad() async throws {
        FindSearchEngine.debugLiteralWindowUTF16 = 8
        let text = "aaaaaaNEEDLEzzz"
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let options = FindSearchOptions(query: "NEEDLE", matchCase: true)
        let outcome = FindSearchEngine.search(options: options, in: snapshot, anchorLocation: 0)
        XCTAssertEqual(outcome.matchCount, 1)
        XCTAssertEqual(outcome.currentRange, NSRange(location: 6, length: 6))
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testRegexAndWholeWordOnPieceTreeDoNotMaterialize() async throws {
        let text = String(repeating: "cat category cat\n", count: 200)
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let before = view.materializeCount

        let regexOptions = FindSearchOptions(query: "cat", useRegex: true)
        let regex = FindSearchEngine.search(options: regexOptions, in: snapshot, anchorLocation: 0)
        let regexString = FindSearchEngine.search(options: regexOptions, in: text, anchorLocation: 0)
        XCTAssertNil(regex.errorMessage)
        XCTAssertEqual(regex.matchCount, regexString.matchCount)
        XCTAssertEqual(regex.currentRange, regexString.currentRange)

        let wholeWordOptions = FindSearchOptions(query: "cat", wholeWord: true)
        let wholeWord = FindSearchEngine.search(options: wholeWordOptions, in: snapshot, anchorLocation: 0)
        let wholeWordString = FindSearchEngine.search(options: wholeWordOptions, in: text, anchorLocation: 0)
        XCTAssertNil(wholeWord.errorMessage)
        XCTAssertEqual(wholeWord.matchCount, wholeWordString.matchCount)
        XCTAssertEqual(wholeWord.matchCount, 400)

        XCTAssertEqual(
            FindSearchEngine.findNext(options: regexOptions, in: snapshot, after: 0),
            FindSearchEngine.findNext(options: regexOptions, in: text, after: 0)
        )
        XCTAssertEqual(
            FindSearchEngine.findPrevious(options: wholeWordOptions, in: snapshot, before: snapshot.utf16Length),
            FindSearchEngine.findPrevious(options: wholeWordOptions, in: text, before: (text as NSString).length)
        )
        let matches = try FindSearchEngine.replaceAllMatches(
            options: regexOptions,
            in: snapshot,
            replacement: "dog"
        )
        XCTAssertEqual(matches.count, regex.matchCount)
        XCTAssertEqual(view.materializeCount, before)
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testReplaceAllMatchesLiteralOnPieceTree() async throws {
        let view = try await loadFileBacked("foo bar foo")
        view.replaceText(in: NSRange(location: 3, length: 0), with: "X")
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let matches = try FindSearchEngine.replaceAllMatches(
            options: FindSearchOptions(query: "foo", matchCase: true),
            in: snapshot,
            replacement: "baz"
        )
        XCTAssertEqual(matches, [
            FindReplaceMatch(range: NSRange(location: 0, length: 3), replacementText: "baz"),
            FindReplaceMatch(range: NSRange(location: 9, length: 3), replacementText: "baz")
        ])
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testReplacementTextLiteralOnPieceTreeDoesNotNeedRegex() async throws {
        let view = try await loadFileBacked("abc")
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let text = try FindSearchEngine.replacementText(
            options: FindSearchOptions(query: "a"),
            in: snapshot,
            matching: NSRange(location: 0, length: 1),
            replacement: "z"
        )
        XCTAssertEqual(text, "z")
        XCTAssertEqual(view.materializeCount, 0)
    }

    private func loadFileBacked(_ text: String) async throws -> StringView {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        let state = try await TextViewState.load(contentsOf: url)
        XCTAssertTrue(state.stringView.isFileBacked)
        return state.stringView
    }
}
