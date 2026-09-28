import AppKit
import XCTest
@testable import Penumbra

/// Tests for `MarkdownPreviewRasterCache` and `MarkdownPreviewRasterWorker`: diagrams, code and
/// images are reused by content across edits instead of re-rendered.
final class MarkdownPreviewRasterCacheTests: XCTestCase {
    private let flowchart = "```mermaid\ngraph TD\nA-->B\n```"
    private let sequence = "```mermaid\nsequenceDiagram\nA->>B: hi\n```"

    /// Counts renders and returns a 1×1 image per diagram.
    private final class CountingRenderer: @unchecked Sendable {
        private let lock = NSLock()
        private var sources: [String] = []

        var renderedSources: [String] { lock.withLock { sources } }

        var render: MarkdownPreviewMermaidRender {
            { [self] source, _, _ in
                lock.withLock { sources.append(source) }
                return MermaidPaintResult(height: 80, image: Self.pixel(), naturalSize: CGSize(width: 10, height: 10))
            }
        }

        static func pixel() -> CGImage? {
            CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    private func inputs(style: MarkdownPreviewStyle = MarkdownPreviewStyle(), theme: Theme = DefaultTheme()) -> MarkdownPreviewRasterInputs {
        MarkdownPreviewRasterInputs(
            baseURL: nil,
            mermaidContext: style.mermaidRenderingContext,
            contentWidth: 400,
            syntaxTheme: theme,
            languageResolver: { TreeSitterLanguage.bundled(forIdentifier: $0) },
            languageProvider: nil
        )
    }

    /// `resolve` then `renderMermaid`, as the controller runs them.
    private func rasterize(
        _ source: String,
        inputs: MarkdownPreviewRasterInputs,
        cache: MarkdownPreviewRasterCache,
        renderer: CountingRenderer
    ) async -> (MarkdownPreviewDocument, MarkdownPreviewRasterResult) {
        let document = MarkdownPreviewDocument.parse(source)
        var pass = MarkdownPreviewRasterWorker.resolve(document: document, inputs: inputs, cache: cache)
        let rendered = await MarkdownPreviewRasterWorker.renderMermaid(
            pass.pendingMermaid, inputs: inputs, cache: cache, render: renderer.render
        )
        pass.result.merge(rendered)
        return (document, pass.result)
    }

    func testEditingProseDoesNotRerenderUnchangedDiagrams() async {
        let cache = MarkdownPreviewRasterCache()
        let renderer = CountingRenderer()
        let inputs = inputs()
        _ = await rasterize("Intro\n\n\(flowchart)\n\n\(sequence)", inputs: inputs, cache: cache, renderer: renderer)
        XCTAssertEqual(renderer.renderedSources.count, 2)

        let (_, result) = await rasterize("Intro, edited\n\n\(flowchart)\n\n\(sequence)", inputs: inputs, cache: cache, renderer: renderer)
        XCTAssertEqual(renderer.renderedSources.count, 2, "Unchanged diagrams come from the cache")
        XCTAssertEqual(result.images.count, 2)
    }

    func testEditingOneDiagramRerendersOnlyThatDiagram() async {
        let cache = MarkdownPreviewRasterCache()
        let renderer = CountingRenderer()
        let inputs = inputs()
        _ = await rasterize("\(flowchart)\n\n\(sequence)", inputs: inputs, cache: cache, renderer: renderer)
        let edited = "```mermaid\ngraph TD\nA-->C\n```"
        _ = await rasterize("\(edited)\n\n\(sequence)", inputs: inputs, cache: cache, renderer: renderer)
        XCTAssertEqual(renderer.renderedSources, ["graph TD\nA-->B", "sequenceDiagram\nA->>B: hi", "graph TD\nA-->C"])
    }

    func testDiagramMovedToAnotherBlockIndexIsReused() async {
        let cache = MarkdownPreviewRasterCache()
        let renderer = CountingRenderer()
        let inputs = inputs()
        let (_, first) = await rasterize(flowchart, inputs: inputs, cache: cache, renderer: renderer)
        let (document, moved) = await rasterize("# Title\n\nNew paragraph\n\n\(flowchart)", inputs: inputs, cache: cache, renderer: renderer)

        XCTAssertEqual(renderer.renderedSources.count, 1)
        guard let index = document.blocks.firstIndex(where: { if case .mermaid = $0.kind { return true }; return false }) else {
            return XCTFail("Expected a mermaid block")
        }
        XCTAssertGreaterThan(index, 0)
        XCTAssertTrue(moved.images[index] === first.images[0], "The same rendered image is reused at its new index")
    }

    func testThemeColorsChangeMissesTheCache() async {
        let cache = MarkdownPreviewRasterCache()
        let renderer = CountingRenderer()
        _ = await rasterize(flowchart, inputs: inputs(), cache: cache, renderer: renderer)
        var dark = MarkdownPreviewStyle()
        dark.backgroundColor = .black
        dark.bodyColor = .white
        _ = await rasterize(flowchart, inputs: inputs(style: dark), cache: cache, renderer: renderer)
        XCTAssertEqual(renderer.renderedSources.count, 2)
    }

    func testMermaidErrorsAreCachedToo() async {
        let cache = MarkdownPreviewRasterCache()
        var renders = 0
        let failing: MarkdownPreviewMermaidRender = { _, _, _ in
            MermaidPaintResult(height: 120, image: nil, errorMessage: "bad diagram")
        }
        let inputs = inputs()
        for _ in 0 ..< 2 {
            let document = MarkdownPreviewDocument.parse(flowchart)
            let pass = MarkdownPreviewRasterWorker.resolve(document: document, inputs: inputs, cache: cache)
            renders += pass.pendingMermaid.count
            let rendered = await MarkdownPreviewRasterWorker.renderMermaid(pass.pendingMermaid, inputs: inputs, cache: cache, render: failing)
            XCTAssertEqual(pass.result.errors.merging(rendered.errors) { $1 }, [0: "bad diagram"])
        }
        XCTAssertEqual(renders, 1)
    }

    func testCancelledRenderStopsButKeepsFinishedDiagrams() async {
        let cache = MarkdownPreviewRasterCache()
        let renderer = CountingRenderer()
        let inputs = inputs()
        let document = MarkdownPreviewDocument.parse("\(flowchart)\n\n\(sequence)")
        let pass = MarkdownPreviewRasterWorker.resolve(document: document, inputs: inputs, cache: cache)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await MarkdownPreviewRasterWorker.renderMermaid(pass.pendingMermaid, inputs: inputs, cache: cache, render: renderer.render)
        }
        let result = await task.value
        XCTAssertTrue(result.images.isEmpty)
        XCTAssertTrue(renderer.renderedSources.isEmpty)
    }

    func testHighlightedCodeIsReusedUntilTheThemeChanges() {
        let cache = MarkdownPreviewRasterCache()
        let theme = DefaultTheme()
        let document = MarkdownPreviewDocument.parse("```javascript\nconst x = 1\n```")
        let first = MarkdownPreviewRasterWorker.resolve(document: document, inputs: inputs(theme: theme), cache: cache)
        let second = MarkdownPreviewRasterWorker.resolve(document: document, inputs: inputs(theme: theme), cache: cache)
        XCTAssertNotNil(first.result.highlightedCode[0])
        XCTAssertTrue(first.result.highlightedCode[0] === second.result.highlightedCode[0])

        let third = MarkdownPreviewRasterWorker.resolve(document: document, inputs: inputs(theme: DefaultTheme()), cache: cache)
        XCTAssertFalse(first.result.highlightedCode[0] === third.result.highlightedCode[0])
    }

    func testEntryCountBoundEvictsLeastRecentlyUsed() {
        let cache = MarkdownPreviewRasterCache(maxEntries: 2)
        let context = MarkdownPreviewStyle().mermaidRenderingContext
        let entry = MarkdownPreviewRasterCache.MermaidEntry(image: CountingRenderer.pixel(), naturalSize: nil, errorMessage: nil)
        cache.storeMermaid(entry, source: "a", context: context)
        cache.storeMermaid(entry, source: "b", context: context)
        _ = cache.mermaid(source: "a", context: context)
        cache.storeMermaid(entry, source: "c", context: context)

        XCTAssertEqual(cache.count, 2)
        XCTAssertNotNil(cache.mermaid(source: "a", context: context))
        XCTAssertNil(cache.mermaid(source: "b", context: context), "The least recently used entry goes first")
        XCTAssertNotNil(cache.mermaid(source: "c", context: context))
    }

    func testByteBoundEvictsOldEntries() {
        let image = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let cache = MarkdownPreviewRasterCache(maxBytes: image.bytesPerRow * image.height * 2)
        for index in 0 ..< 5 {
            cache.storeImage(image, path: "/tmp/\(index).png", modified: nil)
        }
        XCTAssertEqual(cache.count, 2)
        XCTAssertNotNil(cache.image(path: "/tmp/4.png", modified: nil))
    }

    func testChangedImageFileIsReloaded() {
        let cache = MarkdownPreviewRasterCache()
        let image = CountingRenderer.pixel()!
        cache.storeImage(image, path: "/tmp/a.png", modified: Date(timeIntervalSince1970: 1))
        XCTAssertNil(cache.image(path: "/tmp/a.png", modified: Date(timeIntervalSince1970: 2)))
    }
}
