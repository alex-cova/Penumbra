import AppKit
import XCTest
@testable import Penumbra

/// Tests for `MarkdownPreviewView.preferredContentSize(forWidth:)` — the intrinsic-size query a
/// host uses to size an inline (non-scrolling) embed of the preview, e.g. a chat bubble, without
/// ever laying the view out on screen.
final class MarkdownPreviewViewSizingTests: XCTestCase {
    @MainActor
    func testPreferredContentSizeIsZeroWithoutDocument() {
        let preview = MarkdownPreviewView(frame: .zero)
        XCTAssertEqual(preview.preferredContentSize(forWidth: 320), .zero)
    }

    @MainActor
    func testPreferredContentSizeMatchesLayoutContentSizeBeforeAnyOnScreenLayout() {
        let preview = MarkdownPreviewView(frame: .zero)
        preview.document = MarkdownPreviewDocument.parse("# Title\n\nSome body text.")

        // Queried with no window, no superview, and `layoutSubtreeIfNeeded()` never called.
        let queried = preview.preferredContentSize(forWidth: 320)

        let expected = MarkdownPreviewLayout.layout(
            document: preview.document!,
            style: preview.style,
            width: 320
        ).contentSize
        XCTAssertEqual(queried, expected)
    }

    @MainActor
    func testPreferredContentSizeGrowsWithDocumentContent() {
        let preview = MarkdownPreviewView(frame: .zero)
        preview.document = MarkdownPreviewDocument.parse("Short.")
        let shortSize = preview.preferredContentSize(forWidth: 320)

        preview.document = MarkdownPreviewDocument.parse(
            "# Heading\n\nA paragraph.\n\n- One\n- Two\n- Three\n\nAnother paragraph."
        )
        let longSize = preview.preferredContentSize(forWidth: 320)

        XCTAssertGreaterThan(longSize.height, shortSize.height)
    }

    @MainActor
    func testPreferredContentSizeClampsNonPositiveWidth() {
        let preview = MarkdownPreviewView(frame: .zero)
        preview.document = MarkdownPreviewDocument.parse("Hello")
        let size = preview.preferredContentSize(forWidth: 0)
        XCTAssertGreaterThan(size.width, 0)
    }

    /// With Metal active the on-screen content view is hidden, and exporting through it produced a
    /// blank white page.
    @MainActor
    func testPDFExportPaintsBackgroundAndTextWhileContentViewIsHidden() throws {
        let preview = MarkdownPreviewView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        var style = preview.style
        style.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.1, alpha: 1)
        preview.style = style
        preview.document = MarkdownPreviewDocument.parse("# Title\n\nSome body text.")
        preview.layoutSubtreeIfNeeded()
        preview.debugContentView.isHidden = true

        let data = try XCTUnwrap(preview.renderedDocumentPDFData())
        let rep = try XCTUnwrap(NSPDFImageRep(data: data))
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let corner = try XCTUnwrap(bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(corner.brightnessComponent, 0.3, "the page background should be the preview's, not white")

        var hasTextPixel = false
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), abs(c.brightnessComponent - corner.brightnessComponent) > 0.15 {
                    hasTextPixel = true
                }
            }
        }
        XCTAssertTrue(hasTextPixel, "the text should be drawn")
    }
}
