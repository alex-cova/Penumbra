import AppKit
import PenumbraLanguages
import XCTest
@testable import Penumbra

/// An asynchronous line highlight is computed against the line's byte range as it was when the
/// request was made. If the text changes before the result is applied (an undo above the line
/// moves it without changing its text, so nothing cancels the request), the tokens land shifted:
/// the result must be dropped and the line asked for again.
@MainActor
final class StaleAsyncHighlightTests: XCTestCase {
    func testAHighlightFinishingAfterAnEditIsDropped() throws {
        let source = "const a = 1;\nfunction f(x) {}\n"
        let stringView = StringView(string: source)
        let lineManager = LineManager(stringView: stringView)
        lineManager.rebuild()
        let mode = TreeSitterInternalLanguageMode(
            language: TreeSitterLanguage.javaScript.internalLanguage,
            languageProvider: nil,
            stringView: stringView,
            lineManager: lineManager
        )
        mode.parse()
        let queue = OperationQueue()
        queue.isSuspended = true
        let highlighter = TreeSitterSyntaxHighlighter(stringView: stringView, languageMode: mode, operationQueue: queue)
        highlighter.theme = DefaultTheme()

        let line = lineManager.line(atRow: 1)
        let text = (source as NSString).substring(with: NSRange(location: line.location, length: line.data.totalLength))
        let attributed = NSMutableAttributedString(string: text, attributes: [.foregroundColor: NSColor.textColor])
        let before = NSAttributedString(attributedString: attributed)
        let input = LineSyntaxHighlighterInput(attributedString: attributed, byteRange: line.data.totalByteRange)

        final class Box: @unchecked Sendable { var result: Result<Void, Error>? }
        let box = Box()
        highlighter.syntaxHighlight(input) { box.result = $0 }
        // The buffer changes while the request waits (the tree is left as it was, like a parse
        // that has not caught up yet).
        stringView.replaceText(in: NSRange(location: 0, length: 0), with: "/*")
        queue.isSuspended = false
        queue.waitUntilAllOperationsAreFinished()
        let deadline = Date().addingTimeInterval(2)
        while box.result == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        let outcome = try XCTUnwrap(box.result)
        guard case .failure(TreeSitterSyntaxHighlighterError.textChanged) = outcome else {
            return XCTFail("expected the stale highlight to be dropped, got \(outcome)")
        }
        XCTAssertTrue(attributed.isEqual(to: before), "a stale highlight was painted")
    }
}
