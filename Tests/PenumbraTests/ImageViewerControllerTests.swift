import AppKit
import Penumbra
import XCTest

/// Guards the image-viewer overlay fixes: the viewer must opaquely cover the editor, and the
/// covered editor must be unselectable (no keyboard focus, caret, or selection) while an image
/// shows.
@MainActor
final class ImageViewerControllerTests: XCTestCase {
    private func makeController() -> ImageViewerController {
        ImageViewerController()
    }

    private func scrollView(in controller: ImageViewerController) -> NSScrollView? {
        controller.containerView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView
    }

    private func tempPNGURL() throws -> URL {
        let image = NSImage(size: NSSize(width: 64, height: 48))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ImageViewerControllerTests", code: 1)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-image-viewer-test-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }

    // MARK: - Opaque backdrop

    func testViewerBackgroundIsOpaqueByDefault() {
        let controller = makeController()
        controller.embed(contentView: NSView())
        guard let scrollView = scrollView(in: controller) else {
            return XCTFail("expected a scroll view in the viewer container")
        }
        XCTAssertTrue(scrollView.drawsBackground, "the image scroll view must paint an opaque backdrop")
        XCTAssertEqual(scrollView.backgroundColor, controller.viewerBackgroundColor)
    }

    func testViewerBackgroundColorAppliesToScrollAndContainerViews() {
        let controller = makeController()
        controller.embed(contentView: NSView())
        controller.viewerBackgroundColor = .red
        guard let scrollView = scrollView(in: controller) else {
            return XCTFail("expected a scroll view in the viewer container")
        }
        XCTAssertEqual(scrollView.backgroundColor, .red)
        XCTAssertEqual(controller.containerView.layer?.backgroundColor, NSColor.red.cgColor)
    }

    // MARK: - Show / hide

    func testShowAndHideImage() throws {
        let controller = makeController()
        let url = try tempPNGURL()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(controller.isShowing)
        controller.show(url: url)
        XCTAssertTrue(controller.isShowing)
        XCTAssertTrue(controller.isShowing(url: url))
        XCTAssertNotNil(controller.currentImage)
        controller.hide()
        XCTAssertFalse(controller.isShowing)
        XCTAssertNil(controller.currentImage)
    }

    func testShowUnreadableURLShowsErrorState() {
        let controller = makeController()
        let url = URL(fileURLWithPath: "/nonexistent/umbra-image-\(UUID().uuidString).png")
        controller.show(url: url)
        XCTAssertTrue(controller.isShowing)
        XCTAssertTrue(controller.isShowing(url: url))
        XCTAssertNil(controller.currentImage)
        controller.hide()
    }

    // MARK: - Covered editor is locked

    func testShowDisablesCoveredEditorAndHideRestoresIt() throws {
        let controller = makeController()
        let editor = TextView()
        editor.isSelectable = true
        editor.participatesInKeyViewLoop = true
        controller.coveredEditor = editor

        let url = try tempPNGURL()
        defer { try? FileManager.default.removeItem(at: url) }
        controller.show(url: url)
        XCTAssertFalse(editor.isSelectable, "the editor behind the image must not be selectable")
        XCTAssertFalse(editor.participatesInKeyViewLoop, "the hidden editor must leave the key-view loop")

        controller.hide()
        XCTAssertTrue(editor.isSelectable)
        XCTAssertTrue(editor.participatesInKeyViewLoop)
    }

    func testHideRestoresPreviousSelectability() {
        let controller = makeController()
        let editor = TextView()
        editor.isSelectable = false
        editor.participatesInKeyViewLoop = false
        controller.coveredEditor = editor

        controller.show(url: URL(fileURLWithPath: "/nonexistent/x.png"))
        controller.hide()
        XCTAssertFalse(editor.isSelectable, "a previously unselectable editor stays unselectable")
        XCTAssertFalse(editor.participatesInKeyViewLoop)
    }

    // MARK: - Zoom

    func testZoomInAndOutClampToRange() throws {
        let controller = makeController()
        let url = try tempPNGURL()
        defer { try? FileManager.default.removeItem(at: url) }
        controller.show(url: url)

        for _ in 0..<200 { controller.zoomOut() }
        XCTAssertGreaterThanOrEqual(controller.zoomPercent, 5, "zoom must not go below the 0.05 floor")
        for _ in 0..<400 { controller.zoomIn() }
        XCTAssertLessThanOrEqual(controller.zoomPercent, 1600, "zoom must not exceed the 16x ceiling")
    }

    func testZoomToActualSizeIs100Percent() throws {
        let controller = makeController()
        let url = try tempPNGURL()
        defer { try? FileManager.default.removeItem(at: url) }
        controller.show(url: url)
        controller.zoomOut()
        controller.zoomOut()
        controller.zoomToActualSize()
        XCTAssertEqual(controller.zoomPercent, 100)
    }

    func testZoomNotifiesStateChange() throws {
        let controller = makeController()
        let url = try tempPNGURL()
        defer { try? FileManager.default.removeItem(at: url) }
        controller.show(url: url)
        var notifications = 0
        controller.onStateChange = { notifications += 1 }
        controller.zoomIn()
        controller.zoomOut()
        controller.recenter()
        XCTAssertEqual(notifications, 3)
    }

    func testImagePixelSizeMatchesFile() throws {
        let controller = makeController()
        let url = try tempPNGURL()
        defer { try? FileManager.default.removeItem(at: url) }
        controller.show(url: url)
        XCTAssertEqual(controller.imagePixelSize, CGSize(width: 64, height: 48))
    }
}
