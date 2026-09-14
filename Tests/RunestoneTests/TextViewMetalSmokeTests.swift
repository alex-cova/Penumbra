import AppKit
import XCTest
@testable import Runestone

/// Runs the same kind of exercises as `TextViewSmokeTests` with the Metal paint backend forced on.
/// Skipped when no Metal device is available (CI VMs) or the `UserDefaults` kill switch is set.
///
/// PR 4 wires `LayoutManager` to `MetalRenderer`; decoration *drawing* lands in PR 5, so these
/// assert "does not crash / stays active / CG fallback still works", not pixels.
@MainActor
final class TextViewMetalSmokeTests: XCTestCase {
    private func skipUnlessMetalActivatable() throws {
        guard MetalContext.isAvailable else {
            throw XCTSkip("Metal is not available")
        }
        let defaults = UserDefaults.standard.object(forKey: MetalActivation.defaultsKey) as? Bool
        guard MetalActivation.resolved(property: true, deviceAvailable: true, defaults: defaults) else {
            throw XCTSkip("Metal is disabled via the UserDefaults kill switch")
        }
    }

    func testTypingUnderMetalKeepsBackendActiveAndTextCorrect() throws {
        try skipUnlessMetalActivatable()
        let textView = makeFocusedTextView(text: "hello\nworld")
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.isMetalRenderingActive)

        textView.selectedRange = NSRange(location: 5, length: 0)
        textView.insertText(" there")
        textView.layoutIfNeeded()

        XCTAssertEqual(textView.text, "hello there\nworld")
        XCTAssertTrue(textView.isMetalRenderingActive)
        XCTAssertTrue(fragmentViews(in: textView).isEmpty, "Metal owns the paint; no fragment views")
    }

    func testInvisibleCharacterToggleUnderMetalDoesNotCrash() throws {
        try skipUnlessMetalActivatable()
        let textView = makeFocusedTextView(text: "\tindented\n  spaced\n")
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()

        // Display-only invalidation path: `setNeedsDisplayOnLines`, no `layoutLinesInViewport`.
        for show in [true, false, true] {
            textView.showTabs = show
            textView.showSpaces = show
            textView.layoutIfNeeded()
        }

        XCTAssertTrue(textView.isMetalRenderingActive)
        XCTAssertEqual(textView.text, "\tindented\n  spaced\n")
    }

    func testMarkedTextAndUnmarkTextUnderMetalDoesNotCrash() throws {
        try skipUnlessMetalActivatable()
        let textView = makeFocusedTextView(text: "abc\ndef")
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        guard let textInputView = findTextInputView(in: textView) else {
            return XCTFail("Expected a TextInputView")
        }

        textView.selectedRange = NSRange(location: 3, length: 0)
        textInputView.setMarkedText("う", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.layoutIfNeeded()
        textInputView.unmarkText()
        textView.layoutIfNeeded()

        XCTAssertTrue(textView.isMetalRenderingActive)
    }

    func testScrollingUnderMetalDoesNotCrash() throws {
        try skipUnlessMetalActivatable()
        let body = (0..<400).map { "line number \($0) with some trailing text" }.joined(separator: "\n")
        let textView = makeFocusedTextView(text: body)
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()

        for y: CGFloat in [0, 600, 2_400, 6_000, 1_200, 0] {
            textView.contentOffset = CGPoint(x: 0, y: y)
            textView.layoutIfNeeded()
        }

        XCTAssertTrue(textView.isMetalRenderingActive)
    }

    func testTogglingMetalOffRestoresFragmentViews() throws {
        try skipUnlessMetalActivatable()
        let textView = makeFocusedTextView(text: "one\ntwo\nthree")
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        XCTAssertTrue(fragmentViews(in: textView).isEmpty)

        textView.isMetalRenderingEnabled = false
        textView.layoutIfNeeded()

        XCTAssertFalse(textView.isMetalRenderingActive)
        XCTAssertFalse(fragmentViews(in: textView).isEmpty, "CG path repopulates fragment views")
    }

    func testTwoTextViewsShareOneGlyphAtlas() throws {
        try skipUnlessMetalActivatable()
        let first = makeFocusedTextView(text: "func first() { return 1 }")
        let second = makeFocusedTextView(text: "func second() { return 2 }")
        for textView in [first, second] {
            textView.isMetalRenderingEnabled = true
            textView.layoutIfNeeded()
        }
        XCTAssertIdentical(MetalContext.shared.glyphAtlas, MetalContext.shared.glyphAtlas)
        XCTAssertGreaterThan(first.metalGlyphAtlasBytes, 0)
        // Both views report the same shared-atlas byte count.
        XCTAssertEqual(first.metalGlyphAtlasBytes, second.metalGlyphAtlasBytes)
        XCTAssertEqual(first.metalFragmentCount, 1)
    }

    func testSplitTwoMetalTextViewsInOneWindowPresentIndependently() throws {
        try skipUnlessMetalActivatable()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let split = NSSplitView(frame: window.contentRect(forFrameRect: window.frame))
        split.isVertical = true
        window.contentView = split

        var textViews: [TextView] = []
        for i in 0..<2 {
            let textView = TextView(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
            split.addArrangedSubview(textView)
            textView.setState(TextViewState(text: "pane \(i)\nsecond line \(i)", theme: DefaultTheme()))
            textView.isMetalRenderingEnabled = true
            textView.layoutIfNeeded()
            textViews.append(textView)
        }
        window.layoutIfNeeded()
        for textView in textViews {
            textView.layoutIfNeeded()
            XCTAssertTrue(textView.isMetalRenderingActive)
            XCTAssertGreaterThanOrEqual(textView.metalFragmentCount, 1)
        }
    }

    func testMetalGlyphSnapshotHasPaintedPixels() throws {
        try skipUnlessMetalActivatable()
        let textView = makeFocusedTextView(text: "func hello() { return 42 }")
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        Thread.sleep(forTimeInterval: 0.1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.isMetalRenderingActive)
        XCTAssertGreaterThan(textView.metalFragmentCount, 0)

        let snapshot = try XCTUnwrap(textView.captureMetalGlyphSnapshot(), "expected a Metal snapshot")
        let data = try XCTUnwrap(snapshot.bitmapData)
        var painted = 0
        let count = snapshot.pixelsWide * snapshot.pixelsHigh * 4
        for index in stride(from: 3, to: count, by: 4) where data[index] != 0 {
            painted += 1
        }
        XCTAssertGreaterThan(painted, 0, "Metal snapshot should contain painted glyph pixels (instances=\(textView.metalInstanceCount))")
    }

    func testLayoutPresentsGlyphInstancesOntoTheCanvas() throws {
        try skipUnlessMetalActivatable()
        let textView = makeFocusedTextView(text: "func hello() { return 42 }")
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        // `nextDrawable` can miss on the layout-synchronous present; the canvas retries on the
        // next turn. One run-loop pass is enough for that retry to land.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.isMetalRenderingActive)
        XCTAssertGreaterThan(textView.metalFragmentCount, 0, "layout should have upserted visible fragments")
        XCTAssertGreaterThan(
            textView.metalInstanceCount,
            0,
            "layout must rebuild instance buffers and present; an empty first drawable is the blank-editor bug (atlasBytes=\(textView.metalGlyphAtlasBytes) drawNs=\(textView.metalDrawNanosP95))"
        )
    }

    func testCanvasLeavingWindowDoesNotCrash() throws {
        try skipUnlessMetalActivatable()
        let textView = makeFocusedTextView(text: "detached")
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        // Simulate a workbench tab switch / EditorHostCache eviction.
        textView.window?.contentView = NSView()
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.isMetalRenderingActive)
    }
}

private extension TextViewMetalSmokeTests {
    func findTextInputView(in root: NSView) -> TextInputView? {
        if let textInputView = root as? TextInputView {
            return textInputView
        }
        for subview in root.subviews {
            if let found = findTextInputView(in: subview) {
                return found
            }
        }
        return nil
    }

    func fragmentViews(in root: NSView) -> [LineFragmentView] {
        var result: [LineFragmentView] = []
        if let fragment = root as? LineFragmentView {
            result.append(fragment)
        }
        for subview in root.subviews {
            result.append(contentsOf: fragmentViews(in: subview))
        }
        return result
    }
}
