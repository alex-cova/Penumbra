import AppKit
import XCTest
import PenumbraMarkdownLanguage
@testable import Penumbra

final class ViewportParseWindowTests: XCTestCase {
    func testFullParseWhenDocumentIsUnderLimit() {
        let text = "a\nb\nc\n"
        let lineManager = LineManager(stringView: StringView(string: text))
        lineManager.rebuild()
        let range = ViewportParseWindow.utf16Range(
            lineManager: lineManager,
            stringLength: (text as NSString).length,
            viewport: CGRect(x: 0, y: 0, width: 100, height: 20),
            fullParseLimit: 1_000,
            maxWindowLength: 4
        )
        XCTAssertEqual(range, NSRange(location: 0, length: (text as NSString).length))
    }

    func testWindowIsCappedForLargeDocuments() {
        let text = String(repeating: "line\n", count: 400)
        let stringView = StringView(string: text)
        let lineManager = LineManager(stringView: stringView)
        lineManager.estimatedLineHeight = 10
        lineManager.rebuild()
        let range = ViewportParseWindow.utf16Range(
            lineManager: lineManager,
            stringLength: (text as NSString).length,
            viewport: CGRect(x: 0, y: 0, width: 100, height: 40),
            overscanScreens: 1,
            fullParseLimit: 10,
            maxWindowLength: 80
        )
        XCTAssertLessThanOrEqual(range.length, 80)
        XCTAssertGreaterThan(range.length, 0)
        XCTAssertEqual(range.location, 0)
    }

    func testZeroViewportFallsBackToLeadingWindow() {
        let text = String(repeating: "line\n", count: 200)
        let lineManager = LineManager(stringView: StringView(string: text))
        lineManager.estimatedLineHeight = 10
        lineManager.rebuild()
        let range = ViewportParseWindow.utf16Range(
            lineManager: lineManager,
            stringLength: (text as NSString).length,
            viewport: .zero,
            fullParseLimit: 10,
            maxWindowLength: 10_000
        )
        XCTAssertEqual(range.location, 0)
        XCTAssertGreaterThan(range.length, 0)
        XCTAssertLessThan(range.length, (text as NSString).length)
    }

    func testShiftMovesRangeAfterPrecedingInsert() {
        let range = NSRange(location: 10, length: 10)
        let shifted = ViewportParseWindow.shift(range, utf16Location: 0, oldLength: 1, newLength: 3)
        XCTAssertEqual(shifted, NSRange(location: 12, length: 10))
    }

    func testShiftLeavesEarlierRangeUnchanged() {
        let range = NSRange(location: 0, length: 4)
        let shifted = ViewportParseWindow.shift(range, utf16Location: 10, oldLength: 2, newLength: 0)
        XCTAssertEqual(shifted, range)
    }

    func testCollapsedTrailingLineStillProducesAWindow() {
        let text = String(repeating: "line\n", count: 30)
        let lineManager = LineManager(stringView: StringView(string: text))
        lineManager.estimatedLineHeight = 10
        lineManager.rebuild()
        let stringLength = (text as NSString).length
        let range = ViewportParseWindow.utf16Range(
            lineManager: lineManager,
            stringLength: stringLength,
            viewport: CGRect(x: 0, y: 10_000, width: 100, height: 40),
            overscanScreens: 0,
            fullParseLimit: 10,
            maxWindowLength: 40
        )
        XCTAssertGreaterThan(range.length, 0)
        XCTAssertEqual(NSMaxRange(range), stringLength)
    }

    func testContainsUTF16Range() {
        let window = NSRange(location: 10, length: 20)
        XCTAssertTrue(window.containsUTF16Range(NSRange(location: 10, length: 20)))
        XCTAssertTrue(window.containsUTF16Range(NSRange(location: 15, length: 5)))
        XCTAssertFalse(window.containsUTF16Range(NSRange(location: 5, length: 10)))
        XCTAssertFalse(window.containsUTF16Range(NSRange(location: 25, length: 10)))
    }
}

@MainActor
final class TextViewStateViewportParseTests: XCTestCase {
    private var originalFullParseLimit = 0
    private var originalWindowLimit = 0

    override func setUp() {
        super.setUp()
        originalFullParseLimit = TreeSitterPerformanceConstants.maxSyncContentLength
        originalWindowLimit = TreeSitterPerformanceConstants.maxViewportParseUTF16Length
    }

    override func tearDown() {
        TreeSitterPerformanceConstants.maxSyncContentLength = originalFullParseLimit
        TreeSitterPerformanceConstants.maxViewportParseUTF16Length = originalWindowLimit
        super.tearDown()
    }

    func testViewportInitDoesNotParse() {
        let state = TextViewState(text: "# Hello\n", language: .markdown, parsePolicy: .viewport)
        XCTAssertFalse(state.isSyntaxTreeReady)
        XCTAssertEqual(state.parsePolicy, .viewport)
    }

    func testSmallFileViewportParseCoversWholeDocument() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let delegate = ViewportParseDelegate()
        let finished = expectation(description: "parse finished")
        delegate.onFinish = { finished.fulfill() }
        textView.editorDelegate = delegate

        let text = "# Hello\n\nworld\n"
        let state = TextViewState(text: text, language: .markdown, parsePolicy: .viewport)
        textView.setState(state)
        wait(for: [finished], timeout: 5)

        XCTAssertTrue(textView.isSyntaxTreeReady)
        XCTAssertNotNil(textView.syntaxNode(at: 0))
        XCTAssertNotNil(textView.syntaxNode(at: max((text as NSString).length - 2, 0)))
        let mode = state.languageMode as! TreeSitterInternalLanguageMode
        XCTAssertEqual(mode.parsedUTF16Range, NSRange(location: 0, length: (text as NSString).length))
    }

    func testLargeFileViewportParseDoesNotCoverTheEnd() {
        TreeSitterPerformanceConstants.maxSyncContentLength = 80
        TreeSitterPerformanceConstants.maxViewportParseUTF16Length = 80
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 80))
        let delegate = ViewportParseDelegate()
        let finished = expectation(description: "parse finished")
        delegate.onFinish = { finished.fulfill() }
        textView.editorDelegate = delegate

        let text = String(repeating: "# heading with enough text\n", count: 200)
        let state = TextViewState(text: text, language: .markdown, parsePolicy: .viewport)
        textView.setState(state)
        wait(for: [finished], timeout: 5)

        XCTAssertTrue(textView.isSyntaxTreeReady)
        XCTAssertNotNil(textView.syntaxNode(at: 0))
        let mode = state.languageMode as! TreeSitterInternalLanguageMode
        let parsed = mode.parsedUTF16Range
        XCTAssertNotNil(parsed)
        XCTAssertLessThan(parsed!.length, (text as NSString).length)
        XCTAssertNil(textView.syntaxNode(at: (text as NSString).length - 2))
    }

    func testReparsingALaterWindowCoversTheEnd() {
        TreeSitterPerformanceConstants.maxSyncContentLength = 80
        TreeSitterPerformanceConstants.maxViewportParseUTF16Length = 80
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 80))
        let delegate = ViewportParseDelegate()
        let finished = expectation(description: "initial parse finished")
        delegate.onFinish = { finished.fulfill() }
        textView.editorDelegate = delegate

        let text = String(repeating: "# heading with enough text\n", count: 200)
        let nsText = text as NSString
        let state = TextViewState(text: text, language: .markdown, parsePolicy: .viewport)
        textView.setState(state)
        wait(for: [finished], timeout: 5)

        let mode = state.languageMode as! TreeSitterInternalLanguageMode
        let initial = mode.parsedUTF16Range
        XCTAssertNotNil(initial)
        XCTAssertLessThan(initial!.length, nsText.length)
        XCTAssertNil(textView.syntaxNode(at: nsText.length - 2))

        let bottomWindow = ViewportParseWindow.utf16Range(
            lineManager: state.lineManager,
            stringLength: nsText.length,
            viewport: CGRect(x: 0, y: 10_000, width: 400, height: 80),
            overscanScreens: 0,
            fullParseLimit: 80,
            maxWindowLength: 80
        )
        XCTAssertGreaterThan(bottomWindow.location, initial!.length)

        // Move the real viewport to match the window we are about to request directly. A
        // deferred layout flush from the *initial* parse (scheduled to flush pending Metal
        // presentation; see `TextInputView.scheduleDeferredLayoutIfNeeded`) can still be
        // pending here and will run `ensureViewportSyntaxParse()` against whatever the live
        // viewport is once AppKit finally lays the view out. If the viewport were left at its
        // unset `.zero` value while we ask the language mode to parse a range far past it, that
        // catch-up layout pass would see the *actual* (still top-of-document) viewport, decide
        // the newly-parsed bottom window doesn't cover what's on screen, and silently reparse
        // back to the top — undoing the call below. Scrolling first keeps the live viewport
        // consistent with `bottomWindow` so any such reconciliation agrees with it instead.
        textView.contentOffset = CGPoint(x: 0, y: 10_000)

        let expanded = expectation(description: "later window parsed")
        mode.parse(coveringUTF16Range: bottomWindow) { _ in
            expanded.fulfill()
        }
        wait(for: [expanded], timeout: 5)
        XCTAssertTrue(mode.parsedRangeContains(NSRange(location: nsText.length - 2, length: 1)))
        XCTAssertNotNil(textView.syntaxNode(at: nsText.length - 2))
        XCTAssertEqual(delegate.finishCount, 1)
    }

    /// Assigning `contentOffset` (the real scroll path) must expand the parsed window. An empty
    /// visible range at location 0 is contained by the leading window, so this uses a y-offset
    /// well past the first screen rather than `contentSize.height - frame.height`, which can be
    /// only a few points in a headless test before content size has settled.
    func testScrollingExpandsViewportParse() {
        TreeSitterPerformanceConstants.maxSyncContentLength = 80
        TreeSitterPerformanceConstants.maxViewportParseUTF16Length = 80
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 80))
        let delegate = ViewportParseDelegate()
        let finished = expectation(description: "initial parse finished")
        delegate.onFinish = { finished.fulfill() }
        textView.editorDelegate = delegate

        let text = String(repeating: "# heading with enough text\n", count: 200)
        let nsText = text as NSString
        let state = TextViewState(text: text, language: .markdown, parsePolicy: .viewport)
        textView.setState(state)
        wait(for: [finished], timeout: 5)

        let mode = state.languageMode as! TreeSitterInternalLanguageMode
        let initial = mode.parsedUTF16Range
        XCTAssertNotNil(initial)
        XCTAssertLessThan(initial!.length, nsText.length)
        XCTAssertNil(textView.syntaxNode(at: nsText.length - 2))

        textView.contentOffset = CGPoint(x: 0, y: 10_000)
        XCTAssertGreaterThan(textView.contentOffset.y, 50)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !mode.parsedRangeContains(NSRange(location: nsText.length - 2, length: 1)) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            mode.parsedRangeContains(NSRange(location: nsText.length - 2, length: 1)),
            "scrolling should reparse the window at the new viewport, not stay on \(String(describing: mode.parsedUTF16Range))"
        )
        XCTAssertNotNil(textView.syntaxNode(at: nsText.length - 2))
        XCTAssertEqual(delegate.finishCount, 1)
    }

    func testLoadDefaultsToViewport() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "# Hello\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try await TextViewState.load(contentsOf: url, language: .markdown)
        XCTAssertEqual(loaded.parsePolicy, .viewport)
        XCTAssertFalse(loaded.isSyntaxTreeReady)
    }
}

private final class ViewportParseDelegate: TextViewDelegate {
    private(set) var finishCount = 0
    var onFinish: (() -> Void)?

    func textViewDidFinishSyntaxParse(_ textView: TextView) {
        finishCount += 1
        onFinish?()
    }
}
