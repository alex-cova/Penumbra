@preconcurrency import AppKit
@testable import Penumbra
import XCTest

/// Scrollbar and minimap code preview: the popup shows lines that are off screen, and a click
/// while it is open jumps to the first of those lines.
@MainActor
final class EditorFragmentPreviewTests: XCTestCase {
    private var windows: [NSWindow] = []

    private func makeTextView(
        text: String,
        showMinimap: Bool = false,
        frame: CGRect = CGRect(x: 0, y: 0, width: 500, height: 600)
    ) -> TextView {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: frame.size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = TextView(frame: frame)
        textView.scrollerOverlayForTesting.scrollerStyleOverride = .overlay
        textView.minimapWidth = 100
        textView.showMinimap = showMinimap
        textView.showsScrollers = true
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        textView.setState(TextViewState(text: text, theme: DefaultTheme()))
        textView.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        textView.layoutIfNeeded()
        return textView
    }

    private var tallDocument: String {
        (0 ..< 300).map { "line \($0)" }.joined(separator: "\n")
    }

    private func mouseEvent(_ type: NSEvent.EventType, at localPoint: CGPoint, in view: NSView) -> NSEvent {
        let windowPoint = view.convert(localPoint, to: nil)
        return NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func pumpMainQueue() {
        for _ in 0 ..< 4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: - Geometry

    func testScrollerMapsTheTrackAroundTheKnob() {
        let geometry = ScrollerGeometry(
            trackLength: 600,
            viewportLength: 200,
            contentOffset: 400,
            minimumContentOffset: 0,
            maximumContentOffset: 2000,
            minKnobLength: 24
        )
        XCTAssertEqual(geometry.contentY(atTrackPosition: 0), geometry.minimumContentOffset)

        let justAbove = geometry.knobOrigin - 0.5
        XCTAssertGreaterThan(justAbove, 0)
        let above = geometry.contentY(atTrackPosition: justAbove)
        XCTAssertLessThan(above, geometry.contentOffset)
        XCTAssertGreaterThan(above, geometry.minimumContentOffset)

        let inside = geometry.knobOrigin + geometry.knobLength / 2
        XCTAssertTrue(geometry.isOnKnob(at: inside))
        let onKnob = geometry.contentY(atTrackPosition: inside)
        XCTAssertGreaterThanOrEqual(onKnob, geometry.contentOffset)
        XCTAssertLessThan(onKnob, geometry.contentOffset + geometry.viewportLength)
    }

    func testMinimapDocumentYInvertsTheBand() {
        let geometry = MinimapGeometry(
            boundsHeight: 600,
            viewportHeight: 200,
            contentOffsetY: 400,
            minimumContentOffsetY: 0,
            maximumContentOffsetY: 4000,
            documentHeight: 5000,
            textContainerInsetTop: 0,
            scale: 0.2,
            minIndicatorHeight: 6
        )
        let band = geometry.bandY(forLineYPosition: 1000)
        XCTAssertEqual(geometry.documentY(forLocalY: band), 1000, accuracy: 0.01)
    }

    func testRowWindowClampsToTheDocument() {
        let height: (Int) -> CGFloat = { _ in 16 }
        XCTAssertEqual(
            EditorFragmentPreview.rowWindow(anchorRow: 0, lineCount: 30, lineHeight: height).rows,
            Array(0 ... 5)
        )
        let end = EditorFragmentPreview.rowWindow(anchorRow: 29, lineCount: 30, lineHeight: height)
        XCTAssertEqual(end.rows, Array(24 ... 29))
        XCTAssertEqual(end.rows.first, 24)
        XCTAssertEqual(
            EditorFragmentPreview.rowWindow(anchorRow: 10, lineCount: 30, lineHeight: height).rows,
            Array(5 ... 15)
        )
    }

    func testCollapsedAnchorPrefersTheFollowingVisibleRow() {
        var heights = Array(repeating: CGFloat(16), count: 200)
        for row in 40 ... 120 {
            heights[row] = 0
        }
        let window = EditorFragmentPreview.rowWindow(anchorRow: 80, lineCount: heights.count) { heights[$0] }
        XCTAssertEqual(window.anchorRow, 121)
        XCTAssertFalse(window.rows.contains(80))
        XCTAssertTrue(window.rows.allSatisfy { heights[$0] > 0 })
    }

    func testAnchorBuriedInCollapsedRowsShowsNothing() {
        var heights = Array(repeating: CGFloat(0), count: 200)
        heights[0] = 16
        let window = EditorFragmentPreview.rowWindow(anchorRow: 100, lineCount: heights.count) { heights[$0] }
        XCTAssertTrue(window.rows.isEmpty)
    }

    func testMovingByCountsVisibleRows() {
        XCTAssertEqual(
            EditorFragmentPreview.row(from: 10, movingBy: 3, lineCount: 30) { _ in 16 },
            13
        )
        var heights = Array(repeating: CGFloat(16), count: 30)
        heights[11] = 0
        XCTAssertEqual(
            EditorFragmentPreview.row(from: 10, movingBy: 1, lineCount: 30) { heights[$0] },
            12
        )
    }

    func testScrollTargetAlignsTheLineWithThePopupAndClamps() {
        XCTAssertEqual(
            EditorFragmentPreview.contentOffset(aligningLineTop: 500, withPopupTop: 40, minimum: 0, maximum: 2000),
            460
        )
        XCTAssertEqual(
            EditorFragmentPreview.contentOffset(aligningLineTop: 10, withPopupTop: 40, minimum: 0, maximum: 2000),
            0
        )
        XCTAssertEqual(
            EditorFragmentPreview.contentOffset(aligningLineTop: 5000, withPopupTop: 40, minimum: 0, maximum: 2000),
            2000
        )
    }

    func testALineIsOnScreenWhenItsTopIsInsideTheViewport() {
        XCTAssertTrue(EditorFragmentPreview.isOnScreen(lineTop: 100, visibleTop: 0, visibleHeight: 200))
        XCTAssertFalse(EditorFragmentPreview.isOnScreen(lineTop: 200, visibleTop: 0, visibleHeight: 200))
        XCTAssertFalse(EditorFragmentPreview.isOnScreen(lineTop: -1, visibleTop: 0, visibleHeight: 200))
    }

    // MARK: - Content

    func testALongLineIsCappedBeforeHighlighting() throws {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        textView.setState(TextViewState(text: String(repeating: "a", count: 600), theme: DefaultTheme()))
        textView.layoutIfNeeded()
        let content = try XCTUnwrap(textView.editorFragmentPreviewContentForTesting(anchorRow: 0))
        let line = try XCTUnwrap(content.lines.first)
        XCTAssertEqual(line.text.string.count, 501)
        XCTAssertTrue(line.text.string.hasSuffix("…"))
    }

    func testCollapsedPreviewDoesNotCreateHandlesOrMaterializeTheBuffer() throws {
        let line = "private int value = 0; // " + String(repeating: "x", count: 40) + "\n"
        let text = String(repeating: line, count: 5000)
        XCTAssertGreaterThanOrEqual(text.utf16.count, StringView.pieceTreeUntitledThreshold)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        textView.setState(TextViewState(text: text, theme: DefaultTheme()))
        textView.layoutIfNeeded()

        let manager = textView.lineManagerForTesting
        let anchor = 400
        manager.setHeight(of: manager.line(atRow: anchor), to: 0)
        let handles = manager.handlesCreated
        let materialized = textView.pieceTreeMaterializeCount

        let content = try XCTUnwrap(textView.editorFragmentPreviewContentForTesting(anchorRow: anchor))
        XCTAssertFalse(content.lines.contains { $0.number == anchor + 1 })
        XCTAssertEqual(manager.handlesCreated, handles)
        XCTAssertEqual(textView.pieceTreeMaterializeCount, materialized)
    }

    // MARK: - Scrollbar

    func testHoveringBelowTheKnobShowsThePreviewAndAClickJumpsToItsFirstLine() throws {
        let textView = makeTextView(text: tallDocument)
        let vertical = textView.scrollerOverlayForTesting.verticalScroller
        vertical.flash()
        let preview = textView.editorFragmentPreviewForTesting
        preview.hoverDelay = 0

        let knob = vertical.subviews[0]
        let knobCenter = CGPoint(x: knob.frame.midX, y: knob.frame.midY)
        preview.mouseMoved(to: vertical.convert(knobCenter, to: textView), showsImmediately: true)
        XCTAssertFalse(preview.isShowing, "the knob is the code already on screen")

        let local = CGPoint(x: vertical.bounds.midX, y: vertical.bounds.height - 4)
        XCTAssertLessThan(knob.frame.maxY, local.y, "the hover must sit below the knob")
        preview.mouseMoved(to: vertical.convert(local, to: textView), showsImmediately: true)
        XCTAssertTrue(preview.isShowing)

        let popupTop = preview.popupTopForTesting
        let firstRow = try XCTUnwrap(preview.shownRows.first)
        let panelFrame = try XCTUnwrap(preview.panelFrameForTesting)
        let topScreen = CGPoint(x: panelFrame.minX, y: panelFrame.maxY)
        let topWindow = try XCTUnwrap(textView.window).convertFromScreen(NSRect(origin: topScreen, size: .zero)).origin
        XCTAssertEqual(textView.convert(topWindow, from: nil).y, popupTop, accuracy: 0.5)

        let caret = textView.lineManagerForTesting.location(ofRow: firstRow)
        vertical.mouseDown(with: mouseEvent(.leftMouseDown, at: local, in: vertical))

        XCTAssertEqual(textView.selectedRange, NSRange(location: caret, length: 0))
        let expected = EditorFragmentPreview.contentOffset(
            aligningLineTop: textView.yPosition(ofLine: firstRow + 1),
            withPopupTop: popupTop,
            minimum: textView.minimumContentOffset.y,
            maximum: textView.maximumContentOffset.y
        )
        XCTAssertEqual(textView.contentOffset.y, expected, accuracy: 0.5)
        pumpMainQueue()
        XCTAssertEqual(textView.contentOffset.y, expected, accuracy: 0.5)
        XCTAssertEqual(textView.selectedRange, NSRange(location: caret, length: 0))
        XCTAssertFalse(preview.isShowing)
    }

    func testClickingTheKnobWhileThePreviewIsOpenDoesNotJump() {
        let textView = makeTextView(text: tallDocument)
        let vertical = textView.scrollerOverlayForTesting.verticalScroller
        vertical.flash()
        let preview = textView.editorFragmentPreviewForTesting
        preview.hoverDelay = 0
        let local = CGPoint(x: vertical.bounds.midX, y: vertical.bounds.height - 4)
        preview.mouseMoved(to: vertical.convert(local, to: textView), showsImmediately: true)
        XCTAssertTrue(preview.isShowing)

        let offset = textView.contentOffset
        let caret = textView.selectedRange
        let knob = vertical.subviews[0]
        let grab = CGPoint(x: knob.frame.midX, y: knob.frame.midY)
        vertical.mouseDown(with: mouseEvent(.leftMouseDown, at: grab, in: vertical))

        XCTAssertEqual(textView.contentOffset, offset)
        XCTAssertEqual(textView.selectedRange, caret)
        XCTAssertFalse(preview.isShowing)
        vertical.mouseUp(with: mouseEvent(.leftMouseUp, at: grab, in: vertical))
    }

    func testTheScrollWheelMovesThePreviewInsteadOfTheEditor() {
        let textView = makeTextView(text: tallDocument)
        let vertical = textView.scrollerOverlayForTesting.verticalScroller
        vertical.flash()
        let preview = textView.editorFragmentPreviewForTesting
        preview.hoverDelay = 0
        let local = CGPoint(x: vertical.bounds.midX, y: vertical.bounds.height - 4)
        preview.mouseMoved(to: vertical.convert(local, to: textView), showsImmediately: true)
        XCTAssertTrue(preview.isShowing)
        XCTAssertLessThan(textView.editorFragmentRowHeight, 80)

        let offset = textView.contentOffset
        let rows = preview.shownRows
        XCTAssertTrue(textView.consumeEditorFragmentPreviewScroll(deltaY: 80))
        XCTAssertEqual(textView.contentOffset, offset)
        XCTAssertTrue(preview.isShowing)
        XCTAssertNotEqual(preview.shownRows, rows)
    }

    // MARK: - Minimap and the preference

    func testTheMinimapPreviewsOutsideTheIndicatorOnly() {
        let textView = makeTextView(text: tallDocument, showMinimap: true)
        XCTAssertTrue(textView.scrollerOverlayForTesting.verticalScroller.isHidden)
        let minimap = textView.minimapViewForTesting
        let indicator = minimap.debugViewportIndicatorFrame
        XCTAssertGreaterThan(indicator.height, 0)
        XCTAssertLessThan(indicator.maxY + 4, minimap.bounds.height)

        let preview = textView.editorFragmentPreviewForTesting
        preview.hoverDelay = 0
        let inside = CGPoint(x: indicator.midX, y: indicator.midY)
        preview.mouseMoved(to: minimap.convert(inside, to: textView), showsImmediately: true)
        XCTAssertFalse(preview.isShowing)

        let below = CGPoint(x: minimap.bounds.midX, y: minimap.bounds.height - 4)
        XCTAssertGreaterThan(below.y, indicator.maxY)
        preview.mouseMoved(to: minimap.convert(below, to: textView), showsImmediately: true)
        XCTAssertTrue(preview.isShowing)
    }

    func testTurningThePreviewOffIgnoresHover() {
        let textView = makeTextView(text: tallDocument)
        let vertical = textView.scrollerOverlayForTesting.verticalScroller
        vertical.flash()
        textView.showsEditorFragmentPreview = false
        let local = CGPoint(x: vertical.bounds.midX, y: vertical.bounds.height - 4)
        vertical.mouseMoved(with: mouseEvent(.mouseMoved, at: local, in: vertical))
        XCTAssertFalse(textView.editorFragmentPreviewForTesting.isShowing)
    }
}
