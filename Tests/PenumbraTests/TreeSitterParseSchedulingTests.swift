import AppKit
import XCTest
import PenumbraMarkdownLanguage
import TestTreeSitterLanguages
import TreeSitter
@testable import Penumbra

final class TreeSitterTreeCopyTests: XCTestCase {
    func testCopiedTreeIsIndependentOfEditsToTheOriginal() {
        let string: NSString = "let foo = 1"
        let parser = TreeSitterParser(encoding: .treeSitterUTF16)
        parser.language = TreeSitterLanguagePointer(tree_sitter_javascript())
        guard let original = parser.parse(string) else {
            return XCTFail("expected a tree")
        }
        let snapshot = original.copy()
        let originalExpression = original.rootNode.expressionString
        XCTAssertEqual(snapshot.rootNode.expressionString, originalExpression)

        let edit = TreeSitterInputEdit(
            startByte: 0,
            oldEndByte: 0,
            newEndByte: 2,
            startPoint: TreeSitterTextPoint(row: 0, column: 0),
            oldEndPoint: TreeSitterTextPoint(row: 0, column: 0),
            newEndPoint: TreeSitterTextPoint(row: 0, column: 1)
        )
        original.apply(edit)
        XCTAssertEqual(snapshot.rootNode.expressionString, originalExpression)
        XCTAssertEqual(snapshot.rootNode.endByte, original.rootNode.endByte - ByteCount(2))
    }
}

final class TreeSitterParserTimeoutTests: XCTestCase {
    private let delegate = MockTreeSitterParserDelegate()
    private var originalParserTimeout: TimeInterval = 0
    private var originalLongParseTimeout: TimeInterval = 0

    override func setUp() {
        super.setUp()
        originalParserTimeout = TreeSitterPerformanceConstants.parserTimeout
        originalLongParseTimeout = TreeSitterPerformanceConstants.longParseTimeout
    }

    override func tearDown() {
        TreeSitterPerformanceConstants.parserTimeout = originalParserTimeout
        TreeSitterPerformanceConstants.longParseTimeout = originalLongParseTimeout
        super.tearDown()
    }

    func testMainThreadTimeoutAbortsALargeParse() {
        TreeSitterPerformanceConstants.parserTimeout = 0
        let parser = TreeSitterParser(encoding: .treeSitterUTF16)
        parser.delegate = delegate
        parser.language = TreeSitterLanguagePointer(tree_sitter_javascript())
        let text = String(repeating: "let name = \"value\";\n", count: 8_000) as NSString
        let tree = parser.parse(text)
        XCTAssertNil(tree)
        XCTAssertTrue(parser.lastParseAborted)
    }

    func testBackgroundParseIgnoresMainThreadTimeout() {
        TreeSitterPerformanceConstants.parserTimeout = 0
        let parser = TreeSitterParser(encoding: .treeSitterUTF16)
        parser.language = TreeSitterLanguagePointer(tree_sitter_javascript())
        let text = String(repeating: "let name = \"value\";\n", count: 2_000) as NSString
        let finished = expectation(description: "background parse")
        DispatchQueue.global(qos: .userInitiated).async {
            let tree = parser.parse(text)
            XCTAssertNotNil(tree)
            XCTAssertFalse(parser.lastParseAborted)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
    }

    func testShouldCancelAbortsParse() {
        let parser = TreeSitterParser(encoding: .treeSitterUTF16)
        parser.language = TreeSitterLanguagePointer(tree_sitter_javascript())
        parser.shouldCancel = { true }
        let text = String(repeating: "let name = \"value\";\n", count: 2_000) as NSString
        let tree = parser.parse(text)
        XCTAssertNil(tree)
        XCTAssertTrue(parser.lastParseAborted)
    }

    func testLongParseNotificationPostsWhenThresholdIsZero() {
        TreeSitterPerformanceConstants.longParseTimeout = 0
        let posted = expectation(forNotification: TreeSitterPerformanceConstants.longParseNotification, object: nil)
        let parser = TreeSitterParser(encoding: .treeSitterUTF16)
        parser.language = TreeSitterLanguagePointer(tree_sitter_javascript())
        _ = parser.parse("let foo = 1" as NSString)
        wait(for: [posted], timeout: 2)
    }
}

final class TreeSitterCaptureSnapshotTests: XCTestCase {
    func testConcurrentCapturesDoNotCrash() {
        let text = "# Hello\n\nThis is **bold** text.\n"
        let languageMode = makeMarkdownLanguageMode(text: text)
        let range = ByteRange(from: 0, to: (text as NSString).byteCount)
        XCTAssertFalse(languageMode.captures(in: range).isEmpty)

        let finished = expectation(description: "concurrent captures")
        finished.expectedFulfillmentCount = 8
        for _ in 0..<8 {
            DispatchQueue.global(qos: .userInitiated).async {
                for _ in 0..<25 {
                    let captures = languageMode.captures(in: range)
                    _ = captures.first?.node.startByte
                }
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 5)
    }

    func testEditDuringCaptureDoesNotCrash() {
        let text = "# Hello\n\nThis is **bold** text.\n"
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let languageMode = TreeSitterInternalLanguageMode(
            language: TreeSitterLanguage.markdown.internalLanguage,
            languageProvider: MarkdownLanguageProvider(),
            stringView: stringView,
            lineManager: lineManager
        )
        languageMode.parse()
        let range = ByteRange(from: 0, to: (text as NSString).byteCount)
        XCTAssertFalse(languageMode.captures(in: range).isEmpty)

        let finished = expectation(description: "capture finished")
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<40 {
                let captures = languageMode.captures(in: range)
                _ = captures.first?.node.startByte
            }
            finished.fulfill()
        }
        let helper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
        for _ in 0..<20 {
            let result = helper.replaceText(in: NSRange(location: 0, length: 0), with: "x")
            _ = languageMode.textDidChange(result.textChange)
        }
        let parseFinished = expectation(description: "parse finished")
        languageMode.parse { _ in parseFinished.fulfill() }
        wait(for: [finished, parseFinished], timeout: 5)
        XCTAssertTrue(languageMode.isSyntaxTreeReady)
    }

    /// `captures(in:)` keeps the last few queried byte windows (`captureWindowCacheSize`) instead
    /// of a single slot, so `LayoutManager`'s 4-way concurrent `highlightQueue` doesn't evict one
    /// visible line's cached window every time a sibling line highlights a nearby-but-different
    /// range. Querying more distinct, non-adjacent windows than the cache holds — round-robin, so
    /// every slot gets evicted and re-populated at least once — must still return the *correct*
    /// captures for each window, both with the default cache size and with the old single-slot
    /// size (``TreeSitterPerformanceConstants/captureWindowCacheSize`` = 1).
    func testCaptureWindowCacheReturnsCorrectResultsAcrossEvictions() {
        var sections: [String] = []
        for index in 0..<12 {
            // Pad each section so windows are byte-distinct and don't share a query range.
            sections.append("# Heading\(index)\n\n**bold\(index)** " + String(repeating: "word ", count: 400) + "\n")
        }
        let text = sections.joined()
        let languageMode = makeMarkdownLanguageMode(text: text)
        let nsText = text as NSString

        // One non-overlapping byte range per section, each containing that section's heading.
        var ranges: [(index: Int, range: ByteRange)] = []
        for index in 0..<12 {
            let needle = "# Heading\(index)"
            let location = nsText.range(of: needle).location
            XCTAssertNotEqual(location, NSNotFound)
            let utf16Range = NSRange(location: location, length: (needle as NSString).length)
            ranges.append((index, ByteRange(utf16Range: utf16Range)))
        }

        let originalCacheSize = TreeSitterPerformanceConstants.captureWindowCacheSize
        defer { TreeSitterPerformanceConstants.captureWindowCacheSize = originalCacheSize }

        for cacheSize in [1, 3, originalCacheSize] {
            TreeSitterPerformanceConstants.captureWindowCacheSize = cacheSize
            // Visit every range twice, interleaved, so the cache is forced to evict and refill
            // (cacheSize is well below 12) and every slot is exercised more than once.
            for pass in 0..<2 {
                for (index, range) in ranges {
                    let captures = languageMode.captures(in: range)
                    XCTAssertTrue(
                        captures.contains { $0.name.hasPrefix("markup.heading") },
                        "cacheSize=\(cacheSize) pass=\(pass): expected a heading capture for Heading\(index), got \(captures.map(\.name))"
                    )
                }
            }
        }
    }

    private func makeMarkdownLanguageMode(text: String) -> TreeSitterInternalLanguageMode {
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let languageMode = TreeSitterInternalLanguageMode(
            language: TreeSitterLanguage.markdown.internalLanguage,
            languageProvider: MarkdownLanguageProvider(),
            stringView: stringView,
            lineManager: lineManager
        )
        languageMode.parse()
        return languageMode
    }
}

@MainActor
final class TreeSitterMaxSyncEditLengthTests: XCTestCase {
    private var originalMaxSyncEditLength = 0

    override func setUp() {
        super.setUp()
        originalMaxSyncEditLength = TreeSitterPerformanceConstants.maxSyncEditLength
    }

    override func tearDown() {
        TreeSitterPerformanceConstants.maxSyncEditLength = originalMaxSyncEditLength
        super.tearDown()
    }

    func testDeferredParseRecolorsChangedRowsOnly() {
        UserDefaults.standard.set(false, forKey: PenumbraSyncKeystrokeParse.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: PenumbraSyncKeystrokeParse.defaultsKey) }
        let source = (0 ..< 80).map { "let value\($0) = \($0);" }.joined(separator: "\n") + "\n"
        let stringView = StringView(string: source)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let languageMode = TreeSitterInternalLanguageMode(
            language: TreeSitterLanguage(tree_sitter_javascript()).internalLanguage,
            languageProvider: nil,
            stringView: stringView,
            lineManager: lineManager
        )
        languageMode.parse()
        XCTAssertTrue(languageMode.isSyntaxTreeReady)

        let helper = TextEditHelper(stringView: stringView, lineManager: lineManager, lineEndings: .lf)
        let edited = helper.replaceText(in: NSRange(location: 4, length: 0), with: "X")
        _ = languageMode.textDidChange(edited.textChange)
        XCTAssertFalse(languageMode.isSyntaxTreeReady)

        let finished = expectation(description: "deferred parse published a row diff")
        languageMode.parse { success in
            XCTAssertTrue(success)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)

        let rows = languageMode.consumePendingSyntaxRows()
        XCTAssertNotNil(rows, "an incremental reparse must publish a row diff, not a full-viewport invalidation")
        let covered = Set(rows?.flatMap { Array($0) } ?? [])
        XCTAssertFalse(covered.contains(70), "typing inside the first statement must not recolor line 70")
        XCTAssertLessThan(covered.count, 8)
    }

    func testSmallEditDefersParseThenHighlights() {
        UserDefaults.standard.set(false, forKey: PenumbraSyncKeystrokeParse.defaultsKey)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let delegate = SyntaxParseFinishedDelegate()
        let finished = expectation(description: "deferred parse finished")
        delegate.onFinish = { finished.fulfill() }
        textView.editorDelegate = delegate
        textView.setState(TextViewState(text: "# Hello\n\n**bold**\n", language: .markdown, parsePolicy: .eager))
        XCTAssertTrue(textView.isSyntaxTreeReady)

        textView.replace(NSRange(location: 0, length: 0), withText: "a")
        XCTAssertFalse(textView.isSyntaxTreeReady)
        XCTAssertTrue(textView.text.hasPrefix("a# Hello"))

        wait(for: [finished], timeout: 5)
        XCTAssertTrue(textView.isSyntaxTreeReady)
    }

    func testSyncKeystrokeParseRollbackKeepsTreeReady() {
        UserDefaults.standard.set(true, forKey: PenumbraSyncKeystrokeParse.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: PenumbraSyncKeystrokeParse.defaultsKey) }
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.setState(TextViewState(text: "# Hello\n\n**bold**\n", language: .markdown, parsePolicy: .eager))
        XCTAssertTrue(textView.isSyntaxTreeReady)

        textView.replace(NSRange(location: 0, length: 0), withText: "a")
        XCTAssertTrue(textView.isSyntaxTreeReady)
        XCTAssertTrue(textView.text.hasPrefix("a# Hello"))
    }

    func testLargeEditDefersParseThenHighlights() {
        TreeSitterPerformanceConstants.maxSyncEditLength = 8
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let delegate = SyntaxParseFinishedDelegate()
        let finished = expectation(description: "deferred parse finished")
        delegate.onFinish = { finished.fulfill() }
        textView.editorDelegate = delegate
        textView.setState(TextViewState(
            text: "# Hello\n\n**bold**\n",
            language: .markdown,
            languageProvider: MarkdownLanguageProvider(),
            parsePolicy: .eager
        ))
        XCTAssertTrue(textView.isSyntaxTreeReady)

        let paste = String(repeating: "plain ", count: 10)
        XCTAssertGreaterThan(paste.utf16.count, TreeSitterPerformanceConstants.maxSyncEditLength)
        textView.replace(NSRange(location: 0, length: 0), withText: paste)
        XCTAssertFalse(textView.isSyntaxTreeReady, "a paste larger than maxSyncEditLength must not parse on the keystroke")
        XCTAssertTrue(textView.text.hasPrefix("plain"))

        wait(for: [finished], timeout: 5)
        XCTAssertTrue(textView.isSyntaxTreeReady)
        let boldLocation = (textView.text as NSString).range(of: "**bold**").location
        XCTAssertNotEqual(boldLocation, NSNotFound)
        let captures = textView.syntaxHighlightCaptures(in: NSRange(location: boldLocation, length: 8))
        XCTAssertTrue(captures.contains { $0.name == "markup.bold" })
    }
}

private final class SyntaxParseFinishedDelegate: TextViewDelegate {
    var onFinish: (() -> Void)?

    func textViewDidFinishSyntaxParse(_ textView: TextView) {
        onFinish?()
    }
}
