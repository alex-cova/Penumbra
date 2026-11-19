import PenumbraLuna
@preconcurrency import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A window that shows one mermaid diagram at any zoom: pinch, ⌘+ / ⌘− / ⌘0, or the toolbar.
/// The preview fits a diagram to its column, which leaves a large one unreadable; this draws the
/// laid-out diagram as vectors (not the preview's capped raster), so text stays sharp when zoomed.
@MainActor
final class MermaidDiagramViewer: NSWindowController, NSWindowDelegate {
    /// Open viewers, kept alive until their window closes. Keyed by source and colors, so a
    /// second click on the same diagram brings its window forward instead of opening another.
    private static var open: [Key: MermaidDiagramViewer] = [:]

    private struct Key: Hashable {
        var source: String
        var background: [CGFloat]
        var foreground: [CGFloat]
    }

    static let minMagnification: CGFloat = 0.05
    static let maxMagnification: CGFloat = 8

    /// Lays the diagram out off the main actor, then opens (or brings forward) its window.
    /// A diagram that fails to lay out opens nothing: the preview already shows its error.
    static func show(
        source: String,
        context: MarkdownPreviewStyle.MermaidRenderingContext,
        title: String? = nil
    ) {
        let key = Key(
            source: source,
            background: rgba(context.backgroundRGBA),
            foreground: rgba(context.foregroundRGBA)
        )
        if let existing = open[key] {
            existing.showWindow(nil)
            return
        }
        Task { @MainActor in
            guard let prepared = await prepare(source: source, context: context) else { return }
            if let existing = open[key] {
                existing.showWindow(nil)
                return
            }
            let viewer = MermaidDiagramViewer(
                source: source,
                diagram: prepared.value,
                background: context.backgroundRGBA,
                title: title ?? "Diagram"
            )
            open[key] = viewer
            viewer.onClose = { open[key] = nil }
            viewer.showWindow(nil)
            viewer.zoomToFit(nil)
        }
    }

    private static func rgba(_ c: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)) -> [CGFloat] {
        [c.red, c.green, c.blue, c.alpha]
    }

    /// `PreparedDiagram` holds a render closure, so it is not `Sendable`. It is built on a
    /// detached task and only read on the main actor afterwards.
    struct PreparedBox: @unchecked Sendable {
        let value: PreparedDiagram
    }

    nonisolated static func prepare(
        source: String,
        context: MarkdownPreviewStyle.MermaidRenderingContext
    ) async -> PreparedBox? {
        let theme = MermaidPaintAdapter.diagramTheme(from: context)
        guard let prepared = try? await MermaidRenderer.prepareAsync(source: source, theme: theme),
              prepared.bounds.width > 0, prepared.bounds.height > 0 else { return nil }
        return PreparedBox(value: prepared)
    }

    private let scrollView = NSScrollView()
    private let canvas: MermaidDiagramCanvasView
    private let zoomControl = NSSegmentedControl()
    private let exportButton = NSButton()
    private var onClose: (() -> Void)?
    /// What export lays out again in light colors.
    private let source: String

    var magnification: CGFloat { scrollView.magnification }

    init(
        source: String,
        diagram: PreparedDiagram,
        background: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat),
        title: String
    ) {
        canvas = MermaidDiagramCanvasView(diagram: diagram)
        self.source = source
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let size = CGSize(
            width: min(max(diagram.bounds.width + 40, 480), screen.width * 0.85),
            height: min(max(diagram.bounds.height + 40, 320), screen.height * 0.85)
        )
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 320, height: 240)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        // The same device-RGB components the preview's background was read as.
        let backgroundColor = NSColor(
            deviceRed: background.red, green: background.green, blue: background.blue, alpha: 1
        )
        window.backgroundColor = backgroundColor
        scrollView.backgroundColor = backgroundColor
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.allowsMagnification = true
        scrollView.minMagnification = Self.minMagnification
        scrollView.maxMagnification = Self.maxMagnification
        scrollView.contentView = MermaidDiagramClipView()
        scrollView.documentView = canvas
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let content = MermaidDiagramContentView(viewer: self)
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window.contentView = content
        installZoomControl(in: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func installZoomControl(in window: NSWindow) {
        zoomControl.segmentCount = 4
        zoomControl.trackingMode = .momentary
        let segments: [(String, String, String)] = [
            ("minus.magnifyingglass", "Zoom Out (⌘−)", "Zoom Out"),
            ("arrow.up.left.and.down.right.magnifyingglass", "Zoom to Fit (⌘0)", "Fit"),
            ("1.magnifyingglass", "Actual Size (⌘1)", "100%"),
            ("plus.magnifyingglass", "Zoom In (⌘+)", "Zoom In")
        ]
        for (index, segment) in segments.enumerated() {
            if let image = NSImage(systemSymbolName: segment.0, accessibilityDescription: segment.2) {
                zoomControl.setImage(image, forSegment: index)
            } else {
                zoomControl.setLabel(segment.2, forSegment: index)
            }
            zoomControl.setToolTip(segment.1, forSegment: index)
        }
        zoomControl.target = self
        zoomControl.action = #selector(zoomControlClicked(_:))
        zoomControl.sizeToFit()

        exportButton.bezelStyle = .texturedRounded
        exportButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
        exportButton.imagePosition = .imageLeading
        exportButton.title = "Export…"
        exportButton.toolTip = "Export as PNG or JPEG (⇧⌘S)"
        exportButton.target = self
        exportButton.action = #selector(exportImage(_:))
        exportButton.sizeToFit()

        let accessory = NSTitlebarAccessoryViewController()
        let gap: CGFloat = 8
        let holder = NSView(frame: CGRect(
            x: 0, y: 0, width: exportButton.frame.width + gap + zoomControl.frame.width + 12, height: 28
        ))
        exportButton.frame.origin = CGPoint(x: 0, y: (28 - exportButton.frame.height) / 2)
        zoomControl.frame.origin = CGPoint(
            x: exportButton.frame.maxX + gap, y: (28 - zoomControl.frame.height) / 2
        )
        holder.addSubview(exportButton)
        holder.addSubview(zoomControl)
        accessory.view = holder
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
    }

    @objc private func zoomControlClicked(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: zoomOut(nil)
        case 1: zoomToFit(nil)
        case 2: zoomToActualSize(nil)
        default: zoomIn(nil)
        }
    }

    // MARK: - Zoom

    /// Fits the whole diagram in the window, never enlarging past 100%.
    @objc func zoomToFit(_ sender: Any?) {
        let available = scrollView.contentView.bounds.size
        let visible = CGSize(
            width: available.width * scrollView.magnification,
            height: available.height * scrollView.magnification
        )
        let diagram = canvas.frame.size
        guard diagram.width > 0, diagram.height > 0, visible.width > 0, visible.height > 0 else { return }
        let fit = min(visible.width / diagram.width, visible.height / diagram.height, 1)
        setMagnification(fit, centeredAt: CGPoint(x: diagram.width / 2, y: diagram.height / 2))
    }

    @objc func zoomToActualSize(_ sender: Any?) {
        setMagnification(1, centeredAt: visibleCenter)
    }

    @objc func zoomIn(_ sender: Any?) {
        setMagnification(scrollView.magnification * 1.25, centeredAt: visibleCenter)
    }

    @objc func zoomOut(_ sender: Any?) {
        setMagnification(scrollView.magnification / 1.25, centeredAt: visibleCenter)
    }

    private var visibleCenter: CGPoint {
        let visible = scrollView.documentVisibleRect
        return CGPoint(x: visible.midX, y: visible.midY)
    }

    private func setMagnification(_ value: CGFloat, centeredAt point: CGPoint) {
        let clamped = min(max(value, Self.minMagnification), Self.maxMagnification)
        scrollView.setMagnification(clamped, centeredAt: point)
    }

    // MARK: - Export

    /// Asks where to save, in PNG or JPEG at 1×, 2× or 3×, and writes the whole diagram.
    @objc func exportImage(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.title = "Export Diagram"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let format = NSPopUpButton()
        format.addItems(withTitles: MermaidDiagramExport.Format.allCases.map(\.title))
        let scale = NSPopUpButton()
        scale.addItems(withTitles: MermaidDiagramExport.scales.map { "\(Int($0))×" })
        scale.selectItem(at: MermaidDiagramExport.scales.firstIndex(of: 2) ?? 0)
        let accessory = NSGridView(views: [
            [NSTextField(labelWithString: "Format:"), format],
            [NSTextField(labelWithString: "Scale:"), scale]
        ])
        accessory.rowSpacing = 8
        accessory.column(at: 0).xPlacement = .trailing
        let padded = NSView()
        accessory.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(accessory)
        NSLayoutConstraint.activate([
            accessory.topAnchor.constraint(equalTo: padded.topAnchor, constant: 12),
            accessory.bottomAnchor.constraint(equalTo: padded.bottomAnchor, constant: -12),
            accessory.centerXAnchor.constraint(equalTo: padded.centerXAnchor),
            accessory.leadingAnchor.constraint(greaterThanOrEqualTo: padded.leadingAnchor, constant: 20)
        ])
        panel.accessoryView = padded

        let applyFormat = ExportFormatObserver(panel: panel, popUp: format)
        applyFormat.apply()
        format.target = applyFormat
        format.action = #selector(ExportFormatObserver.formatChanged(_:))

        panel.beginSheetModal(for: window) { [weak self] response in
            withExtendedLifetime(applyFormat) {}
            guard response == .OK, let self, let url = panel.url else { return }
            let chosen = MermaidDiagramExport.Format.allCases[max(format.indexOfSelectedItem, 0)]
            let factor = MermaidDiagramExport.scales[max(scale.indexOfSelectedItem, 0)]
            Task { @MainActor in await self.write(to: url, format: chosen, scale: factor) }
        }
    }

    /// Writes the diagram in light colors, whatever the viewer shows, like the PDF export.
    private func write(to url: URL, format: MermaidDiagramExport.Format, scale: CGFloat) async {
        guard let data = await MermaidDiagramExport.lightImageData(source: source, scale: scale, format: format) else {
            presentExportError(NSError(
                domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                userInfo: [NSLocalizedDescriptionKey: "The diagram could not be drawn as an image."]
            ))
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            presentExportError(error)
        }
    }

    private func presentExportError(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }
}

/// Handles the zoom key equivalents while the viewer's window is key.
@MainActor
private final class MermaidDiagramContentView: NSView {
    private weak var viewer: MermaidDiagramViewer?

    init(viewer: MermaidDiagramViewer) {
        self.viewer = viewer
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let viewer,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                || event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift]
        else { return super.performKeyEquivalent(with: event) }
        let shifted = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s" where shifted: viewer.exportImage(nil)
        case "=", "+": viewer.zoomIn(nil)
        case "-", "_": viewer.zoomOut(nil)
        case "0": viewer.zoomToFit(nil)
        case "1": viewer.zoomToActualSize(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

/// Keeps the save panel's file type and name extension in step with the Format pop-up.
@MainActor
private final class ExportFormatObserver: NSObject {
    private weak var panel: NSSavePanel?
    private weak var popUp: NSPopUpButton?

    init(panel: NSSavePanel, popUp: NSPopUpButton) {
        self.panel = panel
        self.popUp = popUp
    }

    @objc func formatChanged(_ sender: Any?) { apply() }

    func apply() {
        guard let panel, let popUp else { return }
        let format = MermaidDiagramExport.Format.allCases[max(popUp.indexOfSelectedItem, 0)]
        panel.allowedContentTypes = [format.contentType]
        let name = panel.nameFieldStringValue.isEmpty ? "Diagram" : panel.nameFieldStringValue
        let base = (name as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base.isEmpty ? "Diagram" : base).\(format.fileExtension)"
    }
}

/// Draws a prepared diagram into an image file's bytes. Separate from the window so it can be
/// tested without a save panel.
enum MermaidDiagramExport {
    enum Format: CaseIterable {
        case png
        case jpeg

        var title: String {
            switch self {
            case .png: return "PNG"
            case .jpeg: return "JPEG"
            }
        }

        var contentType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            }
        }

        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            }
        }
    }

    static let scales: [CGFloat] = [1, 2, 3]

    /// The light colors exports use: the preview's light look (white page, dark text), the same
    /// one the PDF export prints with.
    @MainActor
    static var lightContext: MarkdownPreviewStyle.MermaidRenderingContext {
        MarkdownPreviewStyle().withAppearance(.light).mermaidRenderingContext
    }

    /// `source` laid out again in ``lightContext`` and encoded, so an export is light whatever
    /// the preview or the viewer shows.
    @MainActor
    static func lightImageData(source: String, scale: CGFloat, format: Format) async -> Data? {
        let context = lightContext
        guard let prepared = await MermaidDiagramViewer.prepare(source: source, context: context) else { return nil }
        let background = context.backgroundRGBA
        return imageData(
            diagram: prepared.value,
            background: CGColor(srgbRed: background.red, green: background.green, blue: background.blue, alpha: 1),
            scale: scale,
            format: format
        )
    }
    /// Longest side of the exported bitmap; a larger diagram is scaled down to fit.
    static let maxPixelDimension: CGFloat = 16_384
    static let jpegQuality: CGFloat = 0.9

    /// The bitmap's scale for `diagram` at the requested `scale`, reduced so neither side passes
    /// ``maxPixelDimension``.
    static func effectiveScale(for size: CGSize, requested scale: CGFloat) -> CGFloat {
        let longest = max(size.width, size.height) * scale
        return longest > maxPixelDimension ? scale * maxPixelDimension / longest : scale
    }

    @MainActor
    static func image(diagram: PreparedDiagram, background: CGColor, scale requested: CGFloat) -> CGImage? {
        let bounds = diagram.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = effectiveScale(for: bounds.size, requested: requested)
        let width = Int((bounds.width * scale).rounded(.up))
        let height = Int((bounds.height * scale).rounded(.up))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            // sRGB, so the file looks the same in whatever app opens it.
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The diagram is laid out with y = 0 at the top. Pin that to the bitmap's top edge: the
        // pixel size is rounded up, and anchoring at `bounds.height` would put the spare
        // fraction of a row above the diagram instead of below it.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: CGFloat(height) / scale)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        // Labels are drawn with AppKit text; give them the unflipped context they expect (see
        // `MermaidDiagramCanvasView.draw`), whatever context is current on the main thread.
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        diagram.render(context, bounds)
        NSGraphicsContext.current = previous
        return context.makeImage()
    }

    @MainActor
    static func imageData(
        diagram: PreparedDiagram, background: CGColor, scale: CGFloat, format: Format
    ) -> Data? {
        guard let image = image(diagram: diagram, background: background, scale: scale) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, format.contentType.identifier as CFString, 1, nil
        ) else { return nil }
        let pixelsPerPoint = CGFloat(image.width) / max(diagram.bounds.width, 1)
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * pixelsPerPoint,
            kCGImagePropertyDPIHeight: 72 * pixelsPerPoint
        ]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Centers the diagram when it is smaller than the window instead of pinning it to a corner.
@MainActor
private final class MermaidDiagramClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let size = document.frame.size
        if rect.width > size.width { rect.origin.x = (size.width - rect.width) / 2 }
        if rect.height > size.height { rect.origin.y = (size.height - rect.height) / 2 }
        return rect
    }
}

/// Draws the prepared diagram as vectors at whatever scale the scroll view magnifies it to.
@MainActor
final class MermaidDiagramCanvasView: NSView {
    private let diagram: PreparedDiagram

    init(diagram: PreparedDiagram) {
        self.diagram = diagram
        super.init(frame: CGRect(origin: .zero, size: diagram.bounds.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The diagram is laid out with y = 0 at the top.
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let current = NSGraphicsContext.current else { return }
        let context = current.cgContext
        context.saveGState()
        context.clip(to: dirtyRect)
        context.translateBy(x: -diagram.bounds.minX, y: -diagram.bounds.minY)
        // Luna draws labels with `NSAttributedString.draw`, which follows the current AppKit
        // context's `isFlipped`. It expects the unflipped one it makes for itself when drawing
        // into a bitmap (the preview's raster); with this view's flipped context current, the
        // text came out upside down.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        diagram.render(context, diagram.bounds)
        NSGraphicsContext.current = current
        context.restoreGState()
    }
}
