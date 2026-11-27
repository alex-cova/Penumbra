import AppKit
import SwiftUI

struct PhotoCanvasView: View {
    @Bindable var session: PhotoEditorSession

    /// Transient gesture bases; the viewport itself lives on the session so the toolbar can drive it.
    @State private var magnifyBaseZoom: CGFloat?
    @State private var panBaseOffset: CGSize?
    @State private var splitFraction: CGFloat = 0.5
    @State private var hoverPoint: CGPoint?
    @State private var optionHeld = false

    @AppStorage("photoEditor.gridStyle") private var gridStyleRaw = PhotoGridStyle.off.rawValue
    @AppStorage("photoEditor.gridSquareSize") private var gridSquareSize = 96.0

    private var gridStyle: PhotoGridStyle {
        PhotoGridStyle(rawValue: gridStyleRaw) ?? .off
    }

    private var viewport: PhotoViewport { session.viewport }
    private var canvasSize: CGSize { session.canvasSize }
    private var displayPixelSize: CGSize { session.displayImagePixelSize }

    var body: some View {
        ZStack {
            PhotoStudio.Photo.canvasVoid

            if let image = displayedImage {
                let rect = viewport.imageRect(imagePixelSize: displayPixelSize, in: canvasSize)
                checkerboard(in: rect)

                if session.compareMode == .sideBySide, let original = session.originalPreview {
                    PhotoCompareSideBySideLayer(
                        original: original,
                        edited: image,
                        imagePixelSize: displayPixelSize,
                        canvasSize: canvasSize,
                        crisp: viewport.zoom >= 4
                    )
                } else {
                    photoLayer(image, rect: rect)
                    if session.compareMode == .split, let original = session.originalPreview {
                        PhotoCompareSplitLayer(
                            original: original,
                            imageRect: rect,
                            canvasSize: canvasSize,
                            crisp: viewport.zoom >= 4,
                            fraction: $splitFraction
                        )
                    }
                }

                clippingLayer(rect: rect)
                gridLayer(rect: rect)

                if session.isCropping {
                    CropOverlay(
                        imageRect: rect,
                        crop: session.adjustments.crop,
                        aspect: session.cropAspect.ratio,
                        pixelSize: cropPixelSize
                    ) { newCrop in
                        session.mutate { $0.crop = newCrop }
                    } onEnded: {
                        session.commit()
                    }
                }

                if session.isRedacting {
                    RedactOverlay(
                        imageRect: rect,
                        regions: session.adjustments.redactions,
                        selectedID: session.selectedRedactionID,
                        tint: PhotoStudio.accent,
                        onDrawEnded: { session.addRedaction(rect: $0) },
                        onSelect: { session.selectedRedactionID = $0 },
                        onChange: { session.updateRedaction(id: $0, rect: $1) },
                        onChangeEnded: { session.commit() }
                    )
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .overlay(alignment: loupeAlignment) {
            if let sample = sampledPixel, let preview = session.previewImage {
                PhotoLoupeOverlay(preview: preview, pixel: sample, onCopy: copyToPasteboard)
                    .padding(PhotoStudio.Spacing.sm)
                    .transition(.opacity)
            }
        }
        .onContinuousHover { phase in
            if case .active(let point) = phase {
                hoverPoint = point
            } else {
                hoverPoint = nil
            }
        }
        .onModifierKeysChanged(mask: .option) { _, new in
            optionHeld = new.contains(.option)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .background(PhotoScrollZoomCatcher(onZoom: handleScrollZoom))
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            session.canvasGeometryChanged(size)
        }
        .gesture(panAndZoom)
        .onTapGesture(count: 2, perform: toggleFitAndActual)
        .overlay(alignment: .bottomTrailing) {
            viewportHint
                .padding(PhotoStudio.Spacing.sm)
        }
        .accessibilityLabel("Photo canvas")
        .accessibilityValue("\(viewport.percent) percent")
        // Note: no ⌘0 / ⌘1 / ⌘9 / ⌘+ / ⌘− bindings here. In Umbra those belong to the
        // window (sidebar toggles, editor zoom) and menu key equivalents win over canvas
        // `.onKeyPress`, so the toolbar buttons are the way to frame the photo.
        .onKeyPress(.return) {
            guard session.isCropping else { return .ignored }
            session.applyCrop()
            return .handled
        }
        .onKeyPress(.escape) {
            if session.isCropping {
                session.cancelCrop()
                return .handled
            }
            if session.isRedacting {
                session.setRedacting(false)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard session.isRedacting, let id = session.selectedRedactionID else { return .ignored }
            session.removeRedaction(id: id)
            return .handled
        }
        .onKeyPress(keys: [.space], phases: [.down, .up]) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            if press.phase.contains(.up) {
                session.endCompare()
            } else {
                session.beginCompare()
            }
            return .handled
        }
    }

    // MARK: - Image sizing

    private var displayedImage: CGImage? {
        session.isComparing ? (session.originalPreview ?? session.previewImage) : session.previewImage
    }

    /// Post-orientation pixel size (crop excluded) — the space the crop rect and its readout live in.
    private var cropPixelSize: CGSize {
        let adj = session.adjustments
        return TransformEngine.orientationTransform(
            flipH: adj.flipHorizontal,
            flipV: adj.flipVertical,
            quarterTurns: adj.rotationQuarterTurns,
            straightenDegrees: adj.straightenDegrees,
            size: session.sourcePixelSize
        ).outputSize
    }

    // MARK: - Layers

    private func photoLayer(_ image: CGImage, rect: CGRect) -> some View {
        Image(decorative: image, scale: 1, orientation: .up)
            .interpolation(viewport.zoom >= 4 ? .none : .high)
            .resizable()
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .position(x: rect.midX, y: rect.midY)
            .photoAnimation(PhotoStudio.Motion.quick, value: session.isComparing)
    }

    @ViewBuilder
    private func gridLayer(rect: CGRect) -> some View {
        let showPixelGrid = PhotoGridRenderer.pixelGridIsVisible(
            imageRect: rect,
            imagePixelSize: displayPixelSize
        )
        if gridStyle != .off || showPixelGrid || session.isCropping {
            Canvas { context, _ in
                let stroke = GraphicsContext.Shading.color(Color.white.opacity(0.35))
                let fine = GraphicsContext.Shading.color(Color.white.opacity(0.18))

                if session.isCropping {
                    var path = Path()
                    let cropRect = cropViewRect(in: rect)
                    for line in PhotoGridRenderer.lines(style: .thirds, in: cropRect, squareSpacing: 0) {
                        path.move(to: line.start)
                        path.addLine(to: line.end)
                    }
                    context.stroke(path, with: stroke, lineWidth: 1)
                }

                if gridStyle != .off {
                    var path = Path()
                    for line in PhotoGridRenderer.lines(
                        style: gridStyle,
                        in: rect,
                        squareSpacing: gridSquareSize
                    ) {
                        path.move(to: line.start)
                        path.addLine(to: line.end)
                    }
                    context.stroke(path, with: stroke, lineWidth: 1)
                }

                if showPixelGrid {
                    var path = Path()
                    for line in PhotoGridRenderer.pixelGridLines(
                        imageRect: rect,
                        imagePixelSize: displayPixelSize,
                        viewBounds: CGRect(origin: .zero, size: canvasSize)
                    ) {
                        path.move(to: line.start)
                        path.addLine(to: line.end)
                    }
                    context.stroke(path, with: fine, lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func clippingLayer(rect: CGRect) -> some View {
        if session.showClippingWarnings, let mask = session.clippingMask {
            Image(decorative: mask, scale: 1, orientation: .up)
                .interpolation(.none)
                .resizable()
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Loupe / colour sampler

    private var samplingActive: Bool { session.isSampling || optionHeld }

    private var loupeAlignment: Alignment {
        guard let hoverPoint, canvasSize.width > 0 else { return .topTrailing }
        let left = hoverPoint.x < canvasSize.width / 2
        let top = hoverPoint.y < canvasSize.height / 2
        return switch (top, left) {
        case (true, true): .bottomTrailing
        case (true, false): .bottomLeading
        case (false, true): .topTrailing
        case (false, false): .topLeading
        }
    }

    private var sampledPixel: PhotoSampledPixel? {
        guard samplingActive,
              let preview = session.previewImage,
              let point = hoverPoint else { return nil }
        let rect = viewport.imageRect(imagePixelSize: displayPixelSize, in: canvasSize)
        guard rect.contains(point), rect.width > 0, rect.height > 0 else { return nil }
        let px = (point.x - rect.minX) / rect.width * CGFloat(preview.width)
        let py = (point.y - rect.minY) / rect.height * CGFloat(preview.height)
        return PhotoPixelSampler.pixel(in: preview, at: CGPoint(x: px, y: py))
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func cropViewRect(in imageRect: CGRect) -> CGRect {
        let crop = session.adjustments.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return CGRect(
            x: imageRect.minX + crop.minX * imageRect.width,
            y: imageRect.minY + crop.minY * imageRect.height,
            width: crop.width * imageRect.width,
            height: crop.height * imageRect.height
        )
    }

    private func checkerboard(in rect: CGRect) -> some View {
        Canvas { context, _ in
            let tile: CGFloat = 12
            guard rect.width > 0, rect.height > 0 else { return }
            context.clip(to: Path(rect))
            let cols = Int(ceil(rect.width / tile)) + 1
            let rows = Int(ceil(rect.height / tile)) + 1
            for row in 0..<rows {
                for col in 0..<cols where !(row + col).isMultiple(of: 2) {
                    let cell = CGRect(
                        x: rect.minX + CGFloat(col) * tile,
                        y: rect.minY + CGFloat(row) * tile,
                        width: tile,
                        height: tile
                    )
                    context.fill(Path(cell), with: .color(Color.primary.opacity(0.08)))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var viewportHint: some View {
        Text("\(viewport.percent)%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, PhotoStudio.Spacing.sm)
            .padding(.vertical, PhotoStudio.Spacing.xs)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: PhotoStudio.Radius.xs))
            .accessibilityHidden(true)
    }

    // MARK: - Gestures

    private func toggleFitAndActual() {
        let fit = PhotoViewport.fitZoom(imagePixelSize: displayPixelSize, in: canvasSize)
        if abs(viewport.zoom - fit) < 0.01 {
            session.frame(.actualSize)
        } else {
            session.frame(.fit)
        }
    }

    private func handleScrollZoom(factor: CGFloat, point: CGPoint) {
        session.zoomViewport(by: factor, toward: point)
    }

    private var panAndZoom: some Gesture {
        SimultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    if magnifyBaseZoom == nil { magnifyBaseZoom = viewport.zoom }
                    guard let base = magnifyBaseZoom else { return }
                    let factor = (base * value.magnification) / max(viewport.zoom, 0.0001)
                    session.zoomViewport(by: factor, toward: value.startLocation, interactive: true)
                }
                .onEnded { _ in
                    magnifyBaseZoom = nil
                    session.syncRenderResolution()
                },
            DragGesture()
                .onChanged { value in
                    if panBaseOffset == nil { panBaseOffset = viewport.offset }
                    guard let base = panBaseOffset else { return }
                    session.viewport = PhotoViewport(
                        zoom: viewport.zoom,
                        offset: CGSize(
                            width: base.width + value.translation.width,
                            height: base.height + value.translation.height
                        )
                    )
                    .clamped(imagePixelSize: displayPixelSize, in: canvasSize)
                }
                .onEnded { _ in
                    panBaseOffset = nil
                }
        )
    }
}

// MARK: - Crop overlay

private struct CropOverlay: View {
    /// The photo's on-screen frame (already zoomed & panned).
    let imageRect: CGRect
    let crop: CGRect?
    let aspect: CGFloat?
    /// Post-orientation image size in pixels, for aspect-locked resizing in real pixel space.
    let pixelSize: CGSize
    let onChanged: (CGRect) -> Void
    let onEnded: () -> Void

    @State private var dragStart: CGRect = .zero

    private var normalizedCrop: CGRect {
        crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    var body: some View {
        let rect = viewCropRect()
        ZStack {
            Color.black.opacity(0.45)
                .reverseMask(alignment: .topLeading) {
                    Rectangle()
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
                .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .highPriorityGesture(bodyDrag)
                .accessibilityLabel("Crop rectangle")

            Text("\(Int((normalizedCrop.width * pixelSize.width).rounded())) × \(Int((normalizedCrop.height * pixelSize.height).rounded()))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: .rect(cornerRadius: PhotoStudio.Radius.xs))
                .position(x: rect.midX, y: max(rect.minY - 14, 10))
                .allowsHitTesting(false)

            ForEach(CropHandle.allCases) { handle in
                CropHandleKnob(handle: handle)
                    .position(handle.point(in: rect))
                    .highPriorityGesture(handleDrag(handle))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bodyDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == .zero { dragStart = normalizedCrop }
                let dx = value.translation.width / max(imageRect.width, 1)
                let dy = value.translation.height / max(imageRect.height, 1)
                var next = dragStart.offsetBy(dx: dx, dy: dy)
                next.origin.x = min(max(0, next.origin.x), 1 - next.width)
                next.origin.y = min(max(0, next.origin.y), 1 - next.height)
                onChanged(next)
            }
            .onEnded { _ in
                dragStart = .zero
                onEnded()
            }
    }

    private func handleDrag(_ handle: CropHandle) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == .zero { dragStart = normalizedCrop }
                let dx = value.translation.width / max(imageRect.width, 1)
                let dy = value.translation.height / max(imageRect.height, 1)
                var next = resize(dragStart, handle: handle, dx: dx, dy: dy)
                next = clampUnit(next)
                if let aspect {
                    next = TransformEngine.constrainedCrop(
                        next,
                        ratio: aspect,
                        anchor: handle.anchor,
                        imagePixelSize: pixelSize
                    )
                    next = clampUnit(next)
                }
                onChanged(next)
            }
            .onEnded { _ in
                dragStart = .zero
                onEnded()
            }
    }

    private func resize(_ start: CGRect, handle: CropHandle, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = start.minX
        var minY = start.minY
        var maxX = start.maxX
        var maxY = start.maxY
        switch handle {
        case .topLeft: minX += dx; minY += dy
        case .topRight: maxX += dx; minY += dy
        case .bottomLeft: minX += dx; maxY += dy
        case .bottomRight: maxX += dx; maxY += dy
        case .top: minY += dy
        case .bottom: maxY += dy
        case .left: minX += dx
        case .right: maxX += dx
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func clampUnit(_ rect: CGRect) -> CGRect {
        var r = rect.standardized
        if r.width < 0.05 { r.size.width = 0.05 }
        if r.height < 0.05 { r.size.height = 0.05 }
        r.origin.x = min(max(0, r.origin.x), 1 - r.width)
        r.origin.y = min(max(0, r.origin.y), 1 - r.height)
        return r
    }

    /// Normalized crop → on-screen rect, derived straight from the zoomed image frame.
    private func viewCropRect() -> CGRect {
        CGRect(
            x: imageRect.minX + normalizedCrop.minX * imageRect.width,
            y: imageRect.minY + normalizedCrop.minY * imageRect.height,
            width: normalizedCrop.width * imageRect.width,
            height: normalizedCrop.height * imageRect.height
        )
    }
}

private extension View {
    func reverseMask<Mask: View>(
        alignment: Alignment = .center,
        @ViewBuilder _ mask: () -> Mask
    ) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: alignment) {
                    mask()
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}
