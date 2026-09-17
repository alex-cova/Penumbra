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

    func testMermaidErrorForInvalidDiagram() async {
        let result = await MermaidPaintAdapter.render(
            source: "gantt\n  title Bad\n  section A\n  task : 2024-01-01, 1d",
            style: MarkdownPreviewStyle(),
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
        let result = await MermaidPaintAdapter.render(source: source, style: style, contentWidth: 300)
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
