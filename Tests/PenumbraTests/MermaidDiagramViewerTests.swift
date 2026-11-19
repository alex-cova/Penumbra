import AppKit
import XCTest
@testable import Penumbra
import PenumbraLuna

/// Clicking a diagram in the Markdown preview opens it in `MermaidDiagramViewer`, a zoomable
/// window, because the preview fits a diagram to its column and a large one becomes unreadable.
final class MermaidDiagramViewerTests: XCTestCase {
    private static let source = "flowchart LR\n  a[Alpha] --> b[Beta]"

    @MainActor
    private func makePreview(withRaster: Bool) -> MarkdownPreviewView {
        let preview = MarkdownPreviewView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        preview.document = MarkdownPreviewDocument.parse(
            "# Title\n\n```mermaid\n\(Self.source)\n```\n\nAfter.\n"
        )
        if withRaster, let index = preview.document?.blocks.firstIndex(where: {
            if case .mermaid = $0.kind { return true } else { return false }
        }) {
            let context = CGContext(
                data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            preview.rasterImages = [index: context.makeImage()!]
            preview.rasterNaturalSizes = [index: CGSize(width: 200, height: 100)]
        }
        preview.layoutSubtreeIfNeeded()
        return preview
    }

    /// Document points down the middle of the preview that hit a diagram.
    @MainActor
    private func diagramHits(in preview: MarkdownPreviewView) -> [CGFloat] {
        let height = preview.preferredContentSize(forWidth: 600).height
        return stride(from: CGFloat(0), to: height, by: 4).filter {
            preview.diagramSource(at: CGPoint(x: 300, y: $0)) != nil
        }
    }

    @MainActor
    func testRenderedDiagramIsAClickTargetAndTextIsNot() throws {
        let preview = makePreview(withRaster: true)
        let hits = diagramHits(in: preview)
        XCTAssertFalse(hits.isEmpty)
        let first = try XCTUnwrap(hits.first)
        XCTAssertEqual(preview.diagramSource(at: CGPoint(x: 300, y: first)), Self.source)
        XCTAssertNil(preview.diagramSource(at: CGPoint(x: 300, y: 4)), "the heading")
    }

    @MainActor
    func testDiagramStillRenderingIsNotAClickTarget() {
        XCTAssertTrue(diagramHits(in: makePreview(withRaster: false)).isEmpty)
    }

    /// A real click (mouse down + up through the window) on the diagram reaches the handler, both
    /// with the Core Graphics content view and with the Metal canvas in front of it.
    @MainActor
    func testClickOnDiagramInAWindowOpensIt() throws {
        for metal in [false, true] {
            let preview = makePreview(withRaster: true)
            preview.usesMetalRendering = metal
            let window = NSWindow(
                contentRect: preview.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = preview
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            preview.layoutSubtreeIfNeeded()

            var opened: [String] = []
            preview.diagramOpenHandler = { opened.append($0) }
            let y = try XCTUnwrap(diagramHits(in: preview).dropFirst(3).first)
            let documentView = try XCTUnwrap(preview.debugDocumentView)
            let inWindow = documentView.convert(CGPoint(x: 300, y: y), to: nil)
            let headingInWindow = documentView.convert(CGPoint(x: 300, y: 4), to: nil)

            // The test process is never the active app, so its window is not key and
            // `sendEvent` would spend the click on activating it. Deliver the events to the view
            // the window's hit test picks, as `sendEvent` does for a key window.
            let root = try XCTUnwrap(window.contentView)
            for point in [headingInWindow, inWindow] {
                let target = try XCTUnwrap(root.hitTest(root.convert(point, from: nil)))
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                    ))
                    if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
                }
            }
            XCTAssertEqual(opened, [Self.source], "metal: \(metal)")
        }
    }

    /// `addToolTip` does not retain its owner: a temporary string owner crashed Umbra when the
    /// tooltip timer fired over a diagram. The document view owns its tooltips itself.
    @MainActor
    func testDiagramToolTipIsOwnedByTheDocumentView() throws {
        let preview = makePreview(withRaster: true)
        let documentView = try XCTUnwrap(preview.debugDocumentView)
        let owner = try XCTUnwrap(documentView as? NSViewToolTipOwner)
        let text = owner.view(documentView, stringForToolTip: 0, point: .zero, userData: nil)
        XCTAssertTrue(text.contains("full size"))
    }

    @MainActor
    func testOpenDiagramGoesToTheHostHandler() {
        let preview = makePreview(withRaster: true)
        var opened: [String] = []
        preview.diagramOpenHandler = { opened.append($0) }
        preview.openDiagram(source: Self.source)
        XCTAssertEqual(opened, [Self.source])
    }

    /// A diagram far wider than the window starts zoomed out to fit, never above 100%, and the
    /// zoom commands move from there.
    @MainActor
    func testViewerFitsAWideDiagramAndZooms() async throws {
        let chain = (0..<30).map { "  n\($0)[Service \($0)] --> n\($0 + 1)[Service \($0 + 1)]" }
        let source = "flowchart LR\n" + chain.joined(separator: "\n") + "\n"
        let context = MarkdownPreviewStyle().mermaidRenderingContext
        let prepared = await MermaidDiagramViewer.prepare(source: source, context: context)
        let diagram = try XCTUnwrap(prepared).value
        XCTAssertGreaterThan(diagram.bounds.width, 3000)

        let viewer = MermaidDiagramViewer(source: Self.source, diagram: diagram, background: context.backgroundRGBA, title: "Test")
        defer { viewer.close() }
        let window = try XCTUnwrap(viewer.window)
        window.setContentSize(CGSize(width: 800, height: 500))
        window.contentView?.layoutSubtreeIfNeeded()

        viewer.zoomToFit(nil)
        let fit = viewer.magnification
        XCTAssertLessThan(fit, 0.3)
        XCTAssertEqual(fit, 800 / diagram.bounds.width, accuracy: 0.02)

        viewer.zoomIn(nil)
        XCTAssertEqual(viewer.magnification, fit * 1.25, accuracy: 0.001)
        viewer.zoomToActualSize(nil)
        XCTAssertEqual(viewer.magnification, 1, accuracy: 0.001)
        for _ in 0..<30 { viewer.zoomIn(nil) }
        XCTAssertEqual(viewer.magnification, MermaidDiagramViewer.maxMagnification, accuracy: 0.001)
    }

    @MainActor
    func testViewerNeverEnlargesASmallDiagramToFit() async throws {
        let context = MarkdownPreviewStyle().mermaidRenderingContext
        let prepared = await MermaidDiagramViewer.prepare(source: Self.source, context: context)
        let diagram = try XCTUnwrap(prepared).value
        let viewer = MermaidDiagramViewer(source: Self.source, diagram: diagram, background: context.backgroundRGBA, title: "Test")
        defer { viewer.close() }
        viewer.window?.setContentSize(CGSize(width: 1200, height: 900))
        viewer.window?.contentView?.layoutSubtreeIfNeeded()
        viewer.zoomToFit(nil)
        XCTAssertEqual(viewer.magnification, 1, accuracy: 0.001)
    }

    // MARK: - Export

    /// RGBA bytes of `image`, redrawn into its own color space so the values are not converted
    /// (reading through `NSBitmapImageRep.colorAt` converted them and skewed the comparison).
    private func rgba(_ image: CGImage) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let space = try XCTUnwrap(image.colorSpace)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (bytes, image.width, image.height)
    }

    @MainActor
    private func preparedDiagram() async throws -> (PreparedDiagram, CGColor, MarkdownPreviewStyle.MermaidRenderingContext) {
        var style = MarkdownPreviewStyle()
        style.backgroundColor = NSColor(deviceRed: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        style.bodyColor = NSColor(deviceWhite: 0.92, alpha: 1)
        let context = style.mermaidRenderingContext
        let prepared = await MermaidDiagramViewer.prepare(source: Self.source, context: context)
        let bg = context.backgroundRGBA
        let color = CGColor(srgbRed: bg.red, green: bg.green, blue: bg.blue, alpha: 1)
        return (try XCTUnwrap(prepared).value, color, context)
    }

    @MainActor
    func testExportsPNGAndJPEGAtTheChosenScaleOnTheThemeBackground() async throws {
        let (diagram, background, _) = try await preparedDiagram()
        for format in MermaidDiagramExport.Format.allCases {
            let data = try XCTUnwrap(MermaidDiagramExport.imageData(
                diagram: diagram, background: background, scale: 2, format: format
            ), "\(format)")
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, format.contentType.identifier)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, Int((diagram.bounds.width * 2).rounded(.up)), "\(format)")
            XCTAssertEqual(image.height, Int((diagram.bounds.height * 2).rounded(.up)), "\(format)")
            XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB, "\(format)")
            // The corner is page: the theme background, 0.1 / 0.1 / 0.12 → 26, 26, 31.
            let pixels = try rgba(image)
            let corner = Array(pixels.bytes[0..<3]).map(Int.init)
            XCTAssertEqual(corner[0], 26, accuracy: 2, "\(format)")
            XCTAssertEqual(corner[1], 26, accuracy: 2, "\(format)")
            XCTAssertEqual(corner[2], 31, accuracy: 2, "\(format)")
            _ = background
        }
    }

    /// The export's labels come out as the preview's raster draws them. The raster is drawn off
    /// the main thread with no AppKit context current, where Luna makes its own unflipped one;
    /// on the main thread a flipped context can be current, which turned the viewer's labels
    /// upside down. The reference repeats the export's geometry on a detached task.
    @MainActor
    func testExportDrawsLabelsLikeThePreviewRaster() async throws {
        let (diagram, background, _) = try await preparedDiagram()
        let exported = try XCTUnwrap(MermaidDiagramExport.image(diagram: diagram, background: background, scale: 2))
        let box = MermaidDiagramViewer.PreparedBox(value: diagram)
        let width = exported.width
        let height = exported.height
        let reference = await Task.detached { () -> CGImage? in
            let bounds = box.value.bounds
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return nil }
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: 2, y: 2)
            context.translateBy(x: 0, y: CGFloat(height) / 2)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            box.value.render(context, bounds)
            return context.makeImage()
        }.value
        let a = try rgba(exported)
        let b = try rgba(try XCTUnwrap(reference))
        XCTAssertEqual(a.bytes.count, b.bytes.count)
        var differing = 0
        for i in stride(from: 0, to: min(a.bytes.count, b.bytes.count), by: 4) {
            let diff = (0..<3).reduce(0) { $0 + abs(Int(a.bytes[i + $1]) - Int(b.bytes[i + $1])) }
            if diff > 12 { differing += 1 }
        }
        XCTAssertLessThan(Double(differing) / Double(a.bytes.count / 4), 0.002)
    }

    /// Exports are always light (white page, dark labels), however dark the viewer is.
    @MainActor
    func testViewerExportIsAlwaysLight() async throws {
        let data = await MermaidDiagramExport.lightImageData(source: Self.source, scale: 1, format: .png)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(data) as CFData, nil))
        let pixels = try rgba(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        XCTAssertEqual(Array(pixels.bytes[0..<3]), [255, 255, 255], "white page")
        var darkest = 255
        for i in stride(from: 0, to: pixels.bytes.count, by: 4) {
            darkest = min(darkest, Int(pixels.bytes[i]) + Int(pixels.bytes[i + 1]) + Int(pixels.bytes[i + 2]))
        }
        XCTAssertLessThan(darkest / 3, 80, "dark label text")
    }

    func testExportScaleIsCappedForHugeDiagrams() {
        XCTAssertEqual(MermaidDiagramExport.effectiveScale(for: CGSize(width: 3000, height: 2900), requested: 3), 3)
        let capped = MermaidDiagramExport.effectiveScale(for: CGSize(width: 7300, height: 700), requested: 3)
        XCTAssertEqual(7300 * capped, MermaidDiagramExport.maxPixelDimension, accuracy: 0.5)
    }

    /// The canvas draws the diagram itself (vectors), so it paints at any size.
    @MainActor
    func testCanvasPaintsTheDiagram() async throws {
        let context = MarkdownPreviewStyle().mermaidRenderingContext
        let prepared = await MermaidDiagramViewer.prepare(source: Self.source, context: context)
        let diagram = try XCTUnwrap(prepared).value
        let canvas = MermaidDiagramCanvasView(diagram: diagram)
        XCTAssertEqual(canvas.frame.size, diagram.bounds.size)
        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        var painted = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.1 { painted += 1 }
            }
        }
        XCTAssertGreaterThan(painted, 50)
    }
}
