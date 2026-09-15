import AppKit
import RunestoneLanguages
import XCTest
import simd
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

    func testMetalPresentsGlyphsOnScreen() throws {
        try skipUnlessMetalActivatable()
        TextView.allowsMetalDrawableCapture = true
        defer { TextView.allowsMetalDrawableCapture = false }

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.setState(TextViewState(text: "func hello() { return 42 }", theme: DefaultTheme()))
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.isMetalRenderingActive)
        XCTAssertGreaterThan(textView.metalInstanceCount, 0, "layout must have rebuilt glyph instances")

        let canvas = try XCTUnwrap(findMetalCanvas(in: textView), "expected a Metal canvas")
        XCTAssertFalse(canvas.isHidden)
        XCTAssertGreaterThan(canvas.bounds.width, 0, "canvas bounds \(canvas.bounds)")
        XCTAssertGreaterThan(canvas.bounds.height, 0, "canvas bounds \(canvas.bounds)")
        XCTAssertNotNil(canvas.window)
        XCTAssertNotNil(canvas.layer as? CAMetalLayer)

        let offscreen = try XCTUnwrap(textView.captureMetalGlyphSnapshot(), "offscreen encode should work")
        var offscreenPainted = 0
        if let data = offscreen.bitmapData {
            let count = offscreen.pixelsWide * offscreen.pixelsHigh * 4
            for index in stride(from: 3, to: count, by: 4) where data[index] != 0 {
                offscreenPainted += 1
            }
        }
        XCTAssertGreaterThan(offscreenPainted, 0, "offscreen encode should have glyphs (canvas=\(canvas.bounds))")
        XCTAssertGreaterThan(
            canvas.debugPresentedAlphaPixels,
            0,
            "on-screen drawable should contain glyph pixels (instances=\(textView.metalInstanceCount) atlas=\(textView.metalGlyphAtlasBytes) canvas=\(canvas.bounds) superview=\(String(describing: type(of: canvas.superview))))"
        )
    }

    func testMetalPresentsGlyphsAfterTypingWithoutExplicitLayout() throws {
        try skipUnlessMetalActivatable()
        TextView.allowsMetalDrawableCapture = true
        defer { TextView.allowsMetalDrawableCapture = false }

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let parent = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = parent
        let textView = TextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: parent.topAnchor),
            textView.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
        window.makeKeyAndOrderFront(nil)
        textView.setState(TextViewState(text: "hello", theme: DefaultTheme()))
        textView.isMetalRenderingEnabled = true
        window.layoutIfNeeded()
        textView.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        let canvas = try XCTUnwrap(findMetalCanvas(in: textView), "expected a Metal canvas")
        let initialPainted = canvas.debugPresentedAlphaPixels
        XCTAssertGreaterThan(initialPainted, 0, "initial on-screen glyphs")

        textView.selectedRange = NSRange(location: textView.text.utf16.count, length: 0)
        textView.insertText(" world")
        // Do not call layoutIfNeeded — rely on the deferred flush like SwiftUI hosting.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        XCTAssertEqual(textView.text, "hello world")
        XCTAssertGreaterThan(
            canvas.debugPresentedAlphaPixels,
            initialPainted,
            "typing must layout and present without an explicit layoutIfNeeded (instances=\(textView.metalInstanceCount))"
        )
    }

    func testMetalPresentsGlyphsWhenAutoLayoutHostedInDarkAppearance() throws {
        try skipUnlessMetalActivatable()
        TextView.allowsMetalDrawableCapture = true
        defer { TextView.allowsMetalDrawableCapture = false }

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        parent.wantsLayer = true
        parent.layer?.backgroundColor = NSColor(red: 0x1e / 255, green: 0x1e / 255, blue: 0x1e / 255, alpha: 1).cgColor
        window.contentView = parent

        let textView = TextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.showMinimap = true
        parent.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: parent.topAnchor),
            textView.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
        window.makeKeyAndOrderFront(nil)
        textView.setState(TextViewState(text: "func hello() { return 42 }\nlet x = 1", theme: DefaultTheme()))
        textView.isMetalRenderingEnabled = true
        window.layoutIfNeeded()
        textView.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        textView.layoutIfNeeded()

        XCTAssertTrue(textView.isMetalRenderingActive)
        let canvas = try XCTUnwrap(findMetalCanvas(in: textView), "expected a Metal canvas")
        XCTAssertEqual(canvas.superview, textView)
        XCTAssertGreaterThan(canvas.bounds.width, 0)
        XCTAssertGreaterThan(canvas.bounds.height, 0)
        XCTAssertGreaterThan(
            canvas.debugPresentedAlphaPixels,
            0,
            "Auto Layout + dark host must still present glyphs (canvas=\(canvas.bounds) instances=\(textView.metalInstanceCount))"
        )
    }

    /// The white-flash regression: `redisplayLines` asks for a *synchronous* highlight on the
    /// edited line, but an edit at/above `maxSyncEditLength` forces `textDidChange` down the
    /// no-reparse path (`canHighlight` false until the background parse catches up). Before the
    /// fix this line still got typeset (in `theme.textColor`) and Metal baked that default color
    /// into the presented frame; now `isSyntaxHighlightPending` makes Metal hold the previously
    /// extracted, correctly colored glyphs instead.
    func testMetalHoldsSyntaxColorsInsteadOfDefaultWhenEditOutrunsHighlight() throws {
        try skipUnlessMetalActivatable()
        let text = "let value = 42\n"
        let state = TextViewState(text: text, theme: DefaultTheme(), language: .javaScript, parsePolicy: .eager)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.setState(state)
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        // The first layout's highlight runs asynchronously (the line isn't "recently edited" yet);
        // let it complete and re-present before taking the "before" snapshot.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        textView.layoutIfNeeded()

        let beforeColors = textView.metalDebugGlyphColors(atLocation: 0)
        XCTAssertFalse(beforeColors.isEmpty, "expected glyphs once initial highlighting completes")
        XCTAssertGreaterThan(
            Set(beforeColors.map(ColorKey.init)).count, 1,
            "expected distinct token colors (keyword vs. number vs. default) once JavaScript highlighting completes"
        )

        // An edit at/above `TreeSitterPerformanceConstants.maxSyncEditLength` (1024 UTF-16 units)
        // skips the synchronous incremental reparse.
        let hugeInsertion = String(repeating: " ", count: TreeSitterPerformanceConstants.maxSyncEditLength + 1)
        textView.selectedRange = NSRange(location: text.utf16.count - 1, length: 0)
        textView.insertText(hugeInsertion)

        // No runloop spin: assert synchronously, immediately after the keystroke/paste, exactly
        // the frame that used to present `theme.textColor`.
        let afterColors = textView.metalDebugGlyphColors(atLocation: 0)
        XCTAssertEqual(
            afterColors.map(ColorKey.init), beforeColors.map(ColorKey.init),
            "the caret line must hold its previous syntax colors, not flash theme.textColor, while the reparse is outstanding"
        )

        // The background parse eventually catches up and colors refresh again.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        textView.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        textView.layoutIfNeeded()
        XCTAssertFalse(textView.metalDebugGlyphColors(atLocation: 0).isEmpty)
    }

    /// A brand-new line (no previously extracted glyphs to hold) must still paint immediately even
    /// while its highlight is pending — the hold-previous-glyphs policy must not regress into
    /// "blank until highlighted".
    func testMetalPaintsNewlyInsertedLineImmediatelyWhileHighlightIsPending() throws {
        try skipUnlessMetalActivatable()
        let text = "let value = 42\n"
        let state = TextViewState(text: text, theme: DefaultTheme(), language: .javaScript, parsePolicy: .eager)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.setState(state)
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        textView.layoutIfNeeded()

        // A huge insertion containing a line break creates a brand-new second line with no prior
        // Metal glyphs, while also forcing the no-reparse path (`maxSyncEditLength`).
        let hugeInsertion = "\n" + String(repeating: "x", count: TreeSitterPerformanceConstants.maxSyncEditLength + 1)
        textView.selectedRange = NSRange(location: text.utf16.count - 1, length: 0)
        textView.insertText(hugeInsertion)
        // A brand-new line only enters `visibleLineIDs`/gets a fragment on the layout pass that
        // follows the edit (`redisplayLines` only re-upserts lines already visible); this is that
        // one pass — still well before the background reparse (no runloop spin) has any chance
        // to complete, so the new line's highlight is still pending here.
        textView.layoutIfNeeded()

        let newLineLocation = text.utf16.count + 1
        XCTAssertFalse(
            textView.metalDebugGlyphColors(atLocation: newLineLocation).isEmpty,
            "a newly inserted line with no prior glyphs must still paint immediately, not wait for highlighting"
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
    func findMetalCanvas(in root: NSView) -> MetalTextCanvasView? {
        if let canvas = root as? MetalTextCanvasView {
            return canvas
        }
        for subview in root.subviews {
            if let canvas = findMetalCanvas(in: subview) {
                return canvas
            }
        }
        return nil
    }

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

/// `Equatable`/`Hashable` wrapper for `SIMD4<Float>` glyph colors, compared component-wise.
private struct ColorKey: Hashable {
    let r: Float
    let g: Float
    let b: Float
    let a: Float

    init(_ color: SIMD4<Float>) {
        r = color.x
        g = color.y
        b = color.z
        a = color.w
    }
}
