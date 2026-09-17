import AppKit
import QuartzCore
import XCTest
@testable import Penumbra
import PenumbraLanguages

final class MarkdownPreviewTests: XCTestCase {
    func testDefaultKeymapBindsCommandBToMarkdownPreview() {
        XCTAssertEqual(
            Keymap.default_.action(for: KeyStroke(KeyChord("b", .command))),
            .toggleMarkdownPreview
        )
    }

    func testSublimeKeymapBindsCommandBToPreviewAndF12ToDefinition() {
        XCTAssertEqual(
            Keymap.sublime.action(for: KeyStroke(KeyChord("b", .command))),
            .toggleMarkdownPreview
        )
        XCTAssertEqual(
            Keymap.sublime.action(for: KeyStroke(KeyChord(code: 0x6F))),
            .goToDefinition
        )
    }

    func testIntelliJKeymapBindsCommandBToPreviewAndF12ToDefinition() {
        XCTAssertEqual(
            Keymap.intelliJ.action(for: KeyStroke(KeyChord("b", .command))),
            .toggleMarkdownPreview
        )
        XCTAssertEqual(
            Keymap.intelliJ.action(for: KeyStroke(KeyChord(code: 0x6F))),
            .goToDefinition
        )
        XCTAssertEqual(
            Keymap.intelliJ.action(for: KeyStroke(KeyChord("b", [.command, .option]))),
            .goToImplementation
        )
    }

    @MainActor
    func testToggleIgnoredForNonMarkdownLanguage() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        textView.languageIdentifier = "swift"
        let controller = MarkdownPreviewController(textView: textView)
        XCTAssertFalse(controller.toggle())
        XCTAssertFalse(controller.isVisible)

        textView.languageIdentifier = "markdown"
        XCTAssertTrue(controller.toggle())
        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(controller.toggle())
        XCTAssertFalse(controller.isVisible)
    }

    @MainActor
    func testToggleIgnoredForNilAndMermaidLanguageIdentifiers() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let controller = MarkdownPreviewController(textView: textView)

        textView.languageIdentifier = nil
        XCTAssertFalse(controller.toggle())

        textView.languageIdentifier = "mermaid"
        XCTAssertFalse(controller.toggle())
    }

    @MainActor
    func testLiveUpdateAfterDebounce() async {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        textView.setState(TextViewState(text: "Initial", theme: DefaultTheme()))
        textView.languageIdentifier = "markdown"
        let controller = MarkdownPreviewController(textView: textView)
        controller.parseDebounceNanoseconds = 10_000_000
        controller.installTextObservation(chaining: nil)
        XCTAssertTrue(controller.toggle())

        textView.text = "# Updated"
        controller.noteTextDidChange()

        try? await Task.sleep(nanoseconds: 30_000_000)
        let hasHeading = controller.previewView.document?.blocks.contains(where: {
            if case .heading(let level, let text) = $0 {
                return level == 1 && String(text.characters).contains("Updated")
            }
            return false
        }) ?? false
        XCTAssertTrue(hasHeading)
    }

    @MainActor
    func testMetalPreviewUsesCAMetalLayerWhenActive() throws {
        guard MetalContext.isAvailable else {
            throw XCTSkip("Metal is not available")
        }
        let defaults = UserDefaults.standard.object(forKey: MetalActivation.defaultsKey) as? Bool
        guard MetalActivation.resolved(property: true, deviceAvailable: true, defaults: defaults) else {
            throw XCTSkip("Metal is disabled via UserDefaults kill switch")
        }

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        textView.isMetalRenderingEnabled = true
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)

        let preview = MarkdownPreviewView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        preview.usesMetalRendering = textView.isMetalRenderingActive
        preview.document = MarkdownPreviewDocument.parse("# Metal\n\nHello")
        preview.layoutSubtreeIfNeeded()

        XCTAssertTrue(textView.isMetalRenderingActive)
        XCTAssertTrue(preview.usesMetalRendering)
        let metalLayer = findMetalLayer(in: preview)
        XCTAssertNotNil(metalLayer, "Preview should host a CAMetalLayer when Metal is active")
    }

    @MainActor
    func testCGPreviewDoesNotUseMetalLayerWhenInactive() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        textView.isMetalRenderingEnabled = false
        let preview = MarkdownPreviewView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        preview.usesMetalRendering = textView.isMetalRenderingActive
        preview.document = MarkdownPreviewDocument.parse("# Core Graphics")
        preview.layoutSubtreeIfNeeded()

        XCTAssertFalse(textView.isMetalRenderingActive)
        XCTAssertFalse(preview.usesMetalRendering)
        let metalView = findMetalCanvasView(in: preview)
        XCTAssertNotNil(metalView)
        XCTAssertTrue(metalView?.isHidden == true, "Metal canvas should stay hidden when CG path is active")
    }

    @MainActor
    func testMetalPreviewTilesOversizedLayout() throws {
        guard MetalContext.isAvailable else {
            throw XCTSkip("Metal is not available")
        }

        let preview = MarkdownPreviewView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        preview.usesMetalRendering = true

        // Taller than a single Metal texture could ever hold — the tile cache must keep Metal
        // active rather than falling back to Core Graphics.
        let maxDimension = MetalTextureUpload.maxTextureDimension
        let tallHeight = CGFloat(maxDimension + 100)
        let layout = MarkdownPreviewLayout(
            blockLayouts: [],
            contentSize: CGSize(width: 320, height: tallHeight)
        )
        preview.applyLayout(layout)

        XCTAssertTrue(preview.usesMetalRendering, "Metal should stay active for an oversized layout via tiling")
        let metalView = findMetalCanvasView(in: preview)
        XCTAssertNotNil(metalView)
        XCTAssertFalse(metalView?.isHidden == true, "Metal canvas should stay visible for an oversized layout")
    }

    @MainActor
    func testMetalPreviewFallsBackWhenDocumentIsTooWideToTile() throws {
        guard MetalContext.isAvailable else {
            throw XCTSkip("Metal is not available")
        }

        let preview = MarkdownPreviewView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        preview.usesMetalRendering = true

        // Wider than a single tile row could ever hold at 2x — horizontal tiling is out of scope,
        // so this is the one remaining legitimate CG fallback for preview size.
        let scale = preview.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let tooWide = CGFloat(MetalTextureUpload.maxTextureDimension) / scale + 100
        let layout = MarkdownPreviewLayout(
            blockLayouts: [],
            contentSize: CGSize(width: tooWide, height: 200)
        )
        preview.applyLayout(layout)

        XCTAssertFalse(preview.usesMetalRendering)
        let metalView = findMetalCanvasView(in: preview)
        XCTAssertTrue(metalView?.isHidden == true, "Metal canvas should stay hidden when the document is too wide to tile")
    }

    /// Regression test for the flip fix in `MarkdownPreviewMetalRenderer.makeTileImage`: without
    /// it, block frames are rasterized against a native (bottom-up) `CGContext`, and the document
    /// ends up mirrored top-to-bottom once uploaded to a texture and presented.
    ///
    /// Does not require a live `MTLDevice` — `makeTileImage` only touches Core Graphics.
    @MainActor
    func testTileRasterOrientationMatchesTopDownDocumentOrder() throws {
        // Explicit, fully-opaque, maximally distinct colors — unlike the semantic system
        // defaults (`.textBackgroundColor` / `.quaternaryLabelColor`), these give a
        // deterministic signal regardless of the test run's light/dark appearance.
        var style = MarkdownPreviewStyle()
        style.backgroundColor = .white
        style.codeBackgroundColor = .black
        // A code block always paints an unconditional `codeBackgroundColor` fill for its frame,
        // regardless of highlighted/plain text — an unambiguous, easy-to-detect fill. Starts
        // right at the document/tile top and is tall enough that a sample well inside it is
        // insensitive to the exact flip-formula rounding.
        let blockFrame = CGRect(x: 0, y: 0, width: 200, height: 100) // document TOP
        let blockLayout = MarkdownPreviewBlockLayout(
            block: .codeBlock(language: nil, source: "x"),
            frame: blockFrame,
            textFrames: [blockFrame]
        )
        let contentSize = CGSize(width: 200, height: 2000)
        let layout = MarkdownPreviewLayout(blockLayouts: [blockLayout], contentSize: contentSize)

        let renderer = MarkdownPreviewMetalRenderer()
        // Sets the renderer's stored layout/style/raster inputs; the Bool result (needs a live
        // Metal device) is irrelevant here — only `makeTileImage`'s CG output is under test.
        _ = renderer.update(layout: layout, style: style, rasterImages: [:], highlightedCode: [:])

        guard let grid = MarkdownPreviewTileGrid(contentSize: contentSize, scale: 2, maxTilePixelHeight: 1024) else {
            XCTFail("Expected a valid tile grid")
            return
        }
        guard let tileImage = renderer.makeTileImage(index: 0, grid: grid) else {
            XCTFail("Expected tile 0 to rasterize")
            return
        }

        // Mirrors `MarkdownPreviewMetalRenderer.uploadTexture`'s own "redraw into a plain
        // context, inspect the raw buffer directly" step: buffer row 0 after this redraw is
        // exactly what `texture.replace` hands to texture row 0, i.e. what `CAMetalLayer`
        // presents at the top of the screen.
        let width = tileImage.width
        let height = tileImage.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let uploadContext = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            XCTFail("Expected an upload-style context")
            return
        }
        uploadContext.draw(tileImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        func isBackground(rowIndex: Int) -> Bool {
            let offset = rowIndex * bytesPerRow + (width / 2) * 4
            let bg = rgb255(style.backgroundColor)
            return abs(Int(bytes[offset]) - bg.0) <= 10
                && abs(Int(bytes[offset + 1]) - bg.1) <= 10
                && abs(Int(bytes[offset + 2]) - bg.2) <= 10
        }

        // The 100pt-tall (200px at 2x) block occupies roughly texture rows 0–199; sample well
        // inside that with margin for the flip formula's rounding, and well outside it near the
        // tile's far (empty) end.
        XCTAssertFalse(isBackground(rowIndex: 50), "Document-top content should land near texture row 0 (screen top), not be mirrored to the bottom")
        XCTAssertTrue(isBackground(rowIndex: height - 50), "Nothing is drawn near this tile's bottom; it must stay background, not show the top block")
    }

    private func rgb255(_ color: NSColor) -> (Int, Int, Int) {
        let converted = color.usingColorSpace(.deviceRGB) ?? color
        return (
            Int((converted.redComponent * 255).rounded()),
            Int((converted.greenComponent * 255).rounded()),
            Int((converted.blueComponent * 255).rounded())
        )
    }

    func testMermaidErrorForInvalidDiagram() async {
        let result = await MermaidPaintAdapter.render(
            source: "gantt\n  title Bad\n  section A\n  task : 2024-01-01, 1d",
            mermaidStyle: MarkdownPreviewStyle().mermaidRenderingContext,
            contentWidth: 300
        )
        XCTAssertNil(result.image)
        XCTAssertNotNil(result.errorMessage)
    }

    func testImageURLResolutionBlocksHTTP() {
        XCTAssertNil(MarkdownPreviewImageLoader.resolveURL("https://example.com/x.png", baseURL: nil))
        let file = URL(fileURLWithPath: "/tmp/doc.md")
        let resolved = MarkdownPreviewImageLoader.resolveURL("diagram.png", baseURL: file.deletingLastPathComponent())
        XCTAssertEqual(resolved?.lastPathComponent, "diagram.png")
    }

    func testParseImageBlock() {
        let document = MarkdownPreviewDocument.parse("![Alt text](images/pic.png)")
        XCTAssertTrue(document.blocks.contains(where: {
            if case .image(let alt, let ref) = $0 {
                return alt == "Alt text" && ref == "images/pic.png"
            }
            return false
        }))
    }

    func testMermaidAccessibilityDescriptionIncludesSource() {
        let document = MarkdownPreviewDocument.parse("```mermaid\ngraph TD\n  A-->B\n```")
        XCTAssertTrue(document.accessibilityDescriptions.contains(where: { $0.contains("graph TD") }))
    }

    @MainActor
    private func findMetalLayer(in view: NSView) -> CAMetalLayer? {
        if let canvas = findMetalCanvasView(in: view), !canvas.isHidden {
            return canvas.layer as? CAMetalLayer
        }
        return nil
    }

    @MainActor
    private func findMetalCanvasView(in view: NSView) -> NSView? {
        if view.layer is CAMetalLayer { return view }
        for subview in view.subviews {
            if let found = findMetalCanvasView(in: subview) { return found }
        }
        return nil
    }

    func testParseHeadingsListsAndFences() {
        let source = """
        # Title

        A paragraph with **bold**.

        - one
        - two

        ```mermaid
        graph TD
          A --> B
        ```

        ```swift
        let x = 1
        ```
        """
        let document = MarkdownPreviewDocument.parse(source)
        XCTAssertTrue(document.blocks.contains(where: {
            if case .heading(let level, _) = $0 { return level == 1 }
            return false
        }))
        XCTAssertTrue(document.blocks.contains(where: {
            if case .unorderedList = $0 { return true }
            return false
        }))
        XCTAssertTrue(document.blocks.contains(where: {
            if case .mermaid = $0 { return true }
            return false
        }))
        XCTAssertTrue(document.blocks.contains(where: {
            if case .codeBlock(let language, _) = $0 { return language == "swift" }
            return false
        }))
    }

    func testFenceLanguageNormalization() {
        XCTAssertEqual(MarkdownPreviewFenceLanguage.normalize("js"), "javascript")
        XCTAssertEqual(MarkdownPreviewFenceLanguage.normalize("TSX"), "typescript")
        XCTAssertEqual(MarkdownPreviewFenceLanguage.normalize("  swift "), "swift")
        XCTAssertNil(MarkdownPreviewFenceLanguage.normalize(nil))
        XCTAssertNil(MarkdownPreviewFenceLanguage.normalize(""))
    }

    func testCodeBlockHighlightingAppliesSyntaxColors() {
        let highlighted = MarkdownPreviewCodeHighlighter.highlight(
            source: "const answer = 42",
            languageHint: "js",
            theme: DefaultTheme(),
            languageResolver: { TreeSitterLanguage.bundled(forIdentifier: $0) }
        )
        guard let highlighted else {
            return XCTFail("Expected highlighted code for javascript fence")
        }
        let defaultColor = DefaultTheme().textColor
        var sawDistinctColor = false
        highlighted.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: highlighted.length)) { value, _, _ in
            if let color = value as? NSColor, !colorsAreEqual(color, defaultColor) {
                sawDistinctColor = true
            }
        }
        XCTAssertTrue(sawDistinctColor, "Highlighted code should use theme token colors")
    }

    @MainActor
    func testPreviewControllerHighlightsCodeFences() async {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        textView.setState(TextViewState(text: "```javascript\nconst x = 1\n```", theme: DefaultTheme()))
        textView.languageIdentifier = "markdown"
        let controller = MarkdownPreviewController(textView: textView)
        controller.parseDebounceNanoseconds = 10_000_000
        controller.codeBlockLanguageResolver = { TreeSitterLanguage.bundled(forIdentifier: $0) }
        XCTAssertTrue(controller.toggle())

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(controller.previewView.highlightedCode.isEmpty)
    }

    func testMermaidFenceExtractor() {
        let segments = MermaidFenceExtractor.segments(in: "text\n```mermaid\ngraph TD\nA-->B\n```\ntail")
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0], .prose("text\n"))
        if case .fencedCode(let language, let body) = segments[1] {
            XCTAssertEqual(language, "mermaid")
            XCTAssertTrue(body.contains("graph TD"))
        } else {
            XCTFail("Expected mermaid fence")
        }
    }

    func testMermaidImageRendersFlowchartWithInk() async throws {
        let source = "graph TD\n  A --> B"
        let style = MarkdownPreviewStyle()
        let result = await MermaidPaintAdapter.render(
            source: source,
            mermaidStyle: style.mermaidRenderingContext,
            contentWidth: 300
        )
        guard let image = result.image else {
            return XCTFail("Expected rendered image: \(result.errorMessage ?? "unknown")")
        }
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
        let samples = [
            samplePixel(image: image, x: image.width / 4, y: image.height / 4),
            samplePixel(image: image, x: image.width / 2, y: image.height / 2),
            samplePixel(image: image, x: 3 * image.width / 4, y: 3 * image.height / 4)
        ]
        XCTAssertTrue(samples.contains(where: { $0 > 0 }), "Diagram should contain visible pixels")
        XCTAssertGreaterThan(Set(samples).count, 1, "Diagram should not be a flat fill")
    }

    private func colorsAreEqual(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let l = lhs.usingColorSpace(.deviceRGB), let r = rhs.usingColorSpace(.deviceRGB) else {
            return false
        }
        return abs(l.redComponent - r.redComponent) < 0.01
            && abs(l.greenComponent - r.greenComponent) < 0.01
            && abs(l.blueComponent - r.blueComponent) < 0.01
    }

    private func samplePixel(image: CGImage, x: Int, y: Int) -> Int {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return 0 }
        let bytesPerRow = image.bytesPerRow
        let offset = y * bytesPerRow + x * 4
        return Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
    }
}
