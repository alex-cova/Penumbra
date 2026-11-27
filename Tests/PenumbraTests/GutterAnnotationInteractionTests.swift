import XCTest
import AppKit
@testable import Penumbra

/// Clicks, hover, tint, emphasis and highlight of the annotation column, through the real
/// window hit test (the gutter container passes events through except over its interactive rect).
@MainActor
final class GutterAnnotationInteractionTests: XCTestCase {
    nonisolated(unsafe) private var window: NSWindow!

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private let red = GutterAnnotationTint(red: 1, green: 0, blue: 0)

    private func annotation(_ id: Int, tint: GutterAnnotationTint? = nil, emphasized: Bool = false) -> GutterAnnotation {
        GutterAnnotation(id: id, text: "author \(id)", tooltip: "commit \(id)", tint: tint, isEmphasized: emphasized)
    }

    private func makeTextView(_ text: String = "one\ntwo\nthree\nfour") -> TextView {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        textView.theme = DefaultTheme()
        textView.showLineNumbers = true
        textView.text = text
        window.contentView = textView
        textView.layoutSubtreeIfNeeded()
        return textView
    }

    /// A new column width reaches the layout on the next main-queue turn.
    private func settle(_ textView: TextView) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        textView.layoutSubtreeIfNeeded()
    }

    private func annotationView(in textView: TextView) throws -> GutterAnnotationView {
        try XCTUnwrap(firstSubview(of: GutterAnnotationView.self, in: textView))
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        for subview in view.subviews {
            if let match = subview as? T ?? firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    /// The window point inside the annotation column, `dy` points below the top of `row`.
    private func columnPoint(row: Int, dy: CGFloat = 6, in textView: TextView) throws -> CGPoint {
        let view = try annotationView(in: textView)
        let lineManager = try XCTUnwrap(view.lineManager)
        let y = view.textContainerInsetTop + lineManager.yPosition(ofRow: row) + dy - view.frame.minY
        return view.convert(CGPoint(x: 10, y: y), to: nil)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        if type == .mouseExited {
            return try XCTUnwrap(NSEvent.enterExitEvent(
                with: type, location: point, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
            ))
        }
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func hitView(at windowPoint: CGPoint) throws -> NSView {
        let frameView = try XCTUnwrap(window.contentView?.superview)
        return try XCTUnwrap(frameView.hitTest(frameView.convert(windowPoint, from: nil)))
    }

    // MARK: - Clicks

    func testAClickOnARowReachesTheHandlerWithItsAnnotation() throws {
        let textView = makeTextView()
        textView.setGutterAnnotations([annotation(1), annotation(1), annotation(2), annotation(3)])
        settle(textView)
        var clicks: [GutterAnnotationClick] = []
        textView.gutterAnnotationClickHandler = { clicks.append($0); return true }

        let point = try columnPoint(row: 2, in: textView)
        let view = try annotationView(in: textView)
        XCTAssertTrue(try hitView(at: point) === view, "the click must reach the column")
        view.mouseDown(with: try event(.leftMouseDown, at: point))

        XCTAssertEqual(clicks.map(\.line), [3])
        XCTAssertEqual(clicks.map(\.annotation.id), [2])
        XCTAssertEqual(clicks.map(\.isSecondary), [false])
        let click = try XCTUnwrap(clicks.first)
        XCTAssertTrue(click.anchorView === view)
        XCTAssertTrue(click.anchorView.bounds.contains(CGPoint(x: click.rect.midX, y: click.rect.midY)))
        XCTAssertNotNil(click.event)
    }

    func testARightClickAndAControlClickAreSecondary() throws {
        let textView = makeTextView()
        textView.setGutterAnnotations([annotation(1), annotation(2), annotation(3), annotation(4)])
        settle(textView)
        var clicks: [GutterAnnotationClick] = []
        textView.gutterAnnotationClickHandler = { clicks.append($0); return true }

        let point = try columnPoint(row: 1, in: textView)
        let view = try annotationView(in: textView)
        XCTAssertTrue(try hitView(at: point) === view, "the click must reach the column")
        view.rightMouseDown(with: try event(.rightMouseDown, at: point))
        view.mouseDown(with: try event(.leftMouseDown, at: point, flags: .control))
        XCTAssertEqual(clicks.map(\.line), [2, 2])
        XCTAssertEqual(clicks.map(\.isSecondary), [true, true])
    }

    func testAClickBelowTheLastLineIsNotARow() throws {
        let textView = makeTextView("one\ntwo")
        textView.setGutterAnnotations([annotation(1), annotation(2)])
        settle(textView)
        var clicks = 0
        textView.gutterAnnotationClickHandler = { _ in clicks += 1; return true }
        let view = try annotationView(in: textView)
        let below = view.convert(CGPoint(x: 10, y: view.bounds.height - 4), to: nil)
        view.mouseDown(with: try event(.leftMouseDown, at: below))
        XCTAssertEqual(clicks, 0)
    }

    func testABlankRowDoesNotReachTheHandler() throws {
        let textView = makeTextView()
        textView.setGutterAnnotations([annotation(1), nil, annotation(2), annotation(3)])
        settle(textView)
        var clicks = 0
        textView.gutterAnnotationClickHandler = { _ in clicks += 1; return true }
        let point = try columnPoint(row: 1, in: textView)
        try annotationView(in: textView).mouseDown(with: try event(.leftMouseDown, at: point))
        XCTAssertEqual(clicks, 0)
    }

    // MARK: - Hover

    func testHoverFiresOncePerAnnotationAndOnceMoreOnLeaving() throws {
        let textView = makeTextView()
        textView.setGutterAnnotations([annotation(1), annotation(1), annotation(2), annotation(3)])
        settle(textView)
        var hovered: [Int?] = []
        textView.gutterAnnotationHoverHandler = { hovered.append($0?.annotation.id) }
        let view = try annotationView(in: textView)

        for row in [0, 0, 1, 2, 2, 3] {
            let point = try columnPoint(row: row, in: textView)
            view.mouseMoved(with: try event(.mouseMoved, at: point))
        }
        // Rows 0 and 1 are one commit: the move between them is not a new hover.
        XCTAssertEqual(hovered, [1, 2, 3])

        view.mouseExited(with: try event(.mouseExited, at: try columnPoint(row: 3, in: textView)))
        XCTAssertEqual(hovered, [1, 2, 3, nil])
        // Leaving again says nothing more.
        view.mouseExited(with: try event(.mouseExited, at: try columnPoint(row: 3, in: textView)))
        XCTAssertEqual(hovered, [1, 2, 3, nil])
    }

    func testReplacingTheAnnotationsEndsAHover() throws {
        let textView = makeTextView()
        textView.setGutterAnnotations([annotation(1), annotation(2), annotation(3), annotation(4)])
        settle(textView)
        var hovered: [Int?] = []
        textView.gutterAnnotationHoverHandler = { hovered.append($0?.annotation.id) }
        let point = try columnPoint(row: 1, in: textView)
        try annotationView(in: textView).mouseMoved(with: try event(.mouseMoved, at: point))
        XCTAssertEqual(hovered, [2])
        textView.setGutterAnnotations([annotation(5), annotation(6), annotation(7), annotation(8)])
        XCTAssertEqual(hovered, [2, nil])
    }

    func testTheTooltipStepsAsideWhileTheHostFollowsTheHover() throws {
        let textView = makeTextView()
        textView.setGutterAnnotations([annotation(1), annotation(2), annotation(3), annotation(4)])
        settle(textView)
        let view = try annotationView(in: textView)
        let local = view.convert(try columnPoint(row: 1, in: textView), from: nil)
        XCTAssertEqual(view.view(view, stringForToolTip: 0, point: local, userData: nil), "commit 2")
        textView.gutterAnnotationHoverHandler = { _ in }
        XCTAssertEqual(view.view(view, stringForToolTip: 0, point: local, userData: nil), "")
    }

    // MARK: - Tint, emphasis, highlight

    func testTintAndEmphasisSurviveEditsToOtherLines() {
        let textView = makeTextView("one\ntwo\nthree")
        textView.setGutterAnnotations(
            [annotation(1, tint: red, emphasized: true), annotation(2, tint: red), annotation(3)],
            edited: GutterAnnotation(id: -1, text: "Not Committed Yet"))
        let two = (textView.text as NSString).range(of: "two")
        textView.replace(NSRange(location: two.location, length: 0), withText: "X")
        XCTAssertEqual(textView.gutterAnnotationForTesting(atRow: 0)?.tint, red)
        XCTAssertEqual(textView.gutterAnnotationForTesting(atRow: 0)?.isEmphasized, true)
        XCTAssertEqual(textView.gutterAnnotationForTesting(atRow: 1)?.id, -1)
        XCTAssertNil(textView.gutterAnnotationForTesting(atRow: 1)?.tint)
    }

    func testEmphasisAddsTheMarkAndWidth() {
        let plain = annotation(1)
        let marked = annotation(1, emphasized: true)
        XCTAssertEqual(plain.displayText, "author 1")
        XCTAssertEqual(marked.displayText, "author 1*")
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        XCTAssertGreaterThan(GutterAnnotationView.columnWidth(for: [marked], font: font),
                             GutterAnnotationView.columnWidth(for: [plain], font: font))
        XCTAssertEqual(GutterAnnotation(id: 2, text: "", isEmphasized: true).displayText, "")
    }

    /// The colour drawn `x` points into the annotation column at the middle of `row`.
    private func pixel(row: Int, x: CGFloat, in textView: TextView) throws -> NSColor? {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        settle(textView)
        let view = try annotationView(in: textView)
        let lineManager = try XCTUnwrap(view.lineManager)
        let lineHeight = lineManager.lineInfo(atRow: row).lineHeight
        let local = CGPoint(x: x, y: view.textContainerInsetTop + lineManager.yPosition(ofRow: row) + lineHeight / 2 - view.frame.minY)
        let point = view.convert(local, to: textView)
        let rep = try XCTUnwrap(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / textView.bounds.width
        return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
    }

    func testATintPaintsItsRowsAndOnlyThose() throws {
        let textView = makeTextView()
        textView.setGutterAnnotations([annotation(1, tint: red), annotation(1, tint: red), annotation(2), annotation(3)])
        let tinted = try XCTUnwrap(pixel(row: 1, x: 2, in: textView))
        // The bitmap's colour space shifts pure red a little; it is still plainly red.
        XCTAssertGreaterThan(tinted.redComponent, 0.8)
        XCTAssertLessThan(tinted.greenComponent, 0.45)
        XCTAssertLessThan(tinted.blueComponent, 0.45)
        let plain = try XCTUnwrap(pixel(row: 2, x: 2, in: textView))
        XCTAssertFalse(plain.redComponent > 0.8 && plain.greenComponent < 0.45, "an untinted row must not be red")
        XCTAssertGreaterThan(tinted.redComponent - tinted.greenComponent, plain.redComponent - plain.greenComponent + 0.3)
    }

    func testHighlightingRepaintsWithoutMovingTheColumn() throws {
        let textView = makeTextView()
        textView.setGutterAnnotations([annotation(1), annotation(1), annotation(2), annotation(3)])
        settle(textView)
        let width = textView.gutterWidth
        let before = try XCTUnwrap(pixel(row: 0, x: 2, in: textView))
        textView.highlightedGutterAnnotationID = 1
        let during = try XCTUnwrap(pixel(row: 0, x: 2, in: textView))
        let otherRow = try XCTUnwrap(pixel(row: 2, x: 2, in: textView))
        XCTAssertNotEqual(before, during)
        XCTAssertEqual(before, otherRow, "only the highlighted commit's rows change")
        XCTAssertEqual(textView.gutterWidth, width, accuracy: 0.01)
        textView.highlightedGutterAnnotationID = nil
        XCTAssertEqual(try XCTUnwrap(pixel(row: 0, x: 2, in: textView)), before)
    }
}
