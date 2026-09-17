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

        await controller.waitForPendingWork()
        let hasHeading = controller.previewView.document?.blocks.contains(where: {
            if case .heading(let level, let text) = $0.kind {
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

    /// Regression test for the blank-preview-pane bug: `MarkdownPreviewMetalCanvasView` sets
    /// `layerContentsRedrawPolicy = .never`, which means `needsDisplay = true` alone never reaches
    /// `updateLayer()`/`present()` — the canvas could stay hidden-behind-a-clear-color forever
    /// while every higher-level flag (`isHidden`, `usesMetalRendering`) looked correct. This drives
    /// a full layout pass in a real window and asserts a drawable was actually presented with tiles.
    @MainActor
    func testMetalPreviewActuallyPresents() throws {
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
        let preview = MarkdownPreviewView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.contentView = preview
        window.makeKeyAndOrderFront(nil)

        preview.usesMetalRendering = true
        preview.document = MarkdownPreviewDocument.parse("# Metal\n\nHello, this is a preview paragraph.")
        preview.layoutSubtreeIfNeeded()
        pumpMainRunLoop()

        XCTAssertTrue(preview.usesMetalRendering)
        XCTAssertGreaterThan(
            preview.debugMetalPresentedTileCount, 0,
            "The Metal canvas must actually present at least one tile, not just clear to the background color"
        )
    }

    /// Regression test for the stale-`visibleRect` bug: rasterizing against a leftover rect from a
    /// taller previous document (or none at all) could select zero tiles for the new, shorter
    /// document — `update()` would still report success, silently presenting an empty frame.
    /// Exercises `MarkdownPreviewMetalRenderer` directly (no window needed) since tile *selection*
    /// is independent of whether the canvas can currently present.
    @MainActor
    func testMetalRendererClampsStaleVisibleRectOnShorterDocument() throws {
        guard MetalContext.isAvailable else {
            throw XCTSkip("Metal is not available")
        }

        let renderer = MarkdownPreviewMetalRenderer()
        let style = MarkdownPreviewStyle()

        let tallLayout = MarkdownPreviewLayout(blockLayouts: [], contentSize: CGSize(width: 320, height: 5000))
        XCTAssertTrue(renderer.update(layout: tallLayout, style: style, rasterImages: [:]))
        renderer.setVisibleRect(CGRect(x: 0, y: 4500, width: 320, height: 240))
        XCTAssertGreaterThan(renderer.lastRequestedTileCount, 0)

        // Swap in a much shorter document without ever explicitly resetting the visible rect —
        // the scenario that used to leave `visibleRect.minY` past the new document's height.
        let shortLayout = MarkdownPreviewLayout(blockLayouts: [], contentSize: CGSize(width: 320, height: 400))
        XCTAssertTrue(renderer.update(layout: shortLayout, style: style, rasterImages: [:]))
        XCTAssertGreaterThan(
            renderer.lastRequestedTileCount, 0,
            "A stale visible rect from a taller previous document must not leave the renderer selecting zero tiles"
        )
    }

    /// Guards the ambiguous-layout fix: `documentView`/`contentView` are frame-driven (sized by
    /// `applyLayout`), not Auto Layout participants with no width/height constraint of their own.
    @MainActor
    func testCGPreviewContentViewHasNonZeroSize() {
        let preview = MarkdownPreviewView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        preview.usesMetalRendering = false
        preview.document = MarkdownPreviewDocument.parse(
            "# Heading\n\nA paragraph long enough to produce a reasonably tall layout for this assertion."
        )
        preview.layoutSubtreeIfNeeded()

        guard let size = preview.debugDocumentView?.frame.size else {
            XCTFail("Expected a document view")
            return
        }
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    /// Guards the scroll-geometry fix: the document view must be flipped so it agrees with
    /// `MarkdownPreviewContentView` (also flipped) and with the tile grid's top-down indexing —
    /// otherwise the pane opens scrolled to the bottom and `documentVisibleRect` is measured from
    /// the wrong end.
    @MainActor
    func testPreviewDocumentViewIsFlipped() {
        let preview = MarkdownPreviewView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        preview.document = MarkdownPreviewDocument.parse("# Heading")
        preview.layoutSubtreeIfNeeded()

        guard let documentView = preview.debugDocumentView else {
            XCTFail("Expected a document view")
            return
        }
        XCTAssertTrue(
            documentView.isFlipped,
            "Document view must be flipped to open scrolled to the top and agree with the tile grid's coordinate space"
        )
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
            block: MarkdownPreviewBlock(kind: .codeBlock(language: nil, source: "x")),
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
            source: "thisisnotamermaidtype\n  nope",
            mermaidStyle: MarkdownPreviewStyle().mermaidRenderingContext,
            contentWidth: 300
        )
        XCTAssertNil(result.image)
        XCTAssertNotNil(result.errorMessage)
        XCTAssertTrue(result.errorMessage?.contains("Unsupported") == true)
    }

    func testMermaidPieChartRenders() async {
        let result = await MermaidPaintAdapter.render(
            source: """
            pie title Preview render time by phase
                "Parse" : 15
                "Layout" : 25
                "Tile" : 20
                "Metal present" : 40
            """,
            mermaidStyle: MarkdownPreviewStyle().mermaidRenderingContext,
            contentWidth: 300
        )
        XCTAssertNotNil(result.image)
        XCTAssertNil(result.errorMessage)
        XCTAssertGreaterThan(result.height, 80)
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
            if case .image(let alt, let ref) = $0.kind {
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
            if case .heading(let level, _) = $0.kind { return level == 1 }
            return false
        }))
        XCTAssertTrue(document.blocks.contains(where: {
            if case .list(let list) = $0.kind {
                return list.items.allSatisfy { if case .bullet = $0.marker { return true }; return false }
            }
            return false
        }))
        XCTAssertTrue(document.blocks.contains(where: {
            if case .mermaid = $0.kind { return true }
            return false
        }))
        XCTAssertTrue(document.blocks.contains(where: {
            if case .codeBlock(let language, _) = $0.kind { return language == "swift" }
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

    /// Regression test: `MarkdownPreviewFenceLanguage.normalize` maps `sh`/`shell`/`zsh` fences to
    /// `"bash"`, so `BundledLanguages` must resolve that identifier too, or every ` ```bash ` /
    /// ` ```sh ` fence in a markdown preview silently renders unhighlighted.
    func testBashAndDiffFencesResolveAndHighlight() {
        let fences: [(hint: String, source: String)] = [
            ("bash", "echo \"hello $USER\""),
            ("sh", "echo \"hello $USER\""),
            ("diff", "-old line\n+new line")
        ]
        let defaultColor = DefaultTheme().textColor
        for fence in fences {
            let highlighted = MarkdownPreviewCodeHighlighter.highlight(
                source: fence.source,
                languageHint: fence.hint,
                theme: DefaultTheme(),
                languageResolver: { TreeSitterLanguage.bundled(forIdentifier: $0) }
            )
            guard let highlighted else {
                XCTFail("Expected highlighted code for '\(fence.hint)' fence")
                continue
            }
            var sawDistinctColor = false
            highlighted.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: highlighted.length)) { value, _, _ in
                if let color = value as? NSColor, !colorsAreEqual(color, defaultColor) {
                    sawDistinctColor = true
                }
            }
            XCTAssertTrue(sawDistinctColor, "'\(fence.hint)' fence should use theme token colors")
        }
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

        await controller.waitForPendingWork()
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

    /// Regression test for the mirrored/rotated-180 mermaid bug: `MarkdownPreviewCGRenderer`
    /// drew raster images with a bare `context.draw(image, in: frame)` into the top-down (flipped)
    /// CTM every block shares, without the local un-flip every *text* draw applies — so an image
    /// with visibly asymmetric top/bottom halves ended up with its top half at the visual bottom.
    /// Mirrors `testTileRasterOrientationMatchesTopDownDocumentOrder`'s pixel-sampling approach but
    /// exercises the `.mermaid` image path instead of a plain fill.
    @MainActor
    func testMermaidImageOrientationNotMirrored() throws {
        // Opaque red in the top half of the source image, transparent in the bottom half — an
        // unambiguous, asymmetric signal for which half ends up where after painting.
        let imageWidth = 40
        let imageHeight = 40
        guard let sourceContext = CGContext(
            data: nil, width: imageWidth, height: imageHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            XCTFail("Expected a bitmap context")
            return
        }
        // CGContext is bottom-up by default: filling y >= imageHeight/2 paints the image's TOP half red.
        sourceContext.setFillColor(NSColor.red.cgColor)
        sourceContext.fill(CGRect(x: 0, y: imageHeight / 2, width: imageWidth, height: imageHeight / 2))
        guard let sourceImage = sourceContext.makeImage() else {
            XCTFail("Expected a source image")
            return
        }

        var style = MarkdownPreviewStyle()
        style.backgroundColor = .white

        let blockFrame = CGRect(x: 0, y: 0, width: 100, height: 100) // document TOP
        let blockLayout = MarkdownPreviewBlockLayout(
            block: MarkdownPreviewBlock(kind: .mermaid(source: "graph TD\nA-->B")),
            frame: blockFrame,
            textFrames: [blockFrame]
        )
        let contentSize = CGSize(width: 100, height: 100) // exactly one block, no scrolled offset to reason about
        let layout = MarkdownPreviewLayout(blockLayouts: [blockLayout], contentSize: contentSize)

        // AppKit path: `MarkdownPreviewContentView.isFlipped == true`, so hand `draw(...)` a
        // top-down bitmap context the same way AppKit's own graphics context would be.
        let pixelSize = 200 // contentSize at 2x
        guard let paintContext = CGContext(
            data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            XCTFail("Expected a paint context")
            return
        }
        paintContext.scaleBy(x: 2, y: 2)
        paintContext.translateBy(x: 0, y: contentSize.height)
        paintContext.scaleBy(x: 1, y: -1) // top-down, matching an AppKit flipped view's graphics context

        MarkdownPreviewCGRenderer.draw(
            layout: layout, style: style, rasterImages: [0: sourceImage], in: paintContext,
            bounds: CGRect(origin: .zero, size: contentSize)
        )
        guard let painted = paintContext.makeImage() else {
            XCTFail("Expected a painted image")
            return
        }

        // A `CGImage`'s raw `dataProvider.data` row order is not guaranteed to match its visual
        // top-to-bottom order regardless of the CTM used to draw it — redraw into a known
        // "upload-style" context first (mirroring `MarkdownPreviewMetalRenderer.uploadTexture` and
        // `testTileRasterOrientationMatchesTopDownDocumentOrder`) so buffer row 0 is unambiguously
        // the visual top, i.e. what a screen or a Metal tile upload would actually show.
        let width = painted.width
        let height = painted.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let uploadContext = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            XCTFail("Expected an upload-style context")
            return
        }
        uploadContext.draw(painted, in: CGRect(x: 0, y: 0, width: width, height: height))

        // `premultipliedFirst | byteOrder32Little` stores each pixel as B, G, R, A in memory.
        func isRedish(row: Int) -> Bool {
            let offset = row * bytesPerRow + (width / 2) * 4
            return Int(bytes[offset + 2]) > 150 && Int(bytes[offset]) < 100
        }

        // blockFrame is 100pt tall at 2x scale = 200px, filling the whole painted buffer; the
        // source image's red top half must land near buffer row 0 (screen top), not row `height`.
        XCTAssertTrue(isRedish(row: 20), "The image's top (red) half should land near the top of the painted buffer")
        XCTAssertFalse(isRedish(row: height - 20), "The image's bottom (transparent) half should not land at the top")
    }

    /// Companion regression at the vendor boundary: a real flowchart, rasterized through
    /// `MermaidPaintAdapter.rasterize` (the actual mermaid paint path, not a synthetic image),
    /// should come out right-side-up. `MermaidPaintAdapter.rasterize` documents that it matches
    /// the vendor's own AppKit flip convention (`ImageRenderer.swift`); this pins that convention
    /// so a future vendor re-sync can't silently drop the flip without a test noticing.
    ///
    /// Uses one node with a short label and one with a much longer label, connected by a single
    /// edge, and measures ink *width* (a node's horizontal extent tracks its label width directly)
    /// within the first and last thirds of the diagram's own content range — not fixed fractions
    /// of the full image, since the diagram is padded and doesn't fill it edge to edge.
    func testMermaidVendorRasterOrientationIsUpright() async throws {
        let source = "flowchart TD\n  A[Sm] --> B[This Is A Much Wider Bottom Node Label]"
        let style = MarkdownPreviewStyle()
        let result = await MermaidPaintAdapter.render(
            source: source, mermaidStyle: style.mermaidRenderingContext, contentWidth: 600
        )
        guard let image = result.image else {
            return XCTFail("Expected rendered image: \(result.errorMessage ?? "unknown")")
        }

        // Normalize row order the same way `testMermaidImageOrientationNotMirrored` does.
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let uploadContext = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            XCTFail("Expected an upload-style context")
            return
        }
        uploadContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // The diagram theme is opaque (not transparent), so every pixel has alpha 255 including
        // the background fill — "ink" has to be detected by color distance from the background,
        // not by alpha. `premultipliedFirst | byteOrder32Little` stores each pixel as B, G, R, A.
        let bg = rgb255(style.backgroundColor)
        func isInk(row: Int, x: Int) -> Bool {
            let offset = row * bytesPerRow + x * 4
            let delta = abs(Int(bytes[offset + 2]) - bg.0)
                + abs(Int(bytes[offset + 1]) - bg.1)
                + abs(Int(bytes[offset]) - bg.2)
            return delta > 30
        }
        func rowHasInk(_ row: Int) -> Bool {
            (0..<width).contains { isInk(row: row, x: $0) }
        }
        func inkWidth(in rowRange: Range<Int>) -> Int {
            var minX = width
            var maxX = -1
            for row in rowRange {
                for x in 0..<width where isInk(row: row, x: x) {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
            return maxX >= minX ? (maxX - minX) : 0
        }

        // Locate the diagram's own content range first — mermaid diagrams are padded, so a fixed
        // fraction of the full image height (e.g. the first/last sixth) can land entirely in empty
        // padding and make every comparison trivially `0 == 0`, as an earlier version of this test
        // discovered.
        guard let minInkRow = (0..<height).first(where: rowHasInk),
              let maxInkRow = (0..<height).reversed().first(where: rowHasInk),
              maxInkRow > minInkRow else {
            XCTFail("Expected ink spread across multiple rows")
            return
        }
        let contentHeight = maxInkRow - minInkRow + 1
        let third = max(contentHeight / 3, 1)
        let topThird = minInkRow..<min(minInkRow + third, height)
        let bottomThird = max(maxInkRow - third + 1, 0)..<(maxInkRow + 1)

        // Upright: the narrow "Sm" node is near the top of the content range, the wide-label node
        // near the bottom, so top ink-width < bottom ink-width. A mirrored render would flip this.
        XCTAssertLessThan(
            inkWidth(in: topThird), inkWidth(in: bottomThird),
            "The narrow node should land near the top of the diagram and the wide-label node near the bottom"
        )
    }

    /// A diagram smaller than the pane must not be stretched up to fill it — `MermaidPaintResult`
    /// carries `naturalSize` precisely so `MarkdownPreviewView.rasterHeights` can cap display width
    /// at the diagram's own extent instead of always stretching to `contentWidth`.
    func testMermaidDiagramNotUpscaledPastNaturalSize() async throws {
        let style = MarkdownPreviewStyle()
        let result = await MermaidPaintAdapter.render(
            source: "graph TD\n  A --> B",
            mermaidStyle: style.mermaidRenderingContext,
            contentWidth: 2000 // much wider than any small two-node flowchart's natural size
        )
        guard let naturalSize = result.naturalSize else {
            return XCTFail("Expected a natural size for a successfully rendered diagram")
        }
        XCTAssertLessThan(naturalSize.width, 2000, "A small flowchart's natural width should be far below an oversized pane")
        XCTAssertEqual(result.height, max(naturalSize.height, 80), accuracy: 0.5, "Display height should match the natural (unstretched) height")
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
