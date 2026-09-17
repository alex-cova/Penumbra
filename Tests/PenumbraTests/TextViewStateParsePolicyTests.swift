import AppKit
import XCTest
import PenumbraMarkdownLanguage
@testable import Penumbra

@MainActor
final class TextViewStateParsePolicyTests: XCTestCase {
    func testEagerInitHasReadySyntaxTree() {
        let state = TextViewState(text: "# Hello\n", language: .markdown)
        XCTAssertTrue(state.isSyntaxTreeReady)
        XCTAssertGreaterThan(state.lineManager.lineCount, 0)
    }

    func testDeferredInitDoesNotParse() {
        let state = TextViewState(
            text: "# Hello\n\nworld\n",
            language: .markdown,
            parsePolicy: .deferred
        )
        XCTAssertFalse(state.isSyntaxTreeReady)
        if case .unknown = state.detectedIndentStrategy {
        } else {
            XCTFail("deferred init should leave indent strategy unknown")
        }
        XCTAssertGreaterThan(state.lineManager.lineCount, 1)
        XCTAssertEqual(state.detectedLineEndings, .lf)
    }

    func testDeferredSetStatePaintsBeforeParseAndNotifiesWhenReady() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let delegate = SyntaxParseDelegate()
        let finished = expectation(description: "parse finished")
        delegate.onFinish = { finished.fulfill() }
        textView.editorDelegate = delegate

        let state = TextViewState(text: "# Hello\n", language: .markdown, parsePolicy: .deferred)
        XCTAssertFalse(state.isSyntaxTreeReady)
        textView.setState(state)
        XCTAssertEqual(textView.text, "# Hello\n")
        XCTAssertFalse(textView.isSyntaxTreeReady)

        wait(for: [finished], timeout: 5)
        XCTAssertTrue(textView.isSyntaxTreeReady)
        XCTAssertTrue(state.isSyntaxTreeReady)
        XCTAssertNotNil(textView.syntaxNode(at: 0))
    }

    func testEagerSetStateDoesNotPostParseCallback() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let delegate = SyntaxParseDelegate()
        delegate.onFinish = {
            XCTFail("eager setState should not fire textViewDidFinishSyntaxParse")
        }
        textView.editorDelegate = delegate
        textView.setState(TextViewState(text: "# Hello\n", language: .markdown))
        XCTAssertTrue(textView.isSyntaxTreeReady)

        let settled = expectation(description: "run loop settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(delegate.finishCount, 0)
    }

    func testCancelledDeferredParseDoesNotNotify() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let delegate = SyntaxParseDelegate()
        delegate.onFinish = {
            XCTFail("cancelled parse should not fire textViewDidFinishSyntaxParse")
        }
        textView.editorDelegate = delegate

        let text = String(repeating: "# heading\n\nparagraph with **bold** text\n", count: 8_000)
        let state = TextViewState(text: text, language: .markdown, parsePolicy: .deferred)
        textView.setState(state)
        textView.cancelSyntaxParse()

        let settled = expectation(description: "cancel settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(delegate.finishCount, 0)
        XCTAssertFalse(textView.isSyntaxTreeReady)
    }

    func testStaleDeferredParseDoesNotNotifyForReplacedState() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let delegate = SyntaxParseDelegate()
        let finished = expectation(description: "second parse finished")
        delegate.onFinish = { finished.fulfill() }
        textView.editorDelegate = delegate

        let first = TextViewState(
            text: String(repeating: "# a long first document\n", count: 8_000),
            language: .markdown,
            parsePolicy: .deferred
        )
        let second = TextViewState(text: "# second\n", language: .markdown, parsePolicy: .deferred)
        textView.setState(first)
        textView.setState(second)

        wait(for: [finished], timeout: 5)
        XCTAssertEqual(textView.text, "# second\n")
        XCTAssertTrue(textView.isSyntaxTreeReady)
        XCTAssertEqual(delegate.finishCount, 1)
    }

    func testAssigningTextOnHighlightedViewDefersParse() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.setState(TextViewState(text: "# Hello\n", language: .markdown))
        XCTAssertTrue(textView.isSyntaxTreeReady)

        let delegate = SyntaxParseDelegate()
        let finished = expectation(description: "reparse finished")
        delegate.onFinish = { finished.fulfill() }
        textView.editorDelegate = delegate
        textView.text = "# Replaced\n"
        XCTAssertFalse(textView.isSyntaxTreeReady)
        XCTAssertEqual(textView.text, "# Replaced\n")

        wait(for: [finished], timeout: 5)
        XCTAssertTrue(textView.isSyntaxTreeReady)
        XCTAssertNotNil(textView.syntaxNode(at: 0))
    }

    func testAssigningTextOnPlainTextViewDoesNotPostParseCallback() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let delegate = SyntaxParseDelegate()
        delegate.onFinish = {
            XCTFail("plain-text assignment should not fire textViewDidFinishSyntaxParse")
        }
        textView.editorDelegate = delegate
        textView.text = "hello"
        XCTAssertTrue(textView.isSyntaxTreeReady)

        let settled = expectation(description: "run loop settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(delegate.finishCount, 0)
    }

    func testTypingDuringDeferredParseDoesNotWaitForTreeAndRestartsParse() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let delegate = SyntaxParseDelegate()
        let finished = expectation(description: "parse finished after edit")
        delegate.onFinish = { finished.fulfill() }
        textView.editorDelegate = delegate

        let text = String(repeating: "# heading\n\nparagraph with **bold** text\n", count: 8_000)
        let state = TextViewState(text: text, language: .markdown, parsePolicy: .deferred)
        textView.setState(state)
        XCTAssertFalse(textView.isSyntaxTreeReady)

        let started = CFAbsoluteTimeGetCurrent()
        textView.replace(NSRange(location: 0, length: 0), withText: "X")
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        XCTAssertLessThan(elapsed, 0.1, "typing must not wait for the in-flight parse")
        XCTAssertTrue(textView.text.hasPrefix("X# heading"))
        XCTAssertFalse(textView.isSyntaxTreeReady)

        wait(for: [finished], timeout: 10)
        XCTAssertTrue(textView.isSyntaxTreeReady)
        XCTAssertTrue(textView.text.hasPrefix("X# heading"))
        XCTAssertNotNil(textView.syntaxNode(at: 0))
    }

    func testStateBuilderDefaultsToViewportParse() {
        let prepared = PenumbraStateBuilder.makeState(text: "# Hello\n", language: .markdown)
        XCTAssertEqual(prepared.state.parsePolicy, .viewport)
        XCTAssertFalse(prepared.state.isSyntaxTreeReady)
    }

    func testStateBuilderLoadUsesMappedIngestAndViewportParse() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "# Hello from disk\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let prepared = try await PenumbraStateBuilder.load(contentsOf: url, language: .markdown)
        XCTAssertEqual(prepared.state.parsePolicy, .viewport)
        XCTAssertFalse(prepared.state.isSyntaxTreeReady)
        XCTAssertEqual(prepared.state.stringView.string as String, "# Hello from disk\n")
        XCTAssertGreaterThan(prepared.state.lineManager.lineCount, 0)
    }

    func testEagerFileBackedLoadParsesWithoutMaterializingUTF16() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "# Hello\n\nworld\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = try await TextViewState.load(contentsOf: url, language: .markdown, parsePolicy: .eager)
        XCTAssertTrue(state.isSyntaxTreeReady)
        XCTAssertEqual(state.stringView.materializeCount, 0)
        XCTAssertTrue(state.stringView.isFileBacked)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.setState(state)
        XCTAssertNotNil(textView.syntaxNode(at: 0))
    }
}

private final class SyntaxParseDelegate: TextViewDelegate {
    private(set) var finishCount = 0
    var onFinish: (() -> Void)?

    func textViewDidFinishSyntaxParse(_ textView: TextView) {
        finishCount += 1
        onFinish?()
    }
}
