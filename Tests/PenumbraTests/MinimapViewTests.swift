@preconcurrency import AppKit
@testable import Penumbra
import PenumbraMarkdownLanguage
import XCTest

/// End-to-end checks on the real `MinimapView` inside a laid-out `TextView` (the Core Text render
/// path, since tests disable Metal): it paints syntax colors, keeps its cost bounded on a large
/// document instead of walking every row, and survives the degenerate document sizes.
final class MinimapViewTests: XCTestCase {
    @MainActor
    private func makeTextView(text: String, language: TreeSitterLanguage? = nil, enableMinimap: Bool = true) -> TextView {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
        textView.minimapWidth = 100
        textView.showMinimap = enableMinimap
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        let state: TextViewState
        if let language {
            state = TextViewState(text: text, theme: DefaultTheme(), language: language, languageProvider: MarkdownLanguageProvider())
        } else {
            state = TextViewState(text: text, theme: DefaultTheme())
        }
        textView.setState(state)
        textView.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        textView.layoutIfNeeded()
        return textView
    }

    private var markdownDocument: String {
        var lines: [String] = []
        for i in 0 ..< 160 {
            switch i % 6 {
            case 0: lines.append("# Heading number \(i)")
            case 1: lines.append("Some **bold** and _italic_ prose on line \(i).")
            case 2: lines.append("    let indented = code(\(i))")
            case 3: lines.append("")
            case 4: lines.append("- list item \(i) with `inline code`")
            default: lines.append("> a quoted line \(i)")
            }
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    func testMinimapPaintsMoreColorsWithSyntaxHighlightingThanWithout() {
        let plain = makeTextView(text: markdownDocument)
        let highlighted = makeTextView(text: markdownDocument, language: .markdown)

        let plainMinimap = plain.minimapViewForTesting
        let highlightedMinimap = highlighted.minimapViewForTesting
        if let bitmap = highlightedMinimap.bitmapImageRepForCachingDisplay(in: highlightedMinimap.bounds) {
            highlightedMinimap.cacheDisplay(in: highlightedMinimap.bounds, to: bitmap)
        }
        if let bitmap = plainMinimap.bitmapImageRepForCachingDisplay(in: plainMinimap.bounds) {
            plainMinimap.cacheDisplay(in: plainMinimap.bounds, to: bitmap)
        }

        XCTAssertEqual(plainMinimap.debugPaletteColorCount, 1, "plain text uses only the base bar color")
        XCTAssertGreaterThan(highlightedMinimap.debugPaletteColorCount, 1,
                             "syntax highlighting interned capture colors into the minimap palette")
    }

    @MainActor
    func testDrawIsBoundedByViewportNotDocumentLength() {
        let manyLines = (0 ..< 5000).map { "func item\($0)() { return \($0) }" }.joined(separator: "\n")
        let textView = makeTextView(text: manyLines, language: .markdown)
        let minimap = textView.minimapViewForTesting

        guard let bitmap = minimap.bitmapImageRepForCachingDisplay(in: minimap.bounds) else {
            return XCTFail("no bitmap")
        }
        minimap.cacheDisplay(in: minimap.bounds, to: bitmap)

        // A y-space walk touches at most ~one row per `minimapRowHeight` of view height; an
        // O(document) walk would report 5000.
        let ceiling = Int(minimap.bounds.height / 3) + 32
        XCTAssertGreaterThan(minimap.debugLastDrawnRowCount, 0)
        XCTAssertLessThan(minimap.debugLastDrawnRowCount, ceiling,
                          "expected a viewport-bounded walk, got \(minimap.debugLastDrawnRowCount)")
    }

    @MainActor
    func testDisabledMinimapDoesNotLeaveTrailingChrome() {
        let neverShown = makeTextView(text: "hello\nworld", enableMinimap: false)
        assertMinimapChromeCollapsed(neverShown.minimapViewForTesting)

        let toggled = makeTextView(text: "hello\nworld", enableMinimap: true)
        let shown = toggled.minimapViewForTesting
        XCTAssertFalse(shown.isHidden)
        XCTAssertGreaterThan(shown.frame.width, 0)
        XCTAssertFalse(shown.debugViewportIndicatorHidden)
        XCTAssertGreaterThan(shown.debugViewportIndicatorFrame.height, 0)

        toggled.showMinimap = false
        toggled.layoutIfNeeded()
        assertMinimapChromeCollapsed(shown)
    }

    @MainActor
    func testDisabledMinimapStaysCollapsedAfterThemeAndAppearanceChanges() {
        let textView = makeTextView(text: markdownDocument, language: .markdown, enableMinimap: false)
        let minimap = textView.minimapViewForTesting
        assertMinimapChromeCollapsed(minimap)

        textView.theme = DefaultTheme()
        textView.layoutIfNeeded()
        assertMinimapChromeCollapsed(minimap)

        textView.appearance = NSAppearance(named: .darkAqua)
        textView.viewDidChangeEffectiveAppearance()
        minimap.viewDidChangeEffectiveAppearance()
        textView.layoutIfNeeded()
        assertMinimapChromeCollapsed(minimap)
    }

    @MainActor
    func testDisabledMinimapCollapsesImmediatelyWithoutWaitingForLayout() {
        let textView = makeTextView(text: markdownDocument, language: .markdown, enableMinimap: true)
        let minimap = textView.minimapViewForTesting
        textView.contentOffset = CGPoint(x: 0, y: 200)
        textView.showMinimap = false
        assertMinimapChromeCollapsed(minimap)
    }

    @MainActor
    func testLayoutSubviewsRepairsStaleMinimapFrameWhenDisabled() {
        let textView = makeTextView(text: "hello\nworld", enableMinimap: true)
        let minimap = textView.minimapViewForTesting
        textView.showMinimap = false
        // Simulate a stale trailing-edge frame left behind without a full collapse.
        minimap.isHidden = false
        minimap.frame = CGRect(x: 400, y: 0, width: 100, height: 600)
        minimap.subviews.forEach { $0.isHidden = false }
        textView.layoutIfNeeded()
        assertMinimapChromeCollapsed(minimap)
    }

    private func assertMinimapChromeCollapsed(_ minimap: MinimapView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(minimap.isHidden, "minimap should be hidden when disabled", file: file, line: line)
        XCTAssertEqual(minimap.frame, .zero, "disabled minimap must not keep a trailing-edge frame", file: file, line: line)
        XCTAssertTrue(minimap.debugViewportIndicatorHidden, "viewport indicator chrome should be hidden", file: file, line: line)
        XCTAssertEqual(minimap.debugViewportIndicatorFrame, .zero, "viewport indicator must not keep a painted frame", file: file, line: line)
    }

    @MainActor
    func testEmptyAndSingleLineDocumentsDoNotCrash() {
        for text in ["", "just one line"] {
            let textView = makeTextView(text: text, language: .markdown)
            let minimap = textView.minimapViewForTesting
            if let bitmap = minimap.bitmapImageRepForCachingDisplay(in: minimap.bounds) {
                minimap.cacheDisplay(in: minimap.bounds, to: bitmap)
            }
        }
    }
}
