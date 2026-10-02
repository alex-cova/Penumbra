import XCTest
import AppKit
@testable import Penumbra

@MainActor
final class LineNumberViewTests: XCTestCase {
    private var window: NSWindow!

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private func makeTextView(lineCount: Int) -> TextView {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        textView.theme = DefaultTheme()
        textView.showLineNumbers = true
        textView.text = (1...lineCount).map { "line \($0)" }.joined(separator: "\n")
        window.contentView = textView
        textView.layoutSubtreeIfNeeded()
        return textView
    }

    private func lineNumberViews(in view: NSView) -> [LineNumberView] {
        view.subviews.flatMap { subview -> [LineNumberView] in
            if let lineNumberView = subview as? LineNumberView { return [lineNumberView] }
            return lineNumberViews(in: subview)
        }
    }

    private func shownLineNumberView(_ number: Int, in textView: TextView) -> LineNumberView? {
        lineNumberViews(in: textView).first { !$0.isHidden && $0.text == "\(number)" }
    }

    private final class CountingLabel: EditorLabel {
        var drawnWidths: [CGFloat] = []

        override func draw(_ dirtyRect: NSRect) {
            drawnWidths.append(bounds.width)
            super.draw(dirtyRect)
        }
    }

    private func settle() {
        for _ in 0 ..< 3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.layoutIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
    }

    private func makeLayerBackedWindow() -> EditorView {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let container = EditorView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        // Layer-backed like the gutter.
        container.wantsLayer = true
        window.contentView = container
        window.orderFrontRegardless()
        return container
    }

    func testLabelRedrawsAtANewSize() {
        let container = makeLayerBackedWindow()
        let label = CountingLabel()
        label.textAlignment = .right
        label.text = "86"
        label.font = DefaultTheme().lineNumberFont
        container.addSubview(label)
        label.frame = CGRect(x: 10, y: 10, width: 26, height: 17)
        settle()
        XCTAssertEqual(label.drawnWidths.last, 26)
        // Other columns narrow the digits. The old drawing, stretched to the new width, squeezed
        // the number and moved it off the column's shared right edge.
        label.frame.size.width = 21
        settle()
        XCTAssertEqual(label.drawnWidths.last, 21)
    }

    func testLineNumberLabelTakesANewWidthAtOnce() throws {
        let container = makeLayerBackedWindow()
        let lineNumberView = LineNumberView()
        container.addSubview(lineNumberView)
        lineNumberView.text = "86"
        lineNumberView.font = DefaultTheme().lineNumberFont
        lineNumberView.frame = CGRect(x: 10, y: 10, width: 26, height: 17)
        settle()
        let label = try XCTUnwrap(lineNumberView.subviews.first as? EditorLabel)
        // Not left to a later layout pass, which may come after the label was drawn.
        lineNumberView.frame.size.width = 21
        XCTAssertEqual(label.frame.width, 21)
    }

    func testDecorationReplacesItsLineNumberOnly() throws {
        let textView = makeTextView(lineCount: 5)
        let plainWidth = textView.gutterWidth
        textView.setGutterDecorations([
            GutterDecoration(line: 2, symbolName: "circle.fill", accessibilityLabel: "Breakpoint", placement: .lineNumber)
        ])
        textView.layoutSubtreeIfNeeded()
        XCTAssertEqual(textView.gutterWidth, plainWidth, "no decoration column for it")
        let decorated = try XCTUnwrap(shownLineNumberView(2, in: textView))
        XCTAssertEqual(decorated.decoration?.line, 2)
        XCTAssertEqual(decorated.subviews.filter { !$0.isHidden }.count, 1)
        XCTAssertFalse(decorated.subviews.first { !$0.isHidden } is EditorLabel, "the number is hidden")
        let plain = try XCTUnwrap(shownLineNumberView(3, in: textView))
        XCTAssertNil(plain.decoration)
        XCTAssertTrue(plain.subviews.first { !$0.isHidden } is EditorLabel)
        // Removing it brings the number back.
        textView.setGutterDecorations([])
        textView.layoutSubtreeIfNeeded()
        XCTAssertNil(try XCTUnwrap(shownLineNumberView(2, in: textView)).decoration)
    }

    func testDecorationFollowsItsLineWhenALineIsInsertedAbove() throws {
        let textView = makeTextView(lineCount: 5)
        textView.gutterDecorationsDidMove = { _ in }
        textView.setGutterDecorations([
            GutterDecoration(line: 3, symbolName: "circle.fill", accessibilityLabel: "Breakpoint", placement: .lineNumber)
        ])
        textView.layoutSubtreeIfNeeded()
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.insertText("new\n")
        textView.layoutSubtreeIfNeeded()
        XCTAssertNil(try XCTUnwrap(shownLineNumberView(3, in: textView)).decoration)
        XCTAssertEqual(try XCTUnwrap(shownLineNumberView(4, in: textView)).decoration?.line, 4)
    }

    func testWithoutLineNumbersTheDecorationGoesInTheColumn() throws {
        let textView = makeTextView(lineCount: 5)
        textView.setGutterDecorations([
            GutterDecoration(line: 2, symbolName: "circle.fill", accessibilityLabel: "Breakpoint", placement: .lineNumber)
        ])
        textView.showLineNumbers = false
        textView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(textView.gutterWidth, 0, "the decoration column holds it")
        textView.showLineNumbers = true
        textView.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(shownLineNumberView(2, in: textView)).decoration?.line, 2)
    }
}
