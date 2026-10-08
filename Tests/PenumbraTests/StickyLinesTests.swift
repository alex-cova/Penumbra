@preconcurrency import AppKit
import TestTreeSitterLanguages
import XCTest
@testable import Penumbra

/// Sticky lines pin the headers of the blocks around the first visible line. The scope resolver
/// is pure; the view tests scroll a real `TextView` over a JavaScript class.
@MainActor
final class StickyLinesTests: XCTestCase {
    private let nested = """
    class Widget {
      render(items) {
        for (const item of items) {
          if (item > 1) {
            use(item);
          } else if (item > 0) {
            skip(item);
          }
        }
      }
    }
    """

    private func scopes(_ text: String, row: Int) throws -> [StickyScope] {
        let mode = LanguageModeFactory.javaScriptLanguageMode(text: text)
        let root = try XCTUnwrap(mode.rootSyntaxNode)
        return StickyScopeResolver.scopes(containingRow: row, root: root, configuration: .javaScript)
    }

    // MARK: - Resolver

    func testScopesAroundANestedStatementAreOutermostFirst() throws {
        let found = try scopes(nested, row: 4)
        XCTAssertEqual(found.map(\.headerRow), [0, 1, 2, 3])
        XCTAssertEqual(found.map(\.endRow), [10, 9, 8, 7], "an `if` with an `else if` ends where its last branch does")
    }

    func testElseIfDoesNotRepeatTheOuterIf() throws {
        let found = try scopes(nested, row: 6)
        XCTAssertEqual(found.map(\.headerRow), [0, 1, 2, 5], "the `if` on row 3 is the head of the same chain")
    }

    func testRowOnTheHeaderItselfIsNotAboveItself() throws {
        let found = try scopes(nested, row: 1)
        XCTAssertEqual(found.map(\.headerRow), [0])
    }

    func testFirstRowAndOneLineBlocksHaveNoScopes() throws {
        XCTAssertEqual(try scopes(nested, row: 0), [])
        let text = "class A {\n  f() { return 1 }\n  g() { return 2 }\n}"
        XCTAssertEqual(try scopes(text, row: 2).map(\.headerRow), [0], "single-line methods are not blocks to pin")
    }

    func testLanguageWithoutStickyTypesPinsOnlyDeclarations() throws {
        let mode = LanguageModeFactory.javaScriptLanguageMode(text: nested)
        let root = try XCTUnwrap(mode.rootSyntaxNode)
        var configuration = LanguageConfiguration.javaScript
        configuration.stickyNodeTypes = []
        let found = StickyScopeResolver.scopes(containingRow: 4, root: root, configuration: configuration)
        XCTAssertEqual(found.map(\.headerRow), [0, 1])
    }

    // MARK: - View

    private func makeSource(methods: Int = 6, bodyLines: Int = 40) -> String {
        var lines = ["class Widget {"]
        for method in 0 ..< methods {
            lines.append("  method\(method)(items) {")
            for line in 0 ..< bodyLines {
                lines.append("    use(\(method), \(line));")
            }
            lines.append("  }")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private func makeTextView(source: String, maximum: Int = 5) -> (NSWindow, TextView) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.setState(TextViewState(text: source, theme: DefaultTheme(), language: .javaScript, parsePolicy: .eager))
        textView.languageIdentifier = "javascript"
        textView.maximumStickyLineCount = maximum
        textView.showsStickyLines = true
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.2)
        return (window, textView)
    }

    private func scroll(_ textView: TextView, toRow row: Int) {
        textView.contentOffset = CGPoint(x: 0, y: textView.stickyLinesInput.yPosition(ofRow: row))
        textView.layoutIfNeeded()
    }

    func testNothingIsPinnedAtTheTop() {
        let (window, textView) = makeTextView(source: makeSource())
        defer { window.orderOut(nil) }
        XCTAssertEqual(textView.stickyLineHeaderRowsForTesting, [])
        XCTAssertTrue(textView.stickyLinesViewForTesting.isHidden)
    }

    func testClassAndMethodArePinnedInsideAMethodBody() {
        let (window, textView) = makeTextView(source: makeSource())
        defer { window.orderOut(nil) }
        // method1 starts at row 1 + 42 = 43; its body begins at row 44.
        scroll(textView, toRow: 60)

        XCTAssertEqual(textView.stickyLineHeaderRowsForTesting, [0, 43])
        XCTAssertFalse(textView.stickyLinesViewForTesting.isHidden)
        let height = textView.stickyLinesInput.stickyRowHeight
        XCTAssertEqual(textView.stickyLinesViewForTesting.frame.height, height * 2, accuracy: 0.5)
    }

    func testTurningThemOffHidesThePanel() {
        let (window, textView) = makeTextView(source: makeSource())
        defer { window.orderOut(nil) }
        scroll(textView, toRow: 60)
        XCTAssertFalse(textView.stickyLineHeaderRowsForTesting.isEmpty)

        textView.showsStickyLines = false
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.stickyLinesViewForTesting.isHidden)
    }

    func testMaximumCountKeepsTheInnermostBlocks() {
        let source = """
        class A {
          class B {
            f() {
              if (x) {
        \(String(repeating: "        use();\n", count: 60))      }
            }
          }
        }
        """
        let (window, textView) = makeTextView(source: source, maximum: 2)
        defer { window.orderOut(nil) }
        scroll(textView, toRow: 30)
        XCTAssertEqual(textView.stickyLineHeaderRowsForTesting, [2, 3], "the method and the `if`, not the classes")
    }

    func testClickJumpsToTheHeaderBelowItsAncestors() {
        let (window, textView) = makeTextView(source: makeSource())
        defer { window.orderOut(nil) }
        scroll(textView, toRow: 60)
        XCTAssertEqual(textView.stickyLineHeaderRowsForTesting, [0, 43])

        textView.clickStickyLineForTesting(slot: 1)

        let input = textView.stickyLinesInput
        let location = input.lineManager.location(ofRow: 43)
        XCTAssertEqual(textView.selectedRange.location, location + 2, "the caret goes to the first non-blank character")
        let expectedTop = input.yPosition(ofRow: 43) - input.stickyRowHeight
        XCTAssertEqual(textView.contentOffset.y + textView.adjustedContentInset.top, expectedTop, accuracy: 1)
        XCTAssertEqual(textView.stickyLineHeaderRowsForTesting, [0], "the method header is now on screen, so only the class is pinned")
    }

    func testLastLineIsPushedUpAsItsBlockEnds() {
        let (window, textView) = makeTextView(source: makeSource())
        defer { window.orderOut(nil) }
        let input = textView.stickyLinesInput
        let height = input.stickyRowHeight
        // method1 ends on row 43 + 41 = 84. Put its closing brace half a slot below the pinned
        // method line: the block's end is closing in on the bottom of its slot.
        let top = input.yPosition(ofRow: 85) - height * 1.5
        textView.contentOffset = CGPoint(x: 0, y: top)
        textView.layoutIfNeeded()

        XCTAssertEqual(textView.stickyLineHeaderRowsForTesting, [0, 43])
        let method = textView.stickyLinesViewForTesting.rowViews[1]
        XCTAssertLessThan(method.frame.minY, height - 0.5, "pushed up from its slot")
        XCTAssertGreaterThan(method.frame.minY, 0)
    }

    /// Handles created while scrolling a whole document, with sticky lines on or off.
    private func handlesCreatedScrolling(stickyLines: Bool) -> Int {
        let (window, textView) = makeTextView(source: makeSource(methods: 60, bodyLines: 80))
        defer { window.orderOut(nil) }
        textView.showsStickyLines = stickyLines
        let lineManager = textView.stickyLinesInput.lineManager
        let lineCount = lineManager.lineCount
        lineManager.resetHandleCounters()
        var row = 0
        while row < lineCount {
            scroll(textView, toRow: row)
            row += 7
        }
        return lineManager.handlesCreated
    }

    func testScrollingAFullDocumentCreatesNoLineHandlesForStickyLines() {
        let without = handlesCreatedScrolling(stickyLines: false)
        let with = handlesCreatedScrolling(stickyLines: true)
        XCTAssertLessThanOrEqual(with, without + 50, "sticky lines read rows, they do not take line handles (\(with) vs \(without))")
    }

    func testEditingAHeaderRefreshesThePinnedText() {
        let (window, textView) = makeTextView(source: makeSource())
        defer { window.orderOut(nil) }
        scroll(textView, toRow: 60)
        XCTAssertEqual(textView.stickyLineHeaderRowsForTesting, [0, 43])

        // A line inserted above shifts every row down by one.
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.insertText("// header\n")
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.2)
        scroll(textView, toRow: 61)

        XCTAssertEqual(textView.stickyLineHeaderRowsForTesting, [1, 44])
    }
}
