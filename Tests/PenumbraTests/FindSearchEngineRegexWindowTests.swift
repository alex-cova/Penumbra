import XCTest
@testable import Penumbra

final class FindSearchEngineRegexWindowTests: XCTestCase {
    private let twoMiB = 2 * 1024 * 1024

    override func tearDown() {
        FindSearchEngine.debugRegexWindowUTF16 = nil
        FindSearchEngine.debugLiteralWindowUTF16 = nil
        super.tearDown()
    }

    func testTwoMiBCaretWholeWordAndZeroLengthCaretAgreeWithContiguous() async throws {
        let line = "hello world\n"
        let repeats = twoMiB / line.count
        let text = String(repeating: line, count: repeats)
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        XCTAssertGreaterThan(snapshot.utf16Length, FindSearchEngine.regexWindowUTF16)
        XCTAssertNil(FindSearchEngine.debugRegexWindowUTF16)

        let caretOptions = FindSearchOptions(query: "^", useRegex: true)
        let windowedCaret = FindSearchEngine.search(options: caretOptions, in: snapshot, anchorLocation: 0)
        let contiguousCaret = FindSearchEngine.search(options: caretOptions, in: text, anchorLocation: 0)
        XCTAssertNil(windowedCaret.errorMessage)
        XCTAssertEqual(windowedCaret.matchCount, contiguousCaret.matchCount)
        // ICU `^` fires at each content line start (not the empty last line, and not extra window cuts).
        XCTAssertEqual(windowedCaret.matchCount, repeats)
        XCTAssertEqual(windowedCaret.currentRange, NSRange(location: 0, length: 0))

        let wholeWordOptions = FindSearchOptions(query: "hello", wholeWord: true)
        let windowedWord = FindSearchEngine.search(options: wholeWordOptions, in: snapshot, anchorLocation: 0)
        let contiguousWord = FindSearchEngine.search(options: wholeWordOptions, in: text, anchorLocation: 0)
        XCTAssertEqual(windowedWord.matchCount, contiguousWord.matchCount)
        XCTAssertEqual(windowedWord.matchCount, repeats)
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testTwoMiBDollarMatchesOnceAtEOF() async throws {
        let text = String(repeating: "a", count: twoMiB)
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        XCTAssertNil(FindSearchEngine.debugRegexWindowUTF16)

        let options = FindSearchOptions(query: "$", useRegex: true)
        let windowed = FindSearchEngine.search(options: options, in: snapshot, anchorLocation: 0)
        let contiguous = FindSearchEngine.search(options: options, in: text, anchorLocation: 0)
        XCTAssertEqual(windowed.matchCount, 1)
        XCTAssertEqual(windowed.matchCount, contiguous.matchCount)
        XCTAssertEqual(windowed.currentRange, NSRange(location: snapshot.utf16Length, length: 0))
        XCTAssertEqual(windowed.currentRange, contiguous.currentRange)
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testTwoMiBTrailingNewlineCaretDoesNotMatchEOFAndDollarDoes() async throws {
        let text = String(repeating: "a", count: twoMiB - 1) + "\n"
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        XCTAssertNil(FindSearchEngine.debugRegexWindowUTF16)

        let caretOptions = FindSearchOptions(query: "^", useRegex: true)
        let windowedCaret = FindSearchEngine.search(options: caretOptions, in: snapshot, anchorLocation: 0)
        let contiguousCaret = FindSearchEngine.search(options: caretOptions, in: text, anchorLocation: 0)
        XCTAssertEqual(windowedCaret.matchCount, contiguousCaret.matchCount)
        // ICU `^` does not fire at EOF after a trailing newline; `$` does (empty last line).
        XCTAssertEqual(windowedCaret.matchCount, 1)
        XCTAssertEqual(windowedCaret.currentRange, NSRange(location: 0, length: 0))

        let dollarOptions = FindSearchOptions(query: "$", useRegex: true)
        let windowedDollar = FindSearchEngine.search(options: dollarOptions, in: snapshot, anchorLocation: 0)
        let contiguousDollar = FindSearchEngine.search(options: dollarOptions, in: text, anchorLocation: 0)
        XCTAssertEqual(windowedDollar.matchCount, contiguousDollar.matchCount)
        XCTAssertEqual(windowedDollar.matchCount, 2)
        XCTAssertEqual(
            FindSearchEngine.findPrevious(options: dollarOptions, in: snapshot, before: snapshot.utf16Length + 1),
            NSRange(location: snapshot.utf16Length, length: 0)
        )
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testWordBoundaryAtOneMiBCutAfterWordCharacterDoesNotMatch() async throws {
        let unique = FindSearchEngine.regexWindowUTF16
        let text = String(repeating: "a", count: unique) + "word"
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let options = FindSearchOptions(query: "word", wholeWord: true)
        let windowed = FindSearchEngine.search(options: options, in: snapshot, anchorLocation: 0)
        let contiguous = FindSearchEngine.search(options: options, in: text, anchorLocation: 0)
        XCTAssertEqual(windowed.matchCount, 0)
        XCTAssertEqual(windowed.matchCount, contiguous.matchCount)
        XCTAssertNil(windowed.currentRange)
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testWordBoundaryAtOneMiBCutAfterNonWordCharacterMatches() async throws {
        let unique = FindSearchEngine.regexWindowUTF16
        let text = String(repeating: " ", count: unique) + "word"
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let options = FindSearchOptions(query: "word", wholeWord: true)
        let windowed = FindSearchEngine.search(options: options, in: snapshot, anchorLocation: 0)
        let contiguous = FindSearchEngine.search(options: options, in: text, anchorLocation: 0)
        XCTAssertEqual(windowed.matchCount, 1)
        XCTAssertEqual(windowed.matchCount, contiguous.matchCount)
        XCTAssertEqual(windowed.currentRange, NSRange(location: unique, length: 4))
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testLookbehindAssertionStartsInPreviousUniquePrefix() async throws {
        let unique = FindSearchEngine.regexWindowUTF16
        let text = String(repeating: "x", count: unique - 4) + "abcdLOOK"
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let options = FindSearchOptions(query: "(?<=abcd)LOOK", matchCase: true, useRegex: true)
        let windowed = FindSearchEngine.search(options: options, in: snapshot, anchorLocation: 0)
        let contiguous = FindSearchEngine.search(options: options, in: text, anchorLocation: 0)
        XCTAssertEqual(windowed.matchCount, 1)
        XCTAssertEqual(windowed.matchCount, contiguous.matchCount)
        XCTAssertEqual(windowed.currentRange, NSRange(location: unique, length: 4))
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testMatchStartingInUniqueAndEndingInRightPad() async throws {
        let unique = FindSearchEngine.regexWindowUTF16
        let needle = String(repeating: "z", count: 80)
        let prefixLen = unique - 30
        let text = String(repeating: "a", count: prefixLen) + needle + String(repeating: "b", count: 1_000)
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let options = FindSearchOptions(query: "z{80}", matchCase: true, useRegex: true)
        let windowed = FindSearchEngine.search(options: options, in: snapshot, anchorLocation: 0)
        let contiguous = FindSearchEngine.search(options: options, in: text, anchorLocation: 0)
        XCTAssertEqual(windowed.matchCount, 1)
        XCTAssertEqual(windowed.currentRange, NSRange(location: prefixLen, length: 80))
        XCTAssertEqual(windowed.currentRange, contiguous.currentRange)
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testSmallWindowHookMatchStartingInUniqueAndEndingInRightPad() async throws {
        FindSearchEngine.debugRegexWindowUTF16 = 8
        let text = "aaaaaazzzzzzzzbbbb"
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let options = FindSearchOptions(query: "z{8}", matchCase: true, useRegex: true)
        let windowed = FindSearchEngine.search(options: options, in: snapshot, anchorLocation: 0)
        XCTAssertEqual(windowed.matchCount, 1)
        XCTAssertEqual(windowed.currentRange, NSRange(location: 6, length: 8))
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testFooDotStarBarAcrossTwoMiBIsSkipped() async throws {
        let text = "foo" + String(repeating: "x", count: twoMiB) + "bar"
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        XCTAssertNil(FindSearchEngine.debugRegexWindowUTF16)

        let options = FindSearchOptions(query: "foo.*bar", matchCase: true, useRegex: true)
        let windowed = FindSearchEngine.search(options: options, in: snapshot, anchorLocation: 0)
        XCTAssertNil(windowed.errorMessage)
        XCTAssertEqual(windowed.matchCount, 0)
        XCTAssertNil(windowed.currentRange)
        let contiguous = FindSearchEngine.search(options: options, in: text, anchorLocation: 0)
        XCTAssertEqual(contiguous.matchCount, 1)
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testFindPreviousBeforeEndAndEndPlusOneOnTwoMiB() async throws {
        let dollars = String(repeating: "a", count: twoMiB)
        let dollarView = try await loadFileBacked(dollars)
        let dollarSnapshot = try XCTUnwrap(dollarView.contentSnapshot())
        let dollarEnd = dollarSnapshot.utf16Length
        let dollarOptions = FindSearchOptions(query: "$", useRegex: true)
        let dollarAtEnd = NSRange(location: dollarEnd, length: 0)
        XCTAssertEqual(
            FindSearchEngine.findPrevious(options: dollarOptions, in: dollarSnapshot, before: dollarEnd),
            dollarAtEnd
        )
        XCTAssertEqual(
            FindSearchEngine.findPrevious(options: dollarOptions, in: dollarSnapshot, before: dollarEnd + 1),
            dollarAtEnd
        )
        XCTAssertNil(
            FindSearchEngine.findPrevious(options: dollarOptions, in: dollarSnapshot, before: dollarEnd - 1)
        )
        XCTAssertEqual(dollarView.materializeCount, 0)

        let caretText = String(repeating: "a", count: twoMiB - 1) + "\n"
        let caretView = try await loadFileBacked(caretText)
        let caretSnapshot = try XCTUnwrap(caretView.contentSnapshot())
        let caretEnd = caretSnapshot.utf16Length
        let caretOptions = FindSearchOptions(query: "^", useRegex: true)
        let firstCaret = NSRange(location: 0, length: 0)
        XCTAssertEqual(
            FindSearchEngine.findPrevious(options: caretOptions, in: caretSnapshot, before: caretEnd),
            firstCaret
        )
        XCTAssertEqual(
            FindSearchEngine.findPrevious(options: caretOptions, in: caretSnapshot, before: caretEnd + 1),
            firstCaret
        )
        let trailingDollar = FindSearchOptions(query: "$", useRegex: true)
        XCTAssertEqual(
            FindSearchEngine.findPrevious(options: trailingDollar, in: caretSnapshot, before: caretEnd),
            NSRange(location: caretEnd, length: 0)
        )
        XCTAssertEqual(
            FindSearchEngine.findPrevious(options: trailingDollar, in: caretSnapshot, before: caretEnd + 1),
            NSRange(location: caretEnd, length: 0)
        )
        XCTAssertEqual(caretView.materializeCount, 0)
    }

    func testOnlyMatchNearStartFindPreviousDoesNotMaterialize() async throws {
        let text = "NEEDLE" + String(repeating: "x", count: twoMiB)
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let options = FindSearchOptions(query: "NEE.LE", matchCase: true, useRegex: true)
        let expected = NSRange(location: 0, length: 6)
        XCTAssertEqual(
            FindSearchEngine.findPrevious(options: options, in: snapshot, before: snapshot.utf16Length),
            expected
        )
        XCTAssertEqual(
            FindSearchEngine.findPrevious(options: options, in: snapshot, before: snapshot.utf16Length + 1),
            expected
        )
        XCTAssertEqual(
            FindSearchEngine.findNext(options: options, in: snapshot, after: 0),
            expected
        )
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testCancellationMidWindow() async throws {
        let text = String(repeating: "needle ", count: 200_000)
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let options = FindSearchOptions(query: "nee.le", useRegex: true)
        let searchTask = Task {
            FindSearchEngine.search(options: options, in: snapshot, anchorLocation: 0)
        }
        searchTask.cancel()
        let outcome = await searchTask.value
        XCTAssertEqual(outcome, .empty)

        let replaceTask = Task {
            try FindSearchEngine.replaceAllMatches(options: options, in: snapshot, replacement: "x")
        }
        replaceTask.cancel()
        do {
            _ = try await replaceTask.value
            XCTFail("cancelled replace-all should throw CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testSmallWindowCaretIsNotDoubleCountedAtWindowStarts() async throws {
        FindSearchEngine.debugRegexWindowUTF16 = 8
        let text = String(repeating: "ab\n", count: 20)
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let options = FindSearchOptions(query: "^", useRegex: true)
        let windowed = FindSearchEngine.search(options: options, in: snapshot, anchorLocation: 0)
        let contiguous = FindSearchEngine.search(options: options, in: text, anchorLocation: 0)
        XCTAssertEqual(windowed.matchCount, contiguous.matchCount)
        XCTAssertEqual(windowed.matchCount, 20)
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testReplacementTextUsesPaddedWindowOnPieceTree() async throws {
        let unique = FindSearchEngine.regexWindowUTF16
        let text = String(repeating: "x", count: unique) + "a=b"
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let options = FindSearchOptions(query: #"(\w+)=(\w+)"#, matchCase: true, useRegex: true)
        let match = NSRange(location: unique, length: 3)
        let expanded = try FindSearchEngine.replacementText(
            options: options,
            in: snapshot,
            matching: match,
            replacement: "$2=$1"
        )
        XCTAssertEqual(expanded, "b=a")
        XCTAssertEqual(view.materializeCount, 0)
    }

    func testReplaceAllMatchesRegexOnPieceTree() async throws {
        let text = String(repeating: "foo bar\n", count: 50)
        let view = try await loadFileBacked(text)
        let snapshot = try XCTUnwrap(view.contentSnapshot())
        let options = FindSearchOptions(query: "(foo) (bar)", matchCase: true, useRegex: true)
        let matches = try FindSearchEngine.replaceAllMatches(
            options: options,
            in: snapshot,
            replacement: "$2:$1"
        )
        XCTAssertEqual(matches.count, 50)
        XCTAssertEqual(matches.first?.replacementText, "bar:foo")
        XCTAssertEqual(matches.first?.range, NSRange(location: 0, length: 7))
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
