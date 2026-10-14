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
    /// blank white page. The export paints from the layout, so it must still draw.
    @MainActor
    func testPDFExportPaintsBackgroundAndTextWhileContentViewIsHidden() throws {
        let preview = MarkdownPreviewView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        var style = preview.style
        style.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.1, alpha: 1)
        preview.style = style
        let document = MarkdownPreviewDocument.parse("# Title\n\nSome body text.")
        preview.document = document
        preview.layoutSubtreeIfNeeded()
        preview.debugContentView.isHidden = true

        let data = try XCTUnwrap(preview.renderedPDFData(
            document: document, style: style.lightForExport(), raster: MarkdownPreviewRasterResult()
        ))
        let bitmap = try pdfBitmap(data)
        let corner = try XCTUnwrap(bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(corner.brightnessComponent, 0.9, "the exported page is white, not the dark preview's")
        XCTAssertTrue(hasPixel(in: bitmap, where: { $0.brightnessComponent < 0.5 }), "dark text should be drawn")
    }

    /// Dynamic colors resolve under the export's own appearance, not the dark preview's.
    @MainActor
    func testPDFExportIsLightInADarkAppearance() throws {
        let preview = MarkdownPreviewView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        preview.appearance = NSAppearance(named: .darkAqua)
        let document = MarkdownPreviewDocument.parse("# Title\n\nSome body text.")
        preview.document = document
        preview.layoutSubtreeIfNeeded()

        // Not `lightForExport()`: the default style's semantic colors are what must resolve light.
        let data = try XCTUnwrap(preview.renderedPDFData(
            document: document, style: MarkdownPreviewStyle(), raster: MarkdownPreviewRasterResult()
        ))
        let bitmap = try pdfBitmap(data)
        let corner = try XCTUnwrap(bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(corner.brightnessComponent, 0.9)
        XCTAssertTrue(hasPixel(in: bitmap, where: { $0.brightnessComponent < 0.5 }), "text should be dark on the light page")
    }

    func testLightExportStyleKeepsTypographyAndSpacing() {
        let dark = MarkdownPreviewStyle(
            bodyColor: .white,
            backgroundColor: .black,
            contentInset: 31,
            blockSpacing: 9
        )
        let light = dark.lightForExport()
        XCTAssertEqual(light.backgroundColor, .white)
        XCTAssertEqual(light.bodyFont, dark.bodyFont)
        XCTAssertEqual(light.contentInset, 31)
        XCTAssertEqual(light.blockSpacing, 9)
        XCTAssertLessThan(light.bodyColor.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 1, 0.3)
    }

    private func pdfBitmap(_ data: Data) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSPDFImageRep(data: data))
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
    }

    private func hasPixel(in bitmap: NSBitmapImageRep, where predicate: (NSColor) -> Bool) -> Bool {
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), predicate(color) {
                    return true
                }
            }
        }
        return false
    }
}
