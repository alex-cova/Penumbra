@preconcurrency import AppKit
@testable import Penumbra
import XCTest

/// End-to-end checks on the overlay scrollers inside a laid-out `TextView`: the vertical scroller
/// takes over from the minimap's viewport indicator when the minimap is off, the horizontal one
/// appears for overflowing unwrapped lines, and both can be turned off.
final class OverlayScrollerTests: XCTestCase {
    @MainActor
    private func makeTextView(
        text: String,
        showMinimap: Bool = false,
        wrapsLines: Bool = true,
        showsScrollers: Bool = true,
        style: NSScroller.Style = .overlay
    ) -> TextView {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
        // Pin the style: on a machine with a mouse attached the system default is legacy.
        textView.scrollerOverlayForTesting.scrollerStyleOverride = style
        textView.minimapWidth = 100
        textView.showMinimap = showMinimap
        textView.isLineWrappingEnabled = wrapsLines
        textView.showsScrollers = showsScrollers
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.setState(TextViewState(text: text, theme: DefaultTheme()))
        textView.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        textView.layoutIfNeeded()
        return textView
    }

    private var tallDocument: String {
        (0 ..< 300).map { "line \($0)" }.joined(separator: "\n")
    }

    private var wideDocument: String {
        String(repeating: "wide ", count: 400)
    }

    /// Overflows both ways. The wide line comes first because the editor only knows a line's width
    /// once it has been laid out, so it has to be inside the initial viewport to widen the content.
    private var combinedDocument: String {
        wideDocument + "\n" + tallDocument
    }

    // MARK: - Vertical scroller vs. the minimap

    @MainActor
    func testVerticalScrollerAppearsWhenMinimapIsOffAndDocumentOverflows() {
        let textView = makeTextView(text: tallDocument, showMinimap: false)
        let vertical = textView.scrollerOverlayForTesting.verticalScroller

        XCTAssertFalse(vertical.isHidden)
        XCTAssertEqual(vertical.frame.width, OverlayScrollerView.thickness)
        XCTAssertEqual(vertical.frame.maxX, textView.bounds.maxX, accuracy: 0.001)
    }

    @MainActor
    func testVerticalScrollerIsHiddenWhileTheMinimapIsShown() {
        let textView = makeTextView(text: tallDocument, showMinimap: true)
        let vertical = textView.scrollerOverlayForTesting.verticalScroller

        XCTAssertTrue(vertical.isHidden, "the minimap's viewport indicator already fills that role")
        XCTAssertEqual(vertical.frame, .zero)
    }

    @MainActor
    func testTurningTheMinimapOffBringsTheVerticalScrollerBack() {
        let textView = makeTextView(text: tallDocument, showMinimap: true)
        let vertical = textView.scrollerOverlayForTesting.verticalScroller
        XCTAssertTrue(vertical.isHidden)

        textView.showMinimap = false
        textView.layoutIfNeeded()
        XCTAssertFalse(vertical.isHidden)

        textView.showMinimap = true
        textView.layoutIfNeeded()
        XCTAssertTrue(vertical.isHidden)
    }

    @MainActor
    func testVerticalScrollerIsHiddenWhenTheDocumentFits() {
        let textView = makeTextView(text: "hello\nworld", showMinimap: false)
        XCTAssertTrue(textView.scrollerOverlayForTesting.verticalScroller.isHidden)
    }

    @MainActor
    func testScrollersCanBeTurnedOff() {
        let textView = makeTextView(text: combinedDocument, wrapsLines: false, showsScrollers: false)
        let overlay = textView.scrollerOverlayForTesting
        XCTAssertTrue(overlay.verticalScroller.isHidden)
        XCTAssertTrue(overlay.horizontalScroller.isHidden)

        textView.showsScrollers = true
        textView.layoutIfNeeded()
        XCTAssertFalse(overlay.verticalScroller.isHidden)
        XCTAssertFalse(overlay.horizontalScroller.isHidden)
    }

    // MARK: - Horizontal scroller

    @MainActor
    func testHorizontalScrollerAppearsForAnOverflowingUnwrappedLine() {
        let textView = makeTextView(text: wideDocument, wrapsLines: false)
        let horizontal = textView.scrollerOverlayForTesting.horizontalScroller

        XCTAssertFalse(horizontal.isHidden)
        XCTAssertEqual(horizontal.frame.height, OverlayScrollerView.thickness)
        XCTAssertEqual(horizontal.frame.maxY, textView.bounds.maxY, accuracy: 0.001)
    }

    @MainActor
    func testHorizontalScrollerIsHiddenWhenLinesWrap() {
        let textView = makeTextView(text: wideDocument, wrapsLines: true)
        XCTAssertTrue(textView.scrollerOverlayForTesting.horizontalScroller.isHidden)
    }

    @MainActor
    func testHorizontalScrollerIsIndependentOfTheMinimap() {
        let textView = makeTextView(text: wideDocument, showMinimap: true, wrapsLines: false)
        let horizontal = textView.scrollerOverlayForTesting.horizontalScroller

        XCTAssertFalse(horizontal.isHidden)
        XCTAssertLessThanOrEqual(horizontal.frame.maxX, textView.bounds.maxX - textView.minimapWidth + 0.001,
                                 "it must not run underneath the minimap")
    }

    @MainActor
    func testBothScrollersLeaveTheCornerClear() {
        let textView = makeTextView(text: combinedDocument, wrapsLines: false)
        let overlay = textView.scrollerOverlayForTesting

        XCTAssertFalse(overlay.verticalScroller.isHidden)
        XCTAssertFalse(overlay.horizontalScroller.isHidden)
        XCTAssertLessThanOrEqual(overlay.verticalScroller.frame.maxY, overlay.horizontalScroller.frame.minY + 0.001)
        XCTAssertLessThanOrEqual(overlay.horizontalScroller.frame.maxX, overlay.verticalScroller.frame.minX + 0.001)
    }

    // MARK: - Auto-hide and hit testing

    @MainActor
    func testScrollingRevealsTheScrollerAndAnIdleScrollerDoesNotSwallowClicks() {
        let textView = makeTextView(text: tallDocument)
        let vertical = textView.scrollerOverlayForTesting.verticalScroller

        // `hitTest` takes a point in the superview's (the text view's) coordinate space.
        let center = CGPoint(x: vertical.frame.midX, y: vertical.frame.midY)

        textView.contentOffset = CGPoint(x: 0, y: 200)
        XCTAssertEqual(vertical.alphaValue, 1, "a scroll reveals the scroller")
        XCTAssertNotNil(vertical.hitTest(center))

        vertical.alphaValue = 0
        XCTAssertNil(vertical.hitTest(center), "a faded-out scroller must let clicks through to the text")
    }

    @MainActor
    func testLegacyStyleKeepsTheScrollerVisibleAndReservesItsStrip() {
        let overlayStyle = makeTextView(text: "hello", style: .overlay)
        XCTAssertEqual(overlayStyle.scrollerOverlayForTesting.reservedTrailingWidth(for: overlayStyle), 0)
        XCTAssertTrue(overlayStyle.scrollerOverlayForTesting.verticalScroller.isHidden)

        let legacy = makeTextView(text: "hello", style: .legacy)
        let vertical = legacy.scrollerOverlayForTesting.verticalScroller
        XCTAssertEqual(legacy.scrollerOverlayForTesting.reservedTrailingWidth(for: legacy), OverlayScrollerView.thickness)
        XCTAssertFalse(vertical.isHidden, "legacy scrollers are permanent, even when the document fits")
        XCTAssertEqual(vertical.alphaValue, 1)
    }

    @MainActor
    func testLegacyStyleReservesNothingWhileTheMinimapIsShown() {
        let textView = makeTextView(text: tallDocument, showMinimap: true, style: .legacy)
        XCTAssertEqual(textView.scrollerOverlayForTesting.reservedTrailingWidth(for: textView), 0)
    }

    // MARK: - Mouse

    @MainActor
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

    @MainActor
    func testDraggingTheKnobScrollsTheDocument() {
        let textView = makeTextView(text: tallDocument)
        let vertical = textView.scrollerOverlayForTesting.verticalScroller
        let knob = vertical.subviews[0]
        XCTAssertEqual(textView.contentOffset.y, 0)

        let grab = CGPoint(x: knob.frame.midX, y: knob.frame.midY)
        vertical.mouseDown(with: mouseEvent(.leftMouseDown, at: grab, in: vertical))
        vertical.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: grab.x, y: grab.y + 60), in: vertical))
        let afterFirstDrag = textView.contentOffset.y
        XCTAssertGreaterThan(afterFirstDrag, 0, "dragging the knob down scrolls the document down")

        vertical.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: grab.x, y: grab.y + 120), in: vertical))
        XCTAssertGreaterThan(textView.contentOffset.y, afterFirstDrag)
        vertical.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: grab.x, y: grab.y + 120), in: vertical))
        XCTAssertLessThanOrEqual(textView.contentOffset.y, textView.maximumContentOffset.y)
    }

    @MainActor
    func testClickingBelowTheKnobPagesTowardTheClick() {
        let textView = makeTextView(text: tallDocument)
        let vertical = textView.scrollerOverlayForTesting.verticalScroller
        let below = CGPoint(x: vertical.bounds.midX, y: vertical.bounds.maxY - 4)

        vertical.mouseDown(with: mouseEvent(.leftMouseDown, at: below, in: vertical))

        XCTAssertGreaterThan(textView.contentOffset.y, 0)
        // The system's "jump to the spot that's clicked" preference makes the click land near the
        // end instead of one page down, so only assert paging when it isn't set.
        if !UserDefaults.standard.bool(forKey: "AppleScrollerPagingBehavior") {
            XCTAssertLessThanOrEqual(textView.contentOffset.y, textView.bounds.height + 0.001,
                                     "a page click moves at most one viewport")
        }
    }

    @MainActor
    func testDraggingTheHorizontalKnobScrollsHorizontally() {
        let textView = makeTextView(text: wideDocument, wrapsLines: false)
        let horizontal = textView.scrollerOverlayForTesting.horizontalScroller
        let knob = horizontal.subviews[0]
        XCTAssertEqual(textView.contentOffset.x, 0)

        let grab = CGPoint(x: knob.frame.midX, y: knob.frame.midY)
        horizontal.mouseDown(with: mouseEvent(.leftMouseDown, at: grab, in: horizontal))
        horizontal.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: grab.x + 40, y: grab.y), in: horizontal))

        XCTAssertGreaterThan(textView.contentOffset.x, 0)
        XCTAssertEqual(textView.contentOffset.y, 0, "a horizontal drag never changes the vertical offset")
    }
}
