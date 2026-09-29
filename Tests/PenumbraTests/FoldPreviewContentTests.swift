@preconcurrency import AppKit
import PenumbraLanguages
import XCTest
@testable import Penumbra

@MainActor
final class FoldPreviewContentTests: XCTestCase {
    private let source = """
    function check(details) {
      if (details.isEmpty()) {
        throw new Error("empty");
      }
      return details;
    }

    """

    func testPreviewHasHeaderHiddenLinesAndClosingBracket() throws {
        let content = try makeContent(headerRow: 1)
        XCTAssertEqual(content.lines.map(\.number), [2, 3, 4])
        XCTAssertEqual(content.lines.map { $0.text.string }, [
            "  if (details.isEmpty()) {",
            "    throw new Error(\"empty\");",
            "  }"
        ])
        XCTAssertFalse(content.isTruncated)
        XCTAssertGreaterThan(content.rowHeight, 0)
    }

    func testPreviewIsSyntaxHighlighted() throws {
        let content = try makeContent(headerRow: 1)
        let throwLine = content.lines[1].text
        let keywordColor = throwLine.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        let plainColor = throwLine.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(keywordColor)
        XCTAssertNotEqual(keywordColor, plainColor, "`throw` should be coloured as a keyword")
    }

    func testPreviewIsTruncatedToTheMaximumLineCount() throws {
        let content = try makeContent(headerRow: 0, maximumLines: 3)
        XCTAssertEqual(content.lines.count, 3)
        XCTAssertTrue(content.isTruncated)
    }

    private func makeContent(headerRow: Int, maximumLines: Int = 20) throws -> FoldPreviewContent {
        let frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: frame)
        window.contentView = textView
        textView.isLineFoldingEnabled = true
        textView.languageConfigurationOverride = LanguageConfiguration.javaScript
        textView.setState(TextViewState(text: source, language: .javaScript))
        let deadline = Date().addingTimeInterval(5)
        while (!textView.isSyntaxTreeReady || textView.foldLineRangesForTesting.isEmpty), Date() < deadline {
            textView.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        for _ in 0 ..< 10 {
            textView.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return try XCTUnwrap(textView.foldPreviewContentForTesting(headerRow: headerRow, maximumLines: maximumLines))
    }
}
