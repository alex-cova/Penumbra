import XCTest
import AppKit
@testable import Penumbra

@MainActor
final class GutterLineClickTests: XCTestCase {
    private var window: NSWindow!

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private func makeTextView(_ text: String) -> TextView {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        textView.theme = DefaultTheme()
        textView.showLineNumbers = true
        textView.text = text
        window.contentView = textView
        textView.layoutSubtreeIfNeeded()
        return textView
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        for subview in view.subviews {
            if let match = subview as? T ?? firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    /// The window point level with the middle of `row`, `x` points into the gutter.
    private func gutterPoint(row: Int, x: CGFloat, in textView: TextView) throws -> CGPoint {
        let decorations = try XCTUnwrap(firstSubview(of: GutterDecorationView.self, in: textView))
        let lineManager = try XCTUnwrap(decorations.lineManager)
        let y = textView.textContainerInset.top + lineManager.yPosition(ofRow: row) + 6
        let container = try XCTUnwrap(decorations.superview)
        return container.convert(CGPoint(x: x, y: y), to: nil)
    }

    private func hitView(at windowPoint: CGPoint) throws -> NSView {
        let frameView = try XCTUnwrap(window.contentView?.superview)
        return try XCTUnwrap(frameView.hitTest(frameView.convert(windowPoint, from: nil)))
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    func testClickOnALineNumberReachesTheHandlerOnMouseUp() throws {
        let textView = makeTextView("one\ntwo\nthree")
        var clicks: [(Int, Bool)] = []
        textView.gutterLineClickHandler = { clicks.append(($0.line, $0.isSecondary)); return true }
        textView.layoutSubtreeIfNeeded()
        let point = try gutterPoint(row: 1, x: textView.gutterWidth - 4, in: textView)
        let view = try hitView(at: point)
        view.mouseDown(with: try event(.leftMouseDown, at: point))
        XCTAssertTrue(clicks.isEmpty, "reported before mouse-up")
        view.mouseUp(with: try event(.leftMouseUp, at: point))
        XCTAssertEqual(clicks.map(\.0), [2])
        XCTAssertEqual(clicks.map(\.1), [false])
    }

    func testDragFromTheGutterSelectsInsteadOfClicking() throws {
        let textView = makeTextView("one\ntwo\nthree")
        var clicks: [Int] = []
        textView.gutterLineClickHandler = { clicks.append($0.line); return true }
        textView.layoutSubtreeIfNeeded()
        let start = try gutterPoint(row: 0, x: textView.gutterWidth - 4, in: textView)
        let end = try gutterPoint(row: 2, x: textView.gutterWidth + 30, in: textView)
        let view = try hitView(at: start)
        view.mouseDown(with: try event(.leftMouseDown, at: start))
        view.mouseDragged(with: try event(.leftMouseDragged, at: end))
        view.mouseUp(with: try event(.leftMouseUp, at: end))
        XCTAssertTrue(clicks.isEmpty)
        XCTAssertGreaterThan(textView.selectedRange.length, 0)
    }

    func testRightClickOnALineNumberIsSecondary() throws {
        let textView = makeTextView("one\ntwo\nthree")
        var clicks: [(Int, Bool)] = []
        textView.gutterLineClickHandler = { clicks.append(($0.line, $0.isSecondary)); return true }
        textView.layoutSubtreeIfNeeded()
        let point = try gutterPoint(row: 2, x: textView.gutterWidth - 4, in: textView)
        try hitView(at: point).rightMouseDown(with: try event(.rightMouseDown, at: point))
        XCTAssertEqual(clicks.map(\.0), [3])
        XCTAssertEqual(clicks.map(\.1), [true])
    }

    func testUnhandledClickStillPlacesTheCaret() throws {
        let textView = makeTextView("one\ntwo\nthree")
        textView.gutterLineClickHandler = { _ in false }
        textView.layoutSubtreeIfNeeded()
        let point = try gutterPoint(row: 1, x: textView.gutterWidth - 4, in: textView)
        let view = try hitView(at: point)
        view.mouseDown(with: try event(.leftMouseDown, at: point))
        view.mouseUp(with: try event(.leftMouseUp, at: point))
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 0))
    }

    func testEmptyDecorationColumnReportsTheLineAndADecorationKeepsItsHandler() throws {
        let textView = makeTextView("one\ntwo\nthree")
        let plainWidth = textView.gutterWidth
        textView.alwaysShowGutterDecorationColumn = true
        textView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(textView.gutterWidth, plainWidth, "the column stays without decorations")
        var lineClicks: [Int] = []
        var decorationClicks: [Int] = []
        textView.gutterLineClickHandler = { lineClicks.append($0.line); return true }
        textView.gutterDecorationHandler = { decorationClicks.append($0) }
        textView.setGutterDecorations([GutterDecoration(line: 1, symbolName: "play.fill", accessibilityLabel: "Run")])
        textView.layoutSubtreeIfNeeded()
        for row in [0, 2] {
            let point = try gutterPoint(row: row, x: 8, in: textView)
            let view = try hitView(at: point)
            XCTAssertTrue(view is GutterDecorationView, "hit \(view)")
            view.mouseDown(with: try event(.leftMouseDown, at: point))
        }
        XCTAssertEqual(decorationClicks, [1])
        XCTAssertEqual(lineClicks, [3])
    }

    func testClickOnADecorationInPlaceOfALineNumberIsALineClick() throws {
        let textView = makeTextView("one\ntwo\nthree")
        var lineClicks: [Int] = []
        var decorationClicks: [Int] = []
        textView.gutterLineClickHandler = { lineClicks.append($0.line); return true }
        textView.gutterDecorationHandler = { decorationClicks.append($0) }
        textView.setGutterDecorations([
            GutterDecoration(line: 2, symbolName: "circle.fill", accessibilityLabel: "Breakpoint", placement: .lineNumber)
        ])
        textView.layoutSubtreeIfNeeded()
        let point = try gutterPoint(row: 1, x: textView.gutterWidth - 8, in: textView)
        let view = try hitView(at: point)
        view.mouseDown(with: try event(.leftMouseDown, at: point))
        view.mouseUp(with: try event(.leftMouseUp, at: point))
        XCTAssertEqual(lineClicks, [2])
        XCTAssertTrue(decorationClicks.isEmpty)
    }

    func testDecorationsDrawWithoutRetainingLineHandles() throws {
        let text = (1 ... 2000).map { "line \($0)" }.joined(separator: "\n")
        let textView = makeTextView(text)
        let view = try XCTUnwrap(firstSubview(of: GutterDecorationView.self, in: textView))
        textView.setGutterDecorations((1 ... 2000).map {
            GutterDecoration(line: $0, symbolName: "circle.fill", accessibilityLabel: "Breakpoint",
                             tintColor: NSColor.systemRed.cgColor, badgeSymbolName: $0.isMultiple(of: 2) ? "questionmark" : nil)
        })
        textView.layoutSubtreeIfNeeded()
        let lineManager = try XCTUnwrap(view.lineManager)
        let createdBefore = lineManager.handlesCreated
        view.display()
        XCTAssertEqual(lineManager.handlesCreated, createdBefore)
    }

    func testContextMenuAppendsHostItems() {
        let textView = makeTextView("one two")
        textView.selectedRange = NSRange(location: 4, length: 3)
        var contexts: [EditorContextMenuContext] = []
        textView.contextMenuItemsProvider = { context in
            contexts.append(context)
            return [NSMenuItem(title: "Evaluate Expression…", action: nil, keyEquivalent: "")]
        }
        let menu = textView.makeContextMenuForTesting(at: 5)
        XCTAssertEqual(menu.items.last?.title, "Evaluate Expression…")
        XCTAssertTrue(menu.items.dropLast().last?.isSeparatorItem ?? false)
        XCTAssertEqual(contexts.first?.location, 5)
        XCTAssertEqual(contexts.first?.selectedRange, NSRange(location: 4, length: 3))
    }

    func testDecorationsFollowLineEditsAndReportTheMove() {
        let textView = makeTextView("one\ntwo\nthree\nfour")
        textView.setGutterDecorations([
            GutterDecoration(line: 2, symbolName: "circle.fill", accessibilityLabel: "Breakpoint", id: "a"),
            GutterDecoration(line: 4, symbolName: "circle.fill", accessibilityLabel: "Breakpoint", id: "b")
        ])
        var reported: [[String]] = []
        textView.gutterDecorationsDidMove = { reported.append($0.map { "\($0.id ?? "")@\($0.line)" }) }
        // Typing on a line moves nothing and reports nothing.
        textView.replace(NSRange(location: 1, length: 0), withText: "x")
        XCTAssertTrue(reported.isEmpty)
        // A new line above both moves both.
        textView.replace(NSRange(location: 0, length: 0), withText: "zero\n")
        XCTAssertEqual(textView.gutterDecorations.map(\.line), [3, 5])
        XCTAssertEqual(reported.last, ["a@3", "b@5"])
        // Deleting "two\n" (the line holding a) drops it.
        let two = (textView.text as NSString).range(of: "two\n")
        textView.replace(two, withText: "")
        XCTAssertEqual(reported.last, ["b@4"])
    }
}
