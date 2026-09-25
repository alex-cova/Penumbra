import AppKit
import PenumbraLanguages
import SwiftUI
import XCTest
import simd
@testable import Penumbra

/// Runs the same kind of exercises as `TextViewSmokeTests` with the Metal paint backend forced on.
/// Skipped when no Metal device is available (CI VMs) or the `UserDefaults` kill switch is set.
///
/// PR 4 wires `LayoutManager` to `MetalRenderer`; decoration *drawing* lands in PR 5, so these
/// assert "does not crash / stays active / CG fallback still works", not pixels.
@MainActor
final class TextViewMetalSmokeTests: XCTestCase {
    private func skipUnlessMetalActivatable() throws {
        let requiresMetal = ProcessInfo.processInfo.environment["PENUMBRA_REQUIRE_METAL"] == "1"
        guard MetalContext.isAvailable else {
            if requiresMetal {
                throw NSError(
                    domain: "PenumbraTests.RequiredMetal",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Metal is required on this runner but no device is available"]
                )
            }
            throw XCTSkip("Metal is not available")
        }
        let defaults = UserDefaults.standard.object(forKey: MetalActivation.defaultsKey) as? Bool
        guard MetalActivation.resolved(property: true, deviceAvailable: true, defaults: defaults) else {
            if requiresMetal {
                throw NSError(
                    domain: "PenumbraTests.RequiredMetal",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Metal is required but disabled by the kill switch"]
                )
            }
            throw XCTSkip("Metal is disabled via the UserDefaults kill switch")
        }
    }

    func testTypingOneCharacterKeepsGlyphsOnLinesBelow() throws {
        try skipUnlessMetalActivatable()
        let source = (0 ..< 40).map { "let value\($0) = \($0);" }.joined(separator: "\n")
        let textView = makeFocusedTextView(text: source)
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(textView.isMetalRenderingActive)
        let before = textView.metalFragmentCount
        XCTAssertGreaterThan(before, 8)
        let lowerLocation = (source as NSString).range(of: "let value5").location
        XCTAssertNotEqual(lowerLocation, NSNotFound)
        let originsBefore = textView.metalDebugGlyphOrigins(atLocation: lowerLocation)
        XCTAssertFalse(originsBefore.isEmpty, "line 5 should be on screen and painted")

        textView.selectedRange = NSRange(location: 4, length: 0)
        textView.insertText("X")
        textView.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertGreaterThanOrEqual(textView.metalFragmentCount, before)
        let originsAfter = textView.metalDebugGlyphOrigins(atLocation: lowerLocation + 1)
        XCTAssertEqual(originsAfter.count, originsBefore.count)
        XCTAssertEqual(textView.text.hasPrefix("let Xvalue0"), true)
    }

    /// Plain text never counts as paint-stable (its highlighter cannot highlight), so the layout
    /// fast path only runs for a tree-sitter language. These tests need that path.
    private func makeHighlightedMetalTextView(text: String, wraps: Bool = true) -> TextView {
        let textView = makeFocusedTextView(text: "")
        textView.isLineWrappingEnabled = wraps
        textView.setState(TextViewState(text: text, theme: DefaultTheme(), language: .javaScript, parsePolicy: .eager))
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.2)
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.05)
        return textView
    }

    /// Lines in the layout padding band are extracted against the old cull rect, so they have no
    /// glyphs until a pass re-upserts them. Scrolling must do that, not skip them as "unchanged".
    func testScrollingInSmallStepsPaintsEveryVisibleLine() throws {
        try skipUnlessMetalActivatable()
        let body = (0 ..< 400).map { "let line\($0) = \($0) + trailing;" }.joined(separator: "\n")
        let textView = makeHighlightedMetalTextView(text: body)
        XCTAssertTrue(textView.isMetalRenderingActive)

        var offsetY: CGFloat = 0
        for _ in 0 ..< 30 {
            offsetY += 23
            textView.contentOffset = CGPoint(x: 0, y: offsetY)
            textView.layoutIfNeeded()
            for probeY: CGFloat in [20, 150, 270] {
                let location = try XCTUnwrap(textView.characterIndex(at: CGPoint(x: 80, y: probeY)))
                XCTAssertFalse(
                    textView.metalDebugGlyphOrigins(atLocation: location).isEmpty,
                    "line at y=\(probeY) after scrolling to \(offsetY) has no Metal glyphs"
                )
            }
        }
    }

    /// Return keeps the edited line's height, but every line below moves down one row. Their
    /// Metal frames must move too, not stay where the fast path last painted them.
    func testReturnMidViewportMovesEveryFollowingLine() throws {
        try skipUnlessMetalActivatable()
        let source = (0 ..< 40).map { "let value\($0) = \($0);" }.joined(separator: "\n")
        let textView = makeHighlightedMetalTextView(text: source)
        let nsSource = source as NSString
        let probe = nsSource.range(of: "let value9 ").location
        let beforeY = try XCTUnwrap(textView.metalDebugGlyphOrigins(atLocation: probe).map(\.y).min())

        let endOfLine3 = nsSource.range(of: "let value3 = 3;").upperBound
        textView.selectedRange = NSRange(location: endOfLine3, length: 0)
        textView.insertText("\n")
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.05)

        let afterY = try XCTUnwrap(textView.metalDebugGlyphOrigins(atLocation: probe + 1).map(\.y).min())
        XCTAssertGreaterThan(afterY, beforeY, "a line below the Return must move down")
    }

    /// Lines below a Return only move. Their glyphs are reused and offset rather than extracted
    /// again (re-extracting every visible line was most of an Enter's paint work), and the result
    /// must be the same glyphs, one line lower.
    func testReturnMovesLinesBelowWithoutReextractingThem() throws {
        try skipUnlessMetalActivatable()
        let source = (0 ..< 40).map { "let value\($0) = \($0);" }.joined(separator: "\n")
        let textView = makeHighlightedMetalTextView(text: source)
        let nsSource = source as NSString
        let probe = nsSource.range(of: "let value9 ").location
        let originsBefore = textView.metalDebugGlyphOrigins(atLocation: probe).sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        XCTAssertFalse(originsBefore.isEmpty)
        let extractsBefore = try XCTUnwrap(textView.metalPerformanceStats).glyphExtractCount

        let endOfLine3 = nsSource.range(of: "let value3 = 3;").upperBound
        textView.selectedRange = NSRange(location: endOfLine3, length: 0)
        textView.insertText("\n")
        textView.layoutIfNeeded()

        let extracts = try XCTUnwrap(textView.metalPerformanceStats).glyphExtractCount - extractsBefore
        XCTAssertLessThan(extracts, 8, "only the edited and new lines (and band edges) re-extract, not the ~36 lines below")
        let originsAfter = textView.metalDebugGlyphOrigins(atLocation: probe + 1).sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        XCTAssertEqual(originsAfter.count, originsBefore.count)
        let shift = try XCTUnwrap(originsAfter.first).y - originsBefore[0].y
        XCTAssertGreaterThan(shift, 0)
        for (before, after) in zip(originsBefore, originsAfter) {
            XCTAssertEqual(after.x, before.x)
            XCTAssertEqual(after.y - before.y, shift, accuracy: 0.001)
        }
    }

    /// Glyphs are culled to the canvas horizontally too. A long line that stays visible while
    /// scrolling sideways must be re-extracted for the new cull rect.
    func testHorizontalScrollReextractsLongLine() throws {
        try skipUnlessMetalActivatable()
        let longLine = "let x = [" + (0 ..< 60).map { "word\($0)" }.joined(separator: ", ") + "];"
        let textView = makeHighlightedMetalTextView(text: longLine + "\nlet y = 1;", wraps: false)
        let before = textView.metalDebugGlyphOrigins(atLocation: 0)
        XCTAssertFalse(before.isEmpty)

        textView.contentOffset = CGPoint(x: 600, y: 0)
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.05)

        let after = textView.metalDebugGlyphOrigins(atLocation: 0)
        XCTAssertFalse(after.isEmpty)
        XCTAssertGreaterThan(
            after.map(\.x).max() ?? 0,
            before.map(\.x).max() ?? 0,
            "glyphs past the old right edge must be extracted after scrolling right"
        )
    }

    /// Typing inside an identifier leaves the tree's structure alone, so the tree diff reports no
    /// rows. The line still has to end up with the colors a fresh open of the same text shows.
    func testColorsAfterTypingMatchAFreshlyOpenedDocument() throws {
        try skipUnlessMetalActivatable()
        let original = "let value = 42\nconst other = value + 1;\n"
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.setState(TextViewState(text: original, theme: DefaultTheme(), language: .javaScript, parsePolicy: .eager))
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.2)
        textView.layoutIfNeeded()

        textView.selectedRange = NSRange(location: 9, length: 0)
        for character in ["X", "Y", "Z"] {
            textView.insertText(character)
            textView.layoutIfNeeded()
        }
        pumpMainRunLoop(for: 0.4)
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.2)
        textView.layoutIfNeeded()

        let fresh = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        fresh.setState(TextViewState(text: textView.text, theme: DefaultTheme(), language: .javaScript, parsePolicy: .eager))
        fresh.isMetalRenderingEnabled = true
        fresh.layoutIfNeeded()
        pumpMainRunLoop(for: 0.2)
        fresh.layoutIfNeeded()

        XCTAssertEqual(
            textView.metalDebugGlyphColors(atLocation: 0).map(ColorKey.init),
            fresh.metalDebugGlyphColors(atLocation: 0).map(ColorKey.init),
            "the edited line kept its color-shifted guess instead of the parsed colors"
        )
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
        // Deferred present encodes on the display link, not synchronously during layout.
        let deadline = Date().addingTimeInterval(1.0)
        while textView.metalInstanceCount == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.016))
            textView.layoutIfNeeded()
        }
        XCTAssertTrue(textView.isMetalRenderingActive)
        XCTAssertGreaterThan(textView.metalFragmentCount, 0, "layout should have upserted visible fragments")
        XCTAssertGreaterThan(
            textView.metalInstanceCount,
            0,
            "display link must rebuild instance buffers and present; an empty first drawable is the blank-editor bug (atlasBytes=\(textView.metalGlyphAtlasBytes) drawNs=\(textView.metalDrawNanosP95))"
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
        let initialFrame = try XCTUnwrap(textView.captureMetalPresentedLayer())
        let initialInk = inkPixelCount(in: initialFrame)
        XCTAssertGreaterThan(initialInk, 0, "initial on-screen glyphs")

        textView.selectedRange = NSRange(location: textView.text.utf16.count, length: 0)
        textView.insertText(" world")
        // Do not call layoutIfNeeded — rely on the deferred flush like SwiftUI hosting.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        XCTAssertEqual(textView.text, "hello world")
        let updatedFrame = try XCTUnwrap(textView.captureMetalPresentedLayer())
        XCTAssertGreaterThan(
            inkPixelCount(in: updatedFrame),
            initialInk,
            "typing must layout and present without an explicit layoutIfNeeded (instances=\(textView.metalInstanceCount))"
        )
        XCTAssertGreaterThan(differingPixelCount(initialFrame, updatedFrame), 20)
        XCTAssertGreaterThan(canvas.debugPresentedAlphaPixels, 0)
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

    func testOpaqueMetalCanvasPresentsLineSelectionAndPageGuide() throws {
        try skipUnlessMetalActivatable()
        let host = try makeCapturingMetalTextView(text: "selected line\nsecond line")
        defer {
            host.close()
            TextView.allowsMetalDrawableCapture = false
        }
        let textView = host.textView
        let before = try XCTUnwrap(textView.captureMetalPresentedLayer())

        textView.lineSelectionDisplayType = .line
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.pageGuideColumn = 10
        textView.showReformattingGuideShading = false
        textView.showPageGuide = true
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.05)

        let after = try XCTUnwrap(textView.captureMetalPresentedLayer())
        XCTAssertGreaterThan(
            differingPixelCount(before, after),
            100,
            "Metal must paint the current-line band and page-guide hairline before becoming opaque"
        )
        let canvas = try XCTUnwrap(findMetalCanvas(in: textView))
        XCTAssertTrue(canvas.isOpaque)
        XCTAssertEqual((canvas.layer as? CAMetalLayer)?.isOpaque, true)
    }

    func testOpaqueMetalCanvasPaintsMethodSeparatorLikePageGuide() throws {
        try skipUnlessMetalActivatable()
        let source = """
        function alpha() {
          return 1
        }

        function beta() {
          return 2
        }
        """
        let host = try makeCapturingMetalTextView(text: source)
        defer {
            host.close()
            TextView.allowsMetalDrawableCapture = false
        }
        let textView = host.textView
        textView.setState(TextViewState(
            text: source,
            theme: DefaultTheme(),
            language: .javaScript,
            parsePolicy: .eager
        ))
        textView.showMethodSeparators = false
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.3)
        textView.layoutIfNeeded()

        let before = try XCTUnwrap(textView.captureMetalPresentedLayer())
        textView.showMethodSeparators = true
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.2)
        textView.layoutIfNeeded()

        let input = try XCTUnwrap(findTextInputView(in: textView))
        XCTAssertFalse(
            input.methodSeparatorController.separatorRows.isEmpty,
            "expected a separator above the second function"
        )
        let separatorView = try XCTUnwrap(findSeparatorView(in: textView))
        let frames = separatorView.separatorLineFrames(
            clip: CGRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000)
        )
        XCTAssertFalse(frames.isEmpty, "expected a hairline frame for the separator row")
        let after = try XCTUnwrap(textView.captureMetalPresentedLayer())
        XCTAssertGreaterThan(
            differingPixelCount(before, after),
            20,
            "Metal must paint method separators with the page-guide hairline"
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
        let hugeInsertion = "XYZ" + String(repeating: " ", count: TreeSitterPerformanceConstants.maxSyncEditLength + 1)
        textView.selectedRange = NSRange(location: text.utf16.count - 1, length: 0)
        textView.insertText(hugeInsertion)

        // No runloop spin: assert synchronously, immediately after the keystroke/paste, exactly
        // the frame that used to present `theme.textColor`.
        let afterColors = textView.metalDebugGlyphColors(atLocation: 0)
        XCTAssertEqual(
            Array(afterColors.prefix(beforeColors.count)).map(ColorKey.init),
            beforeColors.map(ColorKey.init),
            "the pending frame must retain the previous syntax colors instead of flashing theme.textColor"
        )
        XCTAssertGreaterThan(
            afterColors.count,
            beforeColors.count,
            "the pending frame must contain glyphs for newly inserted characters, not the stale pre-edit glyph set"
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

    func testMetalPresentsEditedExistingLineWhileHighlightIsPending() throws {
        try skipUnlessMetalActivatable()
        let text = "let value = 42\n"
        let host = try makeCapturingMetalTextView(text: text)
        defer {
            host.close()
            TextView.allowsMetalDrawableCapture = false
        }
        let textView = host.textView
        textView.setState(TextViewState(
            text: text,
            theme: DefaultTheme(),
            language: .javaScript,
            parsePolicy: .eager
        ))
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.2)
        textView.layoutIfNeeded()
        let before = try XCTUnwrap(textView.captureMetalPresentedLayer())
        let beforeColors = textView.metalDebugGlyphColors(atLocation: 0)
        XCTAssertFalse(beforeColors.isEmpty)

        let insertion = "XYZ" + String(
            repeating: " ",
            count: TreeSitterPerformanceConstants.maxSyncEditLength + 1
        )
        textView.selectedRange = NSRange(location: 4, length: 0)
        textView.insertText(insertion)
        // Force only the edit frame. Do not let the background parse complete first.
        textView.layoutIfNeeded()

        let after = try XCTUnwrap(textView.captureMetalPresentedLayer())
        XCTAssertGreaterThan(
            differingPixelCount(before, after),
            20,
            "the pending-highlight edit must reach the presented drawable"
        )
        XCTAssertGreaterThan(
            textView.metalDebugGlyphColors(atLocation: 0).count,
            beforeColors.count,
            "newly inserted glyphs must coexist with retained syntax colors"
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

    func testMetalRepaintsGlyphsAfterHostReturnsToWindow() throws {
        try skipUnlessMetalActivatable()
        let host = try makeCapturingMetalTextView(text: "reattached text")
        defer {
            host.close()
            TextView.allowsMetalDrawableCapture = false
        }
        let textView = host.textView
        let before = try XCTUnwrap(textView.captureMetalPresentedLayer())
        XCTAssertGreaterThan(paintedPixelCount(in: before), 0)

        let window = host.window
        window.contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        textView.layoutIfNeeded()

        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.05)

        XCTAssertGreaterThan(textView.metalInstanceCount, 0, "reattaching must rebuild compacted Metal buffers")
        let presented = try XCTUnwrap(textView.captureMetalPresentedLayer())
        XCTAssertGreaterThan(
            paintedPixelCount(in: presented),
            0,
            "reattached presented drawable must contain painted glyph pixels"
        )
    }

    func testMetalSkipsUnchangedDecorationBuilds() throws {
        try skipUnlessMetalActivatable()
        let textView = makeFocusedTextView(text: "unchanged decorations")
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        let firstBuildCount = try XCTUnwrap(textView.metalPerformanceStats?.decorationBuildCount)

        textView.layoutIfNeeded()
        let secondBuildCount = try XCTUnwrap(textView.metalPerformanceStats?.decorationBuildCount)

        XCTAssertEqual(
            secondBuildCount,
            firstBuildCount,
            "a layout pass with unchanged decoration inputs must not rebuild Metal decoration geometry"
        )
    }

    func testMetalMovesHeldGlyphsWhenFragmentFrameChangesWhileHighlightPending() throws {
        try skipUnlessMetalActivatable()
        let text = "let value = 42\n"
        let textView = TextView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        textView.setState(TextViewState(
            text: text,
            theme: DefaultTheme(),
            language: .javaScript,
            parsePolicy: .eager
        ))
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        textView.layoutIfNeeded()

        let before = try XCTUnwrap(
            textView.metalDebugGlyphOrigins(atLocation: 0).map(\.y).min(),
            "expected initially highlighted glyphs"
        )
        let insertedPrefix = "\n" + String(repeating: " ", count: TreeSitterPerformanceConstants.maxSyncEditLength + 1)
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.insertText(insertedPrefix)
        textView.layoutIfNeeded()

        let oldLineLocation = insertedPrefix.utf16.count
        let after = try XCTUnwrap(
            textView.metalDebugGlyphOrigins(atLocation: oldLineLocation).map(\.y).min(),
            "expected held glyphs for the moved line"
        )
        XCTAssertGreaterThan(after, before, "held glyphs must follow their fragment after it moves")
    }

    func testMetalRepaintsAfterReturnInsertsLineBreak() throws {
        try skipUnlessMetalActivatable()
        let host = try makeCapturingMetalTextView(text: "one")
        defer {
            host.close()
            TextView.allowsMetalDrawableCapture = false
        }
        let textView = host.textView
        let fixedBounds = textView.bounds
        let before = try XCTUnwrap(textView.captureMetalPresentedLayer())
        let beforeInk = inkPixelCount(in: before)
        XCTAssertGreaterThan(beforeInk, 0, "initial drawable must contain the first line")

        textView.selectedRange = NSRange(location: 3, length: 0)
        textView.insertText("\n")
        textView.insertText("second_line_probe")
        // Match the SwiftUI-hosted app: no explicit layout and no resize after the edit.
        pumpMainRunLoop()

        XCTAssertEqual(textView.text, "one\nsecond_line_probe")
        XCTAssertEqual(textView.bounds, fixedBounds, "the repaint must not depend on resizing")
        let after = try XCTUnwrap(textView.captureMetalPresentedLayer())
        XCTAssertGreaterThan(
            inkPixelCount(in: after),
            beforeInk,
            "the presented drawable must contain the newly typed second line"
        )
        XCTAssertGreaterThan(
            differingPixelCount(before, after),
            40,
            "Return and following text must visibly change the presented drawable"
        )
        XCTAssertFalse(
            textView.metalDebugGlyphOrigins(atLocation: 4).isEmpty,
            "renderer state should agree with the presented frame"
        )
    }

    func testMetalShiftsFollowingLineWhenReturnInsertsEmptyLine() throws {
        try skipUnlessMetalActivatable()
        let host = try makeCapturingMetalTextView(text: "aaa\nbbb")
        defer {
            host.close()
            TextView.allowsMetalDrawableCapture = false
        }
        let textView = host.textView
        XCTAssertTrue(textView.focusTextInput())
        textView.layoutIfNeeded()
        pumpMainRunLoop(for: 0.05)
        let beforeY = try XCTUnwrap(
            textView.metalDebugGlyphOrigins(atLocation: 4).map(\.y).min(),
            "expected glyphs for the second line"
        )
        let before = try XCTUnwrap(textView.captureMetalPresentedLayer())

        textView.selectedRange = NSRange(location: 3, length: 0)
        textView.insertText("\n")
        pumpMainRunLoop()

        XCTAssertEqual(textView.text, "aaa\n\nbbb")
        let afterY = try XCTUnwrap(
            textView.metalDebugGlyphOrigins(atLocation: 5).map(\.y).min(),
            "following line must still have glyphs after an empty-line Return"
        )
        XCTAssertGreaterThan(afterY, beforeY, "Return at end of line must move following glyphs down without extra typing")
        let after = try XCTUnwrap(textView.captureMetalPresentedLayer())
        XCTAssertGreaterThan(
            differingPixelCount(before, after),
            20,
            "shifting the following line must change the presented drawable"
        )
    }

    func testMetalMovesCaretWhenReturnAppendsEmptyLineAtEndOfDocument() throws {
        try skipUnlessMetalActivatable()
        let host = try makeCapturingMetalTextView(text: "hello")
        defer {
            host.close()
            TextView.allowsMetalDrawableCapture = false
        }
        let textView = host.textView
        XCTAssertTrue(textView.focusTextInput())
        textView.layoutIfNeeded()
        textView.selectedRange = NSRange(location: 5, length: 0)
        textView.layoutIfNeeded()
        let beforeCaret = textView.caretRect(for: textView.endOfDocument)

        textView.insertText("\n")
        pumpMainRunLoop()

        XCTAssertEqual(textView.text, "hello\n")
        let afterCaret = textView.caretRect(for: textView.endOfDocument)
        XCTAssertGreaterThan(
            afterCaret.minY,
            beforeCaret.minY,
            "Return at end of document must move the caret onto the new line without extra typing"
        )
    }

    func testSwiftUIHostedMetalPresentsRepeatedReturnsWithoutResize() throws {
        try skipUnlessMetalActivatable()
        TextView.allowsMetalDrawableCapture = true
        defer { TextView.allowsMetalDrawableCapture = false }

        let size = CGSize(width: 720, height: 480)
        let textView = TextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.setState(TextViewState(text: "root", theme: DefaultTheme()))
        textView.isMetalRenderingEnabled = true
        let paneHost = NSView(frame: CGRect(origin: .zero, size: size))
        paneHost.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: paneHost.topAnchor),
            textView.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: paneHost.bottomAnchor)
        ])
        let hostingView = NSHostingView(rootView: MetalHostRepresentable(host: paneHost))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        pumpMainRunLoop(for: 0.2)
        let fixedBounds = textView.bounds
        let before = try XCTUnwrap(textView.captureMetalPresentedLayer())

        textView.selectedRange = NSRange(location: textView.text.utf16.count, length: 0)
        for index in 1...8 {
            textView.insertText("\nline_\(index)")
            pumpMainRunLoop(for: 0.03)
        }

        XCTAssertEqual(textView.bounds, fixedBounds)
        let after = try XCTUnwrap(textView.captureMetalPresentedLayer())
        XCTAssertGreaterThan(differingPixelCount(before, after), 200)
        let finalLine = textView.text.utf16.count - "line_8".utf16.count
        XCTAssertFalse(textView.metalDebugGlyphOrigins(atLocation: finalLine).isEmpty)
        window.orderOut(nil)
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

    func findSeparatorView(in root: NSView) -> MethodSeparatorView? {
        if let separator = root as? MethodSeparatorView {
            return separator
        }
        for subview in root.subviews {
            if let found = findSeparatorView(in: subview) {
                return found
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

private struct MetalHostRepresentable: NSViewRepresentable {
    let host: NSView

    func makeNSView(context: Context) -> EditorHostContainer {
        let container = EditorHostContainer()
        container.mount(host)
        return container
    }

    func updateNSView(_ container: EditorHostContainer, context: Context) {
        container.mount(host)
    }
}
