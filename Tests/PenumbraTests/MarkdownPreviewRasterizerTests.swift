import AppKit
import XCTest
@testable import Penumbra

/// Tests for `MarkdownPreviewRasterizer` — the standalone (no host `TextView` required)
/// mermaid/image/code-fence rasterization pipeline a non-editor host drives directly.
final class MarkdownPreviewRasterizerTests: XCTestCase {
    func testEmptyDocumentProducesEmptyResult() async {
        let document = MarkdownPreviewDocument.parse("Just a paragraph, no fences or images.")
        let result = await MarkdownPreviewRasterizer.rasterize(
            document: document,
            style: MarkdownPreviewStyle(),
            contentWidth: 300
        )
        XCTAssertTrue(result.images.isEmpty)
        XCTAssertTrue(result.highlightedCode.isEmpty)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidMermaidFenceProducesAnImage() async {
        let document = MarkdownPreviewDocument.parse("""
        ```mermaid
        pie title Preview render time by phase
            "Parse" : 15
            "Layout" : 25
        ```
        """)
        let result = await MarkdownPreviewRasterizer.rasterize(
            document: document,
            style: MarkdownPreviewStyle(),
            contentWidth: 300
        )
        XCTAssertEqual(result.images.count, 1)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testInvalidMermaidFenceProducesAnError() async {
        let document = MarkdownPreviewDocument.parse("""
        ```mermaid
        thisisnotamermaidtype
          nope
        ```
        """)
        let result = await MarkdownPreviewRasterizer.rasterize(
            document: document,
            style: MarkdownPreviewStyle(),
            contentWidth: 300
        )
        XCTAssertTrue(result.images.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
    }

    func testCodeFenceWithoutResolverStaysUnhighlighted() async {
        let document = MarkdownPreviewDocument.parse("""
        ```swift
        let x = 1
        ```
        """)
        let result = await MarkdownPreviewRasterizer.rasterize(
            document: document,
            style: MarkdownPreviewStyle(),
            contentWidth: 300
        )
        XCTAssertTrue(result.highlightedCode.isEmpty)
    }

    func testRemoteImageReferenceIsSkipped() async {
        let document = MarkdownPreviewDocument.parse("![alt](https://example.com/pic.png)")
        let result = await MarkdownPreviewRasterizer.rasterize(
            document: document,
            style: MarkdownPreviewStyle(),
            contentWidth: 300
        )
        XCTAssertTrue(result.images.isEmpty)
    }
}
