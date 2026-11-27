import CoreGraphics
import Foundation
import XCTest
@testable import Umbra

/// Pure-logic tests for the ported photo editor: viewport geometry, orientation math, history,
/// render coalescing, and the JSON look/session stores. Rendering itself (Core Image) is covered
/// by inspection in the app; these pin the arithmetic the canvas and overlays derive from.
@MainActor
final class PhotoEngineMathTests: XCTestCase {
    // MARK: - Viewport

    func testFitZoomUsesSmallerAxis() {
        let fit = PhotoViewport.fitZoom(
            imagePixelSize: CGSize(width: 4000, height: 3000),
            in: CGSize(width: 800, height: 600)
        )
        XCTAssertEqual(fit, 0.2, accuracy: 0.0001)
    }

    func testFillZoomUsesLargerAxis() {
        let fill = PhotoViewport.fillZoom(
            imagePixelSize: CGSize(width: 4000, height: 3000),
            in: CGSize(width: 800, height: 600)
        )
        XCTAssertEqual(fill, 0.2, accuracy: 0.0001)
        let fillTall = PhotoViewport.fillZoom(
            imagePixelSize: CGSize(width: 1000, height: 2000),
            in: CGSize(width: 800, height: 600)
        )
        XCTAssertEqual(fillTall, 0.8, accuracy: 0.0001)
    }

    func testViewportPercentAndClamp() {
        XCTAssertEqual(PhotoViewport(zoom: 1).percent, 100)
        XCTAssertEqual(PhotoViewport(zoom: 0.001).zoom, PhotoViewport.minZoom)
        XCTAssertEqual(PhotoViewport(zoom: 100).zoom, PhotoViewport.maxZoom)
        XCTAssertEqual(PhotoViewport(zoom: 1).actualSize().zoom, 1)
    }

    func testImageRectCentersWithOffset() {
        let viewport = PhotoViewport(zoom: 0.5, offset: .zero)
        let rect = viewport.imageRect(
            imagePixelSize: CGSize(width: 400, height: 200),
            in: CGSize(width: 800, height: 600)
        )
        XCTAssertEqual(rect, CGRect(x: 300, y: 250, width: 200, height: 100))
    }

    func testZoomedTowardPointPinsPixel() {
        let base = PhotoViewport(zoom: 1)
        let pixels = CGSize(width: 400, height: 400)
        let canvas = CGSize(width: 800, height: 800)
        let point = CGPoint(x: 500, y: 500)
        let next = base.zoomed(to: 2, toward: point, imagePixelSize: pixels, in: canvas)
        let before = base.imagePoint(forView: point, imagePixelSize: pixels, in: canvas)
        let after = next.imagePoint(forView: point, imagePixelSize: pixels, in: canvas)
        XCTAssertEqual(before.x, after.x, accuracy: 0.001)
        XCTAssertEqual(before.y, after.y, accuracy: 0.001)
    }

    // MARK: - Orientation

    func testQuarterTurnSwapsOutputSize() {
        let (_, size) = TransformEngine.orientationTransform(
            flipH: false, flipV: false, quarterTurns: 1, straightenDegrees: 0,
            size: CGSize(width: 400, height: 300)
        )
        XCTAssertEqual(size.width, 300, accuracy: 0.001)
        XCTAssertEqual(size.height, 400, accuracy: 0.001)
    }

    func testIdentityOrientationKeepsSize() {
        let (_, size) = TransformEngine.orientationTransform(
            flipH: false, flipV: false, quarterTurns: 0, straightenDegrees: 0,
            size: CGSize(width: 400, height: 300)
        )
        XCTAssertEqual(size.width, 400, accuracy: 0.001)
        XCTAssertEqual(size.height, 300, accuracy: 0.001)
    }

    func testPixelRectRoundTrip() {
        let size = CGSize(width: 1000, height: 500)
        let normalized = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        let pixels = TransformEngine.pixelRect(for: normalized, in: size)
        XCTAssertEqual(pixels, CGRect(x: 100, y: 100, width: 500, height: 200))
        let back = TransformEngine.normalizedRect(for: pixels, in: size)
        XCTAssertEqual(back.origin.x, normalized.origin.x, accuracy: 0.001)
        XCTAssertEqual(back.size.width, normalized.size.width, accuracy: 0.001)
    }

    func testMatchingAspect() {
        XCTAssertEqual(TransformEngine.matchingAspect(for: CGRect(x: 0, y: 0, width: 1, height: 1)), .square)
        XCTAssertEqual(
            TransformEngine.matchingAspect(for: CGRect(x: 0, y: 0, width: 16, height: 9)),
            .sixteenNine
        )
        XCTAssertEqual(TransformEngine.matchingAspect(for: nil), .original)
    }

    // MARK: - Curves and color

    func testToneCurveClamp() {
        XCTAssertEqual(ToneCurve.clamped([0, 2, -1]), ToneCurve.identityYs)
        XCTAssertEqual(ToneCurve.clamped([0, 0.5, 0.5, 0.5, 1]), [0, 0.5, 0.5, 0.5, 1])
        XCTAssertTrue(ToneCurve().isIdentity)
    }

    func testColorCubeInterpolation() {
        XCTAssertEqual(PhotoColorCube.interpolate(xs: [0, 1], ys: [0, 10], x: 0.25), 2.5, accuracy: 0.0001)
        XCTAssertEqual(PhotoColorCube.hueDistance(10, 350), 20, accuracy: 0.0001)
        let (h, _, _) = PhotoColorCube.rgbToHSL(1, 0, 0)
        XCTAssertEqual(h, 0, accuracy: 0.001)
    }

    func testHSLBandWeightFallsOff() {
        XCTAssertEqual(SelectiveHSLEngine.bandWeight(hue: 0, band: .reds), 1, accuracy: 0.0001)
        XCTAssertEqual(SelectiveHSLEngine.bandWeight(hue: 30, band: .reds), 0, accuracy: 0.0001)
        XCTAssertTrue(SelectiveHSL().isIdentity)
    }

    // MARK: - History and coalescing

    func testEditHistoryUndoRedo() {
        var history = EditHistory(.identity)
        XCTAssertFalse(history.canUndo)
        var next = EditAdjustment.identity
        next.exposure = 10
        history.commit(next)
        XCTAssertTrue(history.canUndo)
        XCTAssertEqual(history.present.exposure, 10)
        history.undo()
        XCTAssertEqual(history.present.exposure, 0)
        XCTAssertTrue(history.canRedo)
        history.redo()
        XCTAssertEqual(history.present.exposure, 10)
    }

    func testRenderCoalescerKeepsNewestAndStrongest() {
        var coalescer = RenderCoalescer()
        XCTAssertFalse(coalescer.hasPending)
        var first = EditAdjustment.identity
        first.exposure = 5
        coalescer.enqueue(RenderRequest(adjustments: first, quality: .interactive))
        var second = EditAdjustment.identity
        second.exposure = 9
        coalescer.enqueue(RenderRequest(adjustments: second, quality: .final))
        let taken = coalescer.takeNext()
        XCTAssertEqual(taken?.adjustments.exposure, 9)
        XCTAssertEqual(taken?.quality, .final)
        XCTAssertFalse(coalescer.hasPending)
    }

    // MARK: - EXIF summary

    func testExifSummaryLine() {
        let metadata: [String: Any] = [
            "{Exif}": [
                "ISOSpeedRatings": [400],
                "FNumber": 2.8,
                "ExposureTime": 0.004,
                "FocalLength": 35.0,
            ],
        ]
        let summary = PhotoExifSummary(metadata: metadata)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(summary.line.contains("ISO 400"))
        XCTAssertTrue(summary.line.contains("f/2.8"))
        XCTAssertTrue(summary.line.contains("35mm"))
        XCTAssertTrue(PhotoExifSummary(metadata: nil).isEmpty)
    }

    // MARK: - Save format mapping

    func testPhotoSaveFormats() {
        XCTAssertEqual(
            IDEWorkspace.photoSaveFormat(for: URL(fileURLWithPath: "a.jpg")),
            .jpeg
        )
        XCTAssertEqual(
            IDEWorkspace.photoSaveFormat(for: URL(fileURLWithPath: "a.PNG")),
            .png
        )
        XCTAssertEqual(
            IDEWorkspace.photoSaveFormat(for: URL(fileURLWithPath: "a.heic")),
            .heic
        )
        XCTAssertEqual(
            IDEWorkspace.photoSaveFormat(for: URL(fileURLWithPath: "a.tiff")),
            .tiff16
        )
        XCTAssertNil(IDEWorkspace.photoSaveFormat(for: URL(fileURLWithPath: "a.gif")))
        XCTAssertNil(IDEWorkspace.photoSaveFormat(for: URL(fileURLWithPath: "a.cr3")))
    }

    // MARK: - JSON stores (isolated to a temp dir)

    private func tempFile(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-photo-test-\(UUID().uuidString)")
            .appendingPathComponent(name)
    }

    func testLookStoreRoundTrip() {
        let file = tempFile(named: "looks.json")
        XCTAssertTrue(PhotoLookStore.load(fileURL: file).isEmpty)
        var adjustments = EditAdjustment.identity
        adjustments.exposure = 25
        let afterAdd = PhotoLookStore.add(name: "Punchy", adjustments: adjustments, fileURL: file)
        XCTAssertEqual(afterAdd.count, 1)
        XCTAssertEqual(afterAdd.first?.name, "Punchy")
        let loaded = PhotoLookStore.load(fileURL: file)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(PhotoLookStore.adjustments(for: loaded[0])?.exposure, 25)
        // Geometry is stripped from looks.
        var geometric = EditAdjustment.identity
        geometric.rotationQuarterTurns = 1
        geometric.crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        _ = PhotoLookStore.add(name: "Geo", adjustments: geometric, fileURL: file)
        let geoStored = PhotoLookStore.load(fileURL: file).last
        XCTAssertEqual(PhotoLookStore.adjustments(for: geoStored!)?.rotationQuarterTurns, 0)
        XCTAssertNil(PhotoLookStore.adjustments(for: geoStored!)?.crop)
        let renamed = PhotoLookStore.rename(id: loaded[0].id, to: "Soft", fileURL: file)
        XCTAssertEqual(renamed.first?.name, "Soft")
        var removed = PhotoLookStore.remove(id: loaded[0].id, fileURL: file)
        XCTAssertEqual(removed.count, 1)
        removed = PhotoLookStore.remove(id: removed[0].id, fileURL: file)
        XCTAssertTrue(removed.isEmpty)
    }

    func testSessionStoreKeyedByPath() {
        let file = tempFile(named: "sessions.json")
        XCTAssertNil(PhotoEditorSessionStore.load(forPath: "/a/b.jpg", fileURL: file))
        var adjustments = EditAdjustment.identity
        adjustments.contrast = 10
        PhotoEditorSessionStore.save(
            PhotoEditorSessionStore.Snapshot(bookmark: Data([1, 2, 3]), adjustments: adjustments),
            forPath: "/a/b.jpg",
            fileURL: file
        )
        PhotoEditorSessionStore.save(
            PhotoEditorSessionStore.Snapshot(bookmark: Data([4]), adjustments: .identity),
            forPath: "/c/d.png",
            fileURL: file
        )
        XCTAssertEqual(
            PhotoEditorSessionStore.load(forPath: "/a/b.jpg", fileURL: file)?.adjustments.contrast,
            10
        )
        XCTAssertEqual(
            PhotoEditorSessionStore.load(forPath: "/c/d.png", fileURL: file)?.adjustments,
            .identity
        )
        PhotoEditorSessionStore.clear(forPath: "/a/b.jpg", fileURL: file)
        XCTAssertNil(PhotoEditorSessionStore.load(forPath: "/a/b.jpg", fileURL: file))
        XCTAssertNotNil(PhotoEditorSessionStore.load(forPath: "/c/d.png", fileURL: file))
    }

    func testExportFormatFileExtensions() {
        XCTAssertEqual(PhotoExportFormat.jpeg.fileExtension, "jpg")
        XCTAssertEqual(PhotoExportFormat.png.fileExtension, "png")
        XCTAssertTrue(PhotoExportFormat.jpeg.supportsQuality)
        XCTAssertFalse(PhotoExportFormat.png.supportsQuality)
    }
}
