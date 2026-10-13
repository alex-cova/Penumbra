import AppKit
import PenumbraLanguages
import PenumbraMarkdownLanguage
import XCTest
@testable import Penumbra

/// `TextInputView.insertTextAtAllSelections` makes one `replaceText` (and one `textDidChange`) per
/// caret, back to front, and every call cancels the parse. Whether a parse lands between two of
/// those edits depends on machine load. Whatever the interleaving, the tree the last parse
/// publishes must give the same captures as a fresh parse of the final text, or a line nobody
/// edited keeps a style it never had (`IncrementalHighlightConsistencyTests
/// .testTypingHeadingMarkersAtSeveralCarets`).
@MainActor
final class MultiCaretIncrementalParseTests: XCTestCase {
    private enum Step: CaseIterable {
        /// Nothing runs between this edit and the next.
        case none
        /// A parse publishes before the next edit.
        case parse
        /// The next edit finds no tree (it arrived while a parse was in flight, or after one was cancelled).
        case invalidate
    }

    /// Every combination of `Step` between the nine edits is 3^8 = 6,561 trees (about 2.5 minutes in
    /// Debug), which found no divergence; the suite runs every 97th so it stays quick (set stride to 1 to run them all).
    private static let combinationStride = 97

    private static let source = "one\n\ntwo\n\nthree\n"

    private func makeMode(text: String) -> (TreeSitterInternalLanguageMode, StringView, LineManager) {
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let mode = TreeSitterInternalLanguageMode(
            language: TreeSitterLanguage.markdown.internalLanguage,
            languageProvider: MarkdownLanguageProvider(),
            stringView: stringView,
            lineManager: lineManager
        )
        return (mode, stringView, lineManager)
    }

    /// Captures (name and byte range) over the whole document, in the order the highlighter sees them.
    private func signature(of mode: TreeSitterInternalLanguageMode, length: Int) -> [String] {
        let all = ByteRange(utf16Range: NSRange(location: 0, length: length))
        return mode.captures(in: all).map { "\($0.name)@\($0.byteRange.lowerBound.value)..<\($0.byteRange.upperBound.value)" }
    }

    /// The parse a keystroke schedules: it runs on the mode's operation queue and publishes on its own.
    private func parseInBackground(_ mode: TreeSitterInternalLanguageMode) {
        var finished = false
        mode.parse { _ in finished = true }
        let deadline = Date().addingTimeInterval(5)
        while !finished, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        XCTAssertTrue(finished, "the background parse never completed")
    }

    func testEveryInterleavingOfParsesMatchesAFreshParse() throws {
        let finalText = "## one\n\n## two\n\n## three\n"
        let (reference, _, _) = makeMode(text: finalText)
        reference.parse()
        let expected = signature(of: reference, length: (finalText as NSString).length)
        XCTAssertFalse(expected.isEmpty)

        let carets = [0, 5, 10] // "one", "two", "three" in the initial text
        // Keystroke k inserts one character at each caret; the carets back to front.
        var plan: [(location: Int, string: String)] = []
        for (index, character) in "## ".enumerated() {
            for (caretIndex, caret) in carets.enumerated().reversed() {
                plan.append((caret + index * (caretIndex + 1), String(character)))
            }
        }
        XCTAssertEqual(plan.count, 9)

        let stepCount = plan.count - 1
        var combinations = 1
        for _ in 0 ..< stepCount { combinations *= Step.allCases.count }

        var failures: [String] = []
        for combination in stride(from: 0, to: combinations, by: Self.combinationStride) {
            var steps: [Step] = []
            var remaining = combination
            for _ in 0 ..< stepCount {
                steps.append(Step.allCases[remaining % Step.allCases.count])
                remaining /= Step.allCases.count
            }
            let (mode, stringView, lineManager) = makeMode(text: Self.source)
            mode.parse()
            let helper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
            for (index, edit) in plan.enumerated() {
                let result = helper.replaceText(in: NSRange(location: edit.location, length: 0), with: edit.string)
                _ = mode.textDidChange(result.textChange)
                guard index < steps.count else { continue }
                switch steps[index] {
                case .none:
                    break
                case .parse:
                    mode.parse()
                case .invalidate:
                    mode.invalidateSyntaxTree()
                }
            }
            XCTAssertEqual(stringView.string as String, finalText)
            mode.parse()
            let actual = signature(of: mode, length: (finalText as NSString).length)
            if actual != expected {
                failures.append("\(steps): \(actual.filter { !expected.contains($0) }) extra, \(expected.filter { !actual.contains($0) }) missing")
                if failures.count >= 5 { break }
            }
        }
        XCTAssertTrue(failures.isEmpty, "trees diverge from a fresh parse:\n" + failures.joined(separator: "\n"))
    }

    /// `TextInputView.replaceText` changes the buffer and the line tree first and tells the language
    /// mode afterwards (`textDidChange`: epoch bump, `ts_tree_edit`). A background parse that
    /// finishes in between publishes a tree built from the new text and the old tree, and the edit is
    /// then applied on top of it. Models that window with a background parse between the two.
    func testAParsePublishedBetweenTheBufferChangeAndTheEditNoticeMatchesAFreshParse() throws {
        let finalText = "## one\n\n## two\n\n## three\n"
        let (reference, _, _) = makeMode(text: finalText)
        reference.parse()
        let expected = signature(of: reference, length: (finalText as NSString).length)

        let carets = [0, 5, 10]
        var plan: [(location: Int, string: String)] = []
        for (index, character) in "## ".enumerated() {
            for (caretIndex, caret) in carets.enumerated().reversed() {
                plan.append((caret + index * (caretIndex + 1), String(character)))
            }
        }
        var failures: [String] = []
        for racing in 0 ..< plan.count {
            for parseAfterEveryEdit in [false, true] {
                let (mode, stringView, lineManager) = makeMode(text: Self.source)
                mode.parse()
                let helper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
                for (index, edit) in plan.enumerated() {
                    let result = helper.replaceText(in: NSRange(location: edit.location, length: 0), with: edit.string)
                    if index == racing {
                        parseInBackground(mode)
                    }
                    _ = mode.textDidChange(result.textChange)
                    if parseAfterEveryEdit {
                        mode.parse()
                    }
                }
                mode.parse()
                let actual = signature(of: mode, length: (finalText as NSString).length)
                if actual != expected {
                    failures.append("racing edit \(racing), parse after every edit \(parseAfterEveryEdit): "
                        + "\(actual.filter { !expected.contains($0) }) extra, \(expected.filter { !actual.contains($0) }) missing")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "trees diverge from a fresh parse:\n" + failures.joined(separator: "\n"))
    }
}
