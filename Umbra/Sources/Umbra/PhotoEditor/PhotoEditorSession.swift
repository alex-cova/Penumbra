import CoreImage
import Foundation
import ImageIO
import Observation

enum PhotoExportState: Equatable {
    case idle
    case exporting
}

/// CIImage is safe for concurrent reads but is not marked `Sendable`.
nonisolated struct SendableCIImage: @unchecked Sendable {
    let image: CIImage
}

/// CGImage likewise predates Swift 6 concurrency annotations.
nonisolated struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
}

@MainActor
@Observable
final class PhotoEditorSession {
    private(set) var sourceURL: URL?
    private(set) var sourceCIImage: CIImage?
    private(set) var sourcePixelSize: CGSize = .zero
    private(set) var sourceMetadata: [String: Any]?
    private(set) var sourceFileName: String?
    private(set) var isRAW = false
    private(set) var exifSummary: PhotoExifSummary = .empty
    private(set) var imageInfo: PhotoImageInfo = .empty

    private(set) var history = EditHistory(.identity)
    private var draft: EditAdjustment?

    var adjustments: EditAdjustment { draft ?? history.present }

    private(set) var previewImage: CGImage?
    private(set) var originalPreview: CGImage?
    private(set) var presetThumbnails: [PhotoPreset: CGImage] = [:]
    private(set) var previewHistogram: PhotoHistogram = .empty

    /// Crop is a canvas mode, not a tab: while true the canvas suspends pan/zoom, shows the crop
    /// overlay, and the preview renders uncropped so the overlay can be dragged over the whole frame.
    var isCropping = false
    var isComparing = false
    var loadError: String?
    var exportState: PhotoExportState = .idle
    var cropAspect: TransformEngine.AspectPreset = .original
    var activeCurveChannel: ToneCurveChannel = .rgb
    var activeColorBand: ColorBand = .reds
    private(set) var batchCompleted = 0
    private(set) var batchTotal = 0

    /// Where the photo sits on the canvas. View state, not part of the edit recipe or undo history,
    /// so it lives here rather than in `EditAdjustment` — the canvas and the toolbar zoom cluster
    /// both drive it.
    var viewport = PhotoViewport.identity
    private(set) var canvasSize: CGSize = .zero
    private var hasFramedImage = false

    /// Canvas overlays that read the rendered preview rather than the recipe.
    private(set) var showClippingWarnings = false
    private(set) var clippingMask: CGImage?
    var compareMode: PhotoCompareMode = .off
    /// Loupe / colour sampler active (toggle button, or hold ⌥).
    var isSampling = false

    private let engine = PhotoRenderEngine()

    private var coalescer = RenderCoalescer()
    private var isRendering = false
    private var interactiveProxy: SendableCIImage?
    private var finalProxy: SendableCIImage?

    private var thumbnailTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var viewportMaxDimension: CGFloat = 1600
    private var holdsSourceAccess = false

    /// Interactive frames render from a proxy no larger than this, regardless of canvas size.
    private static let interactiveMaxDimension: CGFloat = 1100

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var hasImage: Bool { sourceCIImage != nil }

    func importImage(from url: URL) {
        stopSourceAccess()
        holdsSourceAccess = url.startAccessingSecurityScopedResource()
        guard loadSource(from: url, recipe: .identity) else {
            stopSourceAccess()
            loadError = String(localized: "Could not open this image.")
            return
        }
        history = EditHistory(.identity)
        draft = nil
        cropAspect = .original
        isCropping = false
        loadError = nil
        originalPreview = nil
        previewImage = nil
        previewHistogram = .empty
        presetThumbnails = [:]
        hasFramedImage = false
        invalidateProxies()
        frameToFitIfNeeded()
        scheduleRender(quality: .final)
        renderOriginalPreviewOffMain()
        rebuildThumbnails()
        scheduleAutosave()
    }

    /// Opens `url` for editing, restoring the autosaved recipe when one exists. Umbra opens one
    /// session per image tab; the store is keyed by file path so several images keep their own
    /// recipes (the reference kept a single snapshot for its single open photo).
    func openDocument(at url: URL) {
        stopSourceAccess()
        holdsSourceAccess = url.startAccessingSecurityScopedResource()
        let path = url.standardizedFileURL.path
        if let snapshot = PhotoEditorSessionStore.load(forPath: path),
           snapshot.adjustments != .identity,
           loadSource(from: url, recipe: snapshot.adjustments) {
            history = EditHistory(snapshot.adjustments)
            draft = nil
            cropAspect = TransformEngine.matchingAspect(for: snapshot.adjustments.crop)
            loadError = nil
            hasFramedImage = false
            invalidateProxies()
            frameToFitIfNeeded()
            scheduleRender(quality: .final)
            renderOriginalPreviewOffMain()
            rebuildThumbnails()
            return
        }
        loadError = nil
        importImage(from: url)
    }

    /// `maxDimension` is the proxy resolution the canvas wants for the photo at its current
    /// on-screen size. Quantised up to a 512-point step so a continuous pinch does not re-decode
    /// every frame; while `interactive` is true the proxy only ever grows, and shrinks back when the
    /// gesture ends.
    func setViewport(maxDimension: CGFloat, interactive: Bool = false) {
        let stepped = (max(320, maxDimension) / 512).rounded(.up) * 512
        if interactive, stepped <= viewportMaxDimension { return }
        guard abs(stepped - viewportMaxDimension) > 8 else { return }
        viewportMaxDimension = stepped
        originalPreview = nil
        invalidateProxies()
        if sourceCIImage != nil {
            scheduleRender(quality: .final)
            renderOriginalPreviewOffMain()
        }
    }

    // MARK: - Canvas viewport

    /// The photo's on-screen logical size in image pixels: source dimensions after
    /// flip / rotate / straighten, minus the crop when it is applied. Crop mode previews the whole
    /// frame, so the overlay can be dragged over all of it.
    var displayImagePixelSize: CGSize {
        guard sourcePixelSize.width > 0, sourcePixelSize.height > 0 else {
            return canvasSize == .zero ? CGSize(width: 1, height: 1) : canvasSize
        }
        let adj = adjustments
        let oriented = TransformEngine.orientationTransform(
            flipH: adj.flipHorizontal,
            flipV: adj.flipVertical,
            quarterTurns: adj.rotationQuarterTurns,
            straightenDegrees: adj.straightenDegrees,
            size: sourcePixelSize
        ).outputSize
        guard !isCropping, !isRedacting, let crop = adj.crop, crop.width > 0, crop.height > 0 else {
            return oriented
        }
        return CGSize(width: oriented.width * crop.width, height: oriented.height * crop.height)
    }

    func canvasGeometryChanged(_ size: CGSize) {
        canvasSize = size
        frameToFitIfNeeded()
        syncRenderResolution()
    }

    enum FrameMode { case fit, actualSize, fill }

    func frame(_ mode: FrameMode) {
        let pixels = displayImagePixelSize
        switch mode {
        case .fit:
            viewport = .fitting(imagePixelSize: pixels, in: canvasSize)
        case .actualSize:
            viewport = viewport.actualSize()
        case .fill:
            viewport = .filling(imagePixelSize: pixels, in: canvasSize)
        }
        viewport = viewport.clamped(imagePixelSize: pixels, in: canvasSize)
        hasFramedImage = true
        syncRenderResolution()
    }

    /// Fit-to-window on first load, once both an image and a real canvas size are known.
    func frameToFitIfNeeded() {
        guard !hasFramedImage, hasImage, canvasSize.width > 0, canvasSize.height > 0 else { return }
        let pixels = displayImagePixelSize
        guard pixels.width > 1, pixels.height > 1 else { return }
        viewport = .fitting(imagePixelSize: pixels, in: canvasSize)
        hasFramedImage = true
    }

    func zoomViewport(by factor: CGFloat, toward point: CGPoint, interactive: Bool = false) {
        let pixels = displayImagePixelSize
        viewport = viewport
            .zoomed(to: viewport.zoom * factor, toward: point, imagePixelSize: pixels, in: canvasSize)
            .clamped(imagePixelSize: pixels, in: canvasSize)
        syncRenderResolution(interactive: interactive)
    }

    func zoomViewportStep(zoomingIn: Bool) {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        zoomViewport(by: zoomingIn ? PhotoViewport.zoomStep : 1 / PhotoViewport.zoomStep, toward: center)
    }

    /// "Zoom to crop": frame the current crop rect (or the whole image if there is none).
    func zoomViewportToCrop() {
        let region = adjustments.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let base = isCropping
            ? displayImagePixelSize
            : TransformEngine.orientationTransform(
                flipH: adjustments.flipHorizontal,
                flipV: adjustments.flipVertical,
                quarterTurns: adjustments.rotationQuarterTurns,
                straightenDegrees: adjustments.straightenDegrees,
                size: sourcePixelSize
            ).outputSize
        viewport = viewport
            .zoomedToRegion(region, imagePixelSize: base, in: canvasSize)
            .clamped(imagePixelSize: displayImagePixelSize, in: canvasSize)
        syncRenderResolution()
    }

    func syncRenderResolution(interactive: Bool = false) {
        let rect = viewport.imageRect(imagePixelSize: displayImagePixelSize, in: canvasSize)
        let onScreenLongest = max(rect.width, rect.height)
        let sourceLongest = max(sourcePixelSize.width, sourcePixelSize.height)
        setViewport(maxDimension: min(onScreenLongest * 2, max(sourceLongest, 1)), interactive: interactive)
    }

    // MARK: - Canvas overlays

    func toggleClippingWarnings() {
        showClippingWarnings.toggle()
        if showClippingWarnings {
            if let preview = previewImage {
                let boxed = SendableCGImage(image: preview)
                Task { [weak self] in
                    let mask: SendableCGImage? = await Task.detached(priority: .userInitiated) {
                        PhotoClippingOverlay.mask(for: boxed.image).map(SendableCGImage.init)
                    }.value
                    self?.clippingMask = mask?.image
                }
            }
        } else {
            clippingMask = nil
        }
    }

    func setCompareMode(_ mode: PhotoCompareMode) {
        compareMode = mode
        if mode != .off, originalPreview == nil {
            renderOriginalPreviewOffMain()
        }
    }

    func cycleCompareMode() {
        setCompareMode(compareMode.next)
    }

    func mutate(_ change: (inout EditAdjustment) -> Void) {
        var next = adjustments
        change(&next)
        guard next != adjustments else { return }
        let rawChanged = next.raw != adjustments.raw
        draft = next
        scheduleRender(quality: .interactive, rawNeedsDecode: rawChanged)
    }

    func commit() {
        let next = draft ?? history.present
        var updated = history
        updated.commit(next)
        history = updated
        draft = nil
        scheduleRender(quality: .final)
        scheduleAutosave()
    }

    /// The crop / orientation as it was when crop mode was entered, for `cancelCrop()`.
    private var cropEntrySnapshot: EditAdjustment?

    func setCropping(_ cropping: Bool) {
        guard isCropping != cropping else { return }
        isCropping = cropping
        cropEntrySnapshot = cropping ? adjustments : nil
        scheduleRender(quality: .final)
    }

    /// Leave crop mode keeping the current crop (Return / the toolbar toggle).
    func applyCrop() {
        guard isCropping else { return }
        isCropping = false
        cropEntrySnapshot = nil
        commit()
        scheduleRender(quality: .final)
    }

    /// Leave crop mode, restoring the crop and orientation to what they were on entry (Esc).
    func cancelCrop() {
        guard isCropping else { return }
        isCropping = false
        if let snapshot = cropEntrySnapshot {
            mutate { adj in
                adj.crop = snapshot.crop
                adj.rotationQuarterTurns = snapshot.rotationQuarterTurns
                adj.straightenDegrees = snapshot.straightenDegrees
                adj.flipHorizontal = snapshot.flipHorizontal
                adj.flipVertical = snapshot.flipVertical
            }
            commit()
            cropAspect = TransformEngine.matchingAspect(for: snapshot.crop)
        }
        cropEntrySnapshot = nil
        scheduleRender(quality: .final)
    }

    // MARK: - Redaction

    var isRedacting = false
    var selectedRedactionID: UUID?

    func setRedacting(_ on: Bool) {
        guard isRedacting != on else { return }
        isRedacting = on
        if !on { selectedRedactionID = nil }
        scheduleRender(quality: .final)
    }

    func addRedaction(rect: CGRect) {
        let region = RedactionRegion(rect: rect.standardized)
        mutate { $0.redactions.append(region) }
        commit()
        selectedRedactionID = region.id
    }

    func updateRedaction(id: UUID, rect: CGRect) {
        mutate { adj in
            guard let index = adj.redactions.firstIndex(where: { $0.id == id }) else { return }
            adj.redactions[index].rect = rect.standardized
        }
    }

    func setRedactionStyle(id: UUID, _ style: RedactionStyle) {
        mutate { adj in
            guard let index = adj.redactions.firstIndex(where: { $0.id == id }) else { return }
            adj.redactions[index].style = style
        }
        commit()
    }

    func setRedactionStrength(id: UUID, _ strength: Double) {
        mutate { adj in
            guard let index = adj.redactions.firstIndex(where: { $0.id == id }) else { return }
            adj.redactions[index].strength = strength
        }
    }

    func removeRedaction(id: UUID) {
        mutate { $0.redactions.removeAll { $0.id == id } }
        commit()
        if selectedRedactionID == id { selectedRedactionID = nil }
    }

    /// Transpose the crop rectangle's aspect (landscape ↔ portrait).
    func swapCropOrientation() {
        guard let crop = adjustments.crop else { return }
        let oriented = displayImagePixelSize
        guard oriented.width > 0, oriented.height > 0 else { return }
        let currentRatio = (crop.width * oriented.width) / (crop.height * oriented.height)
        guard currentRatio > 0 else { return }
        mutate { adj in
            adj.crop = TransformEngine.constrainedCrop(
                crop,
                ratio: 1 / currentRatio,
                anchor: .topLeft,
                imagePixelSize: oriented
            )
        }
        commit()
        cropAspect = TransformEngine.matchingAspect(for: adjustments.crop)
    }

    func undo() {
        let previousRAW = adjustments.raw
        draft = nil
        var updated = history
        updated.undo()
        history = updated
        scheduleRender(quality: .final, rawNeedsDecode: previousRAW != adjustments.raw)
        scheduleAutosave()
    }

    func redo() {
        let previousRAW = adjustments.raw
        draft = nil
        var updated = history
        updated.redo()
        history = updated
        scheduleRender(quality: .final, rawNeedsDecode: previousRAW != adjustments.raw)
        scheduleAutosave()
    }

    func beginCompare() {
        guard hasImage else { return }
        if originalPreview == nil {
            renderOriginalPreviewOffMain()
        }
        isComparing = true
    }

    func endCompare() {
        isComparing = false
    }

    func reset() {
        let previousRAW = adjustments.raw
        draft = nil
        var updated = history
        updated.commit(.identity)
        history = updated
        cropAspect = .original
        scheduleRender(quality: .final, rawNeedsDecode: previousRAW != .identity)
        scheduleAutosave()
    }

    func applyLook(_ look: EditAdjustment) {
        mutate { current in
            current = current.replacingLook(with: look)
        }
        commit()
    }

    /// Called after the rendered recipe was written back to the source file: the file now holds
    /// the edited pixels, so the recipe resets to identity and the source is re-decoded from
    /// disk. Umbra-only — the reference never saves in place.
    func markSaved() {
        draft = nil
        history = EditHistory(.identity)
        cropAspect = .original
        isCropping = false
        isRedacting = false
        selectedRedactionID = nil
        if let url = sourceURL {
            PhotoEditorSessionStore.clear(forPath: url.standardizedFileURL.path)
            _ = loadSource(from: url, recipe: .identity)
        }
        hasFramedImage = false
        invalidateProxies()
        frameToFitIfNeeded()
        scheduleRender(quality: .final)
        renderOriginalPreviewOffMain()
        rebuildThumbnails()
    }

    func releaseSource() {
        thumbnailTask?.cancel()
        autosaveTask?.cancel()
        stopSourceAccess()
    }

    /// Close the current document and return to the drop well. Clears the autosaved snapshot so the
    /// photo does not reappear on the next launch.
    func closeDocument() {
        thumbnailTask?.cancel()
        autosaveTask?.cancel()
        stopSourceAccess()

        sourceURL = nil
        sourceCIImage = nil
        sourcePixelSize = .zero
        sourceMetadata = nil
        sourceFileName = nil
        isRAW = false
        exifSummary = .empty
        imageInfo = .empty

        history = EditHistory(.identity)
        draft = nil
        previewImage = nil
        originalPreview = nil
        presetThumbnails = [:]
        previewHistogram = .empty

        isCropping = false
        isRedacting = false
        selectedRedactionID = nil
        isComparing = false
        loadError = nil
        cropAspect = .original
        exportState = .idle
        showClippingWarnings = false
        clippingMask = nil
        compareMode = .off
        isSampling = false

        viewport = .identity
        canvasSize = .zero
        hasFramedImage = false
        invalidateProxies()

        if let url = sourceURL {
            PhotoEditorSessionStore.clear(forPath: url.standardizedFileURL.path)
        }
    }

    func export(format: PhotoExportFormat, quality: Double) async -> Result<Data, Error> {
        guard let url = sourceURL else {
            return .failure(PhotoExportError.encodeFailed)
        }
        exportState = .exporting
        defer { exportState = .idle }

        let engine = self.engine
        let adj = adjustments
        let boxedURL = url
        let ciFormat: CIFormat = format == .tiff16 ? .RGBA16 : .RGBA8
        let rendered: SendableCGImage? = await Task.detached(priority: .userInitiated) {
            guard let image = engine.renderFull(sourceURL: boxedURL, adjustments: adj, format: ciFormat) else {
                return nil
            }
            return SendableCGImage(image: image)
        }.value

        guard let rendered else {
            return .failure(PhotoExportError.encodeFailed)
        }

        do {
            let data = try PhotoExportEngine.encode(
                rendered.image,
                format: format,
                quality: quality,
                sourceMetadata: sourceMetadata
            )
            return .success(data)
        } catch {
            return .failure(error)
        }
    }

    func batchExport(
        urls: [URL],
        format: PhotoExportFormat,
        quality: Double,
        destination: URL
    ) async -> [PhotoBatchExportItem] {
        exportState = .exporting
        batchTotal = urls.count
        batchCompleted = 0
        defer {
            exportState = .idle
            batchTotal = 0
            batchCompleted = 0
        }

        let engine = self.engine
        let adj = adjustments
        let destAccess = destination.startAccessingSecurityScopedResource()
        defer {
            if destAccess { destination.stopAccessingSecurityScopedResource() }
        }

        var items: [PhotoBatchExportItem] = []
        items.reserveCapacity(urls.count)
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            let item = await Task.detached(priority: .userInitiated) {
                PhotoBatchExportEngine.export(
                    sourceURL: url,
                    adjustments: adj,
                    format: format,
                    quality: quality,
                    destinationDirectory: destination,
                    engine: engine
                )
            }.value
            if accessed { url.stopAccessingSecurityScopedResource() }
            items.append(item)
            batchCompleted += 1
        }
        return items
    }

    // MARK: - Rendering

    /// Crop mode shows the full transformed image so the overlay can be dragged; every other
    /// state previews the cropped result.
    private var renderAdjustments: EditAdjustment {
        var adj = adjustments
        if isCropping || isRedacting {
            adj.crop = nil
        }
        return adj
    }

    private func scheduleRender(quality: RenderQuality, rawNeedsDecode: Bool = false) {
        guard sourceCIImage != nil else { return }
        coalescer.enqueue(RenderRequest(
            adjustments: renderAdjustments,
            quality: quality,
            rawNeedsDecode: rawNeedsDecode
        ))
        drainRenders()
    }

    private func drainRenders() {
        guard !isRendering else { return }
        isRendering = true
        Task { [weak self] in
            while let request = self?.coalescer.takeNext() {
                await self?.performRender(request)
            }
            self?.isRendering = false
        }
    }

    private func performRender(_ request: RenderRequest) async {
        guard let source = sourceCIImage else { return }

        let isRAWFile = isRAW
        let url = sourceURL
        let rawSettings = request.adjustments.raw
        let needsDecode = request.rawNeedsDecode && isRAWFile
        let adj = request.adjustments
        let computeHistogram = request.quality == .final
        let computeClipping = request.quality == .final && showClippingWarnings
        let engine = self.engine

        let cachedProxy: SendableCIImage? = needsDecode ? nil : proxy(for: request.quality)
        let tierDimension = dimension(for: request.quality)
        let boxedSource = SendableCIImage(image: source)

        let output: RenderOutput? = await Task.detached(priority: .userInitiated) {
            var root = boxedSource.image
            var decoded: SendableCIImage?
            if needsDecode, let url,
               let redecoded = PhotoSourceLoader.image(at: url, raw: rawSettings, draft: true) {
                root = redecoded
                decoded = SendableCIImage(image: redecoded)
            }
            let proxy = cachedProxy?.image ?? engine.makeProxy(source: root, maxDimension: tierDimension)
            guard let image = engine.renderPreview(proxy: proxy, adjustments: adj) else { return nil }
            let histogram = computeHistogram ? PhotoHistogramEngine.compute(image) : nil
            let clipping = computeClipping ? PhotoClippingOverlay.mask(for: image) : nil
            return RenderOutput(
                preview: SendableCGImage(image: image),
                decodedSource: decoded,
                histogram: histogram,
                clippingMask: clipping.map(SendableCGImage.init)
            )
        }.value

        guard let output else { return }
        previewImage = output.preview.image
        if let decoded = output.decodedSource {
            sourceCIImage = decoded.image
            sourcePixelSize = decoded.image.extent.size
            invalidateProxies()
        }
        if let histogram = output.histogram {
            previewHistogram = histogram
        }
        if computeClipping {
            clippingMask = output.clippingMask?.image
        }
    }

    private struct RenderOutput {
        var preview: SendableCGImage
        var decodedSource: SendableCIImage?
        var histogram: PhotoHistogram?
        var clippingMask: SendableCGImage?
    }

    private func dimension(for quality: RenderQuality) -> CGFloat {
        quality == .final
            ? viewportMaxDimension
            : min(viewportMaxDimension, Self.interactiveMaxDimension)
    }

    /// Lazily builds and caches the downscaled proxy for a quality tier. The proxy CIImage is a
    /// cheap lazy node; caching it keeps the render context's intermediate cache warm across ticks.
    private func proxy(for quality: RenderQuality) -> SendableCIImage? {
        guard let source = sourceCIImage else { return nil }
        if quality == .final {
            if let finalProxy { return finalProxy }
            let built = SendableCIImage(image: engine.makeProxy(source: source, maxDimension: dimension(for: .final)))
            finalProxy = built
            return built
        }
        if let interactiveProxy { return interactiveProxy }
        let built = SendableCIImage(image: engine.makeProxy(source: source, maxDimension: dimension(for: .interactive)))
        interactiveProxy = built
        return built
    }

    private func invalidateProxies() {
        interactiveProxy = nil
        finalProxy = nil
    }

    private func renderOriginalPreviewOffMain() {
        let maxDimension = viewportMaxDimension
        let engine = self.engine
        if isRAW, let url = sourceURL {
            Task { [weak self] in
                let rendered: SendableCGImage? = await Task.detached(priority: .userInitiated) {
                    guard let source = PhotoSourceLoader.image(at: url, raw: .identity, draft: true) else {
                        return nil
                    }
                    guard let image = engine.renderPreview(
                        source: source,
                        adjustments: .identity,
                        maxDimension: maxDimension
                    ) else { return nil }
                    return SendableCGImage(image: image)
                }.value
                guard let rendered else { return }
                self?.originalPreview = rendered.image
            }
            return
        }

        guard let source = sourceCIImage else { return }
        let boxed = SendableCIImage(image: source)
        Task { [weak self] in
            let rendered: SendableCGImage? = await Task.detached(priority: .userInitiated) {
                guard let image = engine.renderPreview(
                    source: boxed.image,
                    adjustments: .identity,
                    maxDimension: maxDimension
                ) else { return nil }
                return SendableCGImage(image: image)
            }.value
            guard let rendered else { return }
            self?.originalPreview = rendered.image
        }
    }

    private func rebuildThumbnails() {
        thumbnailTask?.cancel()
        guard let source = sourceCIImage else {
            presetThumbnails = [:]
            return
        }
        let boxed = SendableCIImage(image: source)
        let engine = self.engine
        thumbnailTask = Task { [weak self] in
            var next: [PhotoPreset: CGImage] = [:]
            for preset in PhotoPreset.allCases {
                guard !Task.isCancelled else { return }
                let rendered: SendableCGImage? = await Task.detached(priority: .utility) {
                    guard let image = engine.thumbnail(source: boxed.image, preset: preset, size: 120) else {
                        return nil
                    }
                    return SendableCGImage(image: image)
                }.value
                if let rendered {
                    next[preset] = rendered.image
                }
            }
            guard !Task.isCancelled else { return }
            self?.presetThumbnails = next
        }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard let url = sourceURL else { return }
        let path = url.standardizedFileURL.path
        let snapshotAdjustments = adjustments
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            _ = self
            await Task.detached(priority: .utility) {
                guard let bookmark = PhotoEditorSessionStore.makeBookmark(for: url) else { return }
                PhotoEditorSessionStore.save(
                    PhotoEditorSessionStore.Snapshot(
                        bookmark: bookmark,
                        adjustments: snapshotAdjustments
                    ),
                    forPath: path
                )
            }.value
        }
    }

    // MARK: - Source loading

    @discardableResult
    private func loadSource(from url: URL, recipe: EditAdjustment) -> Bool {
        isRAW = PhotoRAWSupport.isRAW(url: url)
        guard let image = PhotoSourceLoader.image(at: url, raw: recipe.raw, draft: true) else {
            return false
        }
        sourceURL = url
        sourceCIImage = image
        sourcePixelSize = image.extent.size
        sourceFileName = url.lastPathComponent
        sourceMetadata = Self.loadMetadata(from: url)
        exifSummary = PhotoExifSummary(metadata: sourceMetadata)
        imageInfo = PhotoImageInfo(
            fileURL: url,
            fileSize: (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init),
            metadata: sourceMetadata,
            pixelSize: image.extent.size,
            isRAW: isRAW
        )
        return true
    }

    private func stopSourceAccess() {
        if holdsSourceAccess, let url = sourceURL {
            url.stopAccessingSecurityScopedResource()
        }
        holdsSourceAccess = false
    }

    private static func loadMetadata(from url: URL) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    }
}
