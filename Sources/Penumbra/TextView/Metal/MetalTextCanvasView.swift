import EditorIntelligence
import Foundation
@preconcurrency import AppKit
import Metal
import QuartzCore

/// Encodes glyph/decoration draws into the canvas's render pass. Implemented by `MetalRenderer`.
@MainActor
protocol MetalCanvasGlyphEncoding: AnyObject {
    /// Called inside `MetalTextCanvasView.draw(_:)` with a live encoder whose color attachment is
    /// already cleared to the opaque editor background. Must not call `endEncoding` / `present` / `commit`.
    func encode(
        into encoder: MTLRenderCommandEncoder,
        commandBuffer: MTLCommandBuffer,
        drawableSize: CGSize
    )
    /// Like `encode`, but forces an instance-buffer rebuild first — for offscreen capture, which
    /// may run after an on-screen `draw` already consumed the dirty flag.
    func encodeForCapture(
        into encoder: MTLRenderCommandEncoder,
        commandBuffer: MTLCommandBuffer,
        drawableSize: CGSize
    )
    /// The canvas left its window (cached / hidden host): release grown instance buffers.
    func hostDidLeaveWindow()
    /// Returns whether every instance-buffer slot this frame will write is free. Checked before
    /// `nextDrawable()` on the display-link path.
    func canAcquireWriteSlots() -> Bool
    /// Bumped after a successful on-screen present commit.
    var paintGeneration: UInt64 { get }
    func notePaintCommitted()
}

/// Opaque `CAMetalLayer` host. When Metal is active `MetalRenderer` paints editor chrome and glyphs here and the
/// `LineFragmentView`s are gone; when it is inactive the canvas is hidden and only clears.
///
/// `draw(_:)` is the only place that calls `nextDrawable()`. Layout updates CPU state and
/// `setNeedsDisplay()` so a flick-scroll cannot present faster than vsync.
final class MetalTextCanvasView: UIView {
    var onRenderingFailure: (() -> Void)?
    /// Set by `MetalRenderer` when it becomes the active paint backend; cleared when it steps down.
    weak var glyphEncoder: MetalCanvasGlyphEncoding?
    /// Non-zero alpha texels in the last on-screen drawable, filled when drawable capture is on.
    private(set) var debugPresentedAlphaPixels = 0
    /// CPU copy of the last drawable submitted for presentation. Populated only in capture mode.
    private var lastPresentedImage: NSBitmapImageRep?

    private var isDisplayDirty = false
    private var drawableRetryCount = 0
    private var presentRetryScheduled = false
    private var deferredPresentScheduled = false
    private var opaqueClearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
    /// Non-zero while `withCoalescedPresent` is running. A layout pass fires several
    /// `setNeedsDisplay`-triggering calls (`setViewport`, each `upsertFragment`) before its own
    /// explicit present; suppressing the deferred present while nested keeps a half-updated pass
    /// from ever being what a stray async present encodes.
    private var presentCoalescingDepth = 0
    private static let maxDrawableRetries = 3
    private static let maxDeferredPresentFrames = 30
    private var deferredPresentFrameCount = 0
    private var displayLink: CADisplayLink?
    private let displayLinkProxy = MetalDisplayLinkProxy()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        displayLinkProxy.canvas = self
        isUserInteractionEnabled = false
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
        wantsLayer = true
        // AppKit must not try to `draw(_:)` into a `CAMetalLayer` — that path installs a
        // CG context which clears the presented drawable (blank editor, offscreen encode still
        // has glyphs). Layout / `updateLayer` present instead.
        layerContentsRedrawPolicy = .never
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = MetalContext.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = !MetalContext.shared.allowsDrawableCapture
        metalLayer.contentsScale = effectiveBackingScale
        let scale = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(
            width: max(bounds.width * scale, 1),
            height: max(bounds.height * scale, 1)
        )
        metalLayer.colorspace = effectiveColorSpace.cgColorSpace
        metalLayer.isOpaque = true
        // `true` requires presenting inside a CA transaction that is *not*
        // `setDisableActions(true)`. Nested layout transactions swallowed the
        // drawable, leaving a clear canvas (offscreen encode still had glyphs).
        // Present immediately; layout already moved the canvas and carets.
        metalLayer.presentsWithTransaction = false
        return metalLayer
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        if usesDeferredPresent {
            armDisplayLink()
        } else {
            presentIfDirtyNow()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func setOpaqueBackgroundColor(
        _ color: NSColor,
        appearance: NSAppearance?,
        colorSpace: NSColorSpace
    ) {
        let premultiplied = MetalColor.premultiplied(
            color,
            appearance: appearance,
            colorSpace: colorSpace
        )
        let alpha = max(premultiplied.w, 0.0001)
        let updated = MTLClearColor(
            red: Double(premultiplied.x / alpha),
            green: Double(premultiplied.y / alpha),
            blue: Double(premultiplied.z / alpha),
            alpha: 1
        )
        guard updated.red != opaqueClearColor.red
                || updated.green != opaqueClearColor.green
                || updated.blue != opaqueClearColor.blue else {
            return
        }
        opaqueClearColor = updated
        setNeedsDisplay()
    }

    /// Backing scale of the window this canvas is on (not `NSScreen.main`, which would be wrong for
    /// a window on a secondary display). `NSScreen.main` is only the detached-view last resort.
    var effectiveBackingScale: CGFloat {
        window?.backingScaleFactor
            ?? window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    var effectiveColorSpace: NSColorSpace {
        if let windowColorSpace = window?.colorSpace {
            return windowColorSpace
        }
        return window?.screen?.colorSpace ?? .sRGB
    }

    override func setNeedsDisplay() {
        isDisplayDirty = true
        super.setNeedsDisplay()
        scheduleDeferredPresentIfNeeded()
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        isDisplayDirty = true
        super.setNeedsDisplay(invalidRect)
        scheduleDeferredPresentIfNeeded()
    }

    /// Encode + present now if a display is pending, or arm the display link when deferred present
    /// is enabled. AppKit does not reliably call `draw(_:)` on a view whose backing layer is
    /// `CAMetalLayer` (especially under a layer-backed SwiftUI host), so layout invokes this
    /// *after* its disableActions transaction.
    ///
    /// `immediately` bypasses deferred present. A scroll moves the line-number views and the
    /// scroller in the current CA transaction; a display-link present would show the text a frame
    /// (or, with a busy main thread, several) behind them.
    func presentIfDirty(immediately: Bool = false) {
        if usesDeferredPresent, !immediately {
            armDisplayLink()
        } else {
            presentIfDirtyNow()
        }
    }

    /// Arms a vsync-aligned present without encoding on the calling thread.
    func armDisplayLink() {
        guard isDisplayDirty else {
            pauseDisplayLinkIfIdle()
            return
        }
        ensureDisplayLink()
        displayLink?.isPaused = false
    }

    /// Synchronous encode + present. Used when deferred present is off and for readback capture.
    func presentIfDirtyNow() {
        guard window != nil, !isHidden, isDisplayDirty else {
            return
        }
        guard let metalLayer = layer as? CAMetalLayer else {
            return
        }
        updateMetalLayerGeometry()
        guard bounds.width > 0, bounds.height > 0,
              metalLayer.drawableSize.width > 1, metalLayer.drawableSize.height > 1 else {
            schedulePresentRetry()
            return
        }
        guard MetalContext.shared.isAvailable else {
            onRenderingFailure?()
            return
        }
        let waitForReadback = MetalContext.shared.allowsDrawableCapture
        if encodePass(on: metalLayer, waitForReadback: waitForReadback) {
            PenumbraSignposts.event("MetalCanvas.presented")
            if EditorPerformanceTrace.shared.isEnabled {
                EditorPerformanceTrace.shared.recordCount(.metalPresents, count: 1)
            }
            isDisplayDirty = false
            drawableRetryCount = 0
            deferredPresentFrameCount = 0
            pauseDisplayLinkIfIdle()
        } else {
            PenumbraSignposts.event("MetalCanvas.presentRetry")
            schedulePresentRetry()
        }
    }

    private func schedulePresentRetry() {
        guard !presentRetryScheduled, drawableRetryCount < Self.maxDrawableRetries else {
            if usesDeferredPresent, deferredPresentFrameCount >= Self.maxDeferredPresentFrames {
                onRenderingFailure?()
            }
            return
        }
        presentRetryScheduled = true
        drawableRetryCount += 1
        if usesDeferredPresent {
            deferredPresentFrameCount += 1
            presentRetryScheduled = false
            armDisplayLink()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.presentRetryScheduled = false
                self?.presentIfDirtyNow()
            }
        }
    }

    /// `layerContentsRedrawPolicy = .never` does not drive `updateLayer` on its own. Layout
    /// presents synchronously when it runs; this coalesced retry covers edits where only
    /// `setNeedsDisplay` fired and no parent layout pass reached `presentIfDirty`.
    private func scheduleDeferredPresentIfNeeded() {
        guard presentCoalescingDepth == 0, !deferredPresentScheduled else {
            return
        }
        if usesDeferredPresent {
            armDisplayLink()
            return
        }
        deferredPresentScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.deferredPresentScheduled = false
            self.presentIfDirtyNow()
        }
    }

    /// Runs `body`, suppressing any deferred present it triggers via `setNeedsDisplay` until it
    /// returns, then presents once with the pass's final state. Reentrant (a depth counter, not a
    /// `Bool`) since a layout pass can itself invoke another paint-affecting call.
    func withCoalescedPresent(immediately: Bool = false, _ body: () -> Void) {
        presentCoalescingDepth += 1
        body()
        presentCoalescingDepth -= 1
        if presentCoalescingDepth == 0 {
            presentIfDirty(immediately: immediately)
        }
    }

    func handleDisplayLink() {
        guard presentCoalescingDepth == 0 else {
            return
        }
        guard window != nil, !isHidden, isDisplayDirty else {
            pauseDisplayLinkIfIdle()
            return
        }
        guard let metalLayer = layer as? CAMetalLayer else {
            return
        }
        updateMetalLayerGeometry()
        guard bounds.width > 0, bounds.height > 0,
              metalLayer.drawableSize.width > 1, metalLayer.drawableSize.height > 1 else {
            return
        }
        guard MetalContext.shared.isAvailable else {
            onRenderingFailure?()
            return
        }
        guard glyphEncoder?.canAcquireWriteSlots() ?? true else {
            return
        }
        let waitForReadback = MetalContext.shared.allowsDrawableCapture
        if encodePass(on: metalLayer, waitForReadback: waitForReadback) {
            PenumbraSignposts.event("MetalCanvas.presented")
            if EditorPerformanceTrace.shared.isEnabled {
                EditorPerformanceTrace.shared.recordCount(.metalPresents, count: 1)
            }
            isDisplayDirty = false
            drawableRetryCount = 0
            deferredPresentFrameCount = 0
            glyphEncoder?.notePaintCommitted()
            pauseDisplayLinkIfIdle()
        } else {
            PenumbraSignposts.event("MetalCanvas.presentRetry")
            deferredPresentFrameCount += 1
            if deferredPresentFrameCount >= Self.maxDeferredPresentFrames {
                onRenderingFailure?()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateMetalLayerGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            // Off-screen (workbench tab switch, EditorHostCache): stop presenting and shrink the
            // grown instance buffers back to their start size.
            invalidateDisplayLink()
            glyphEncoder?.hostDidLeaveWindow()
            return
        }
        updateMetalLayerGeometry()
        if !isHidden {
            setNeedsDisplay()
            // Defer until after the hosting layout pass has given the canvas a real
            // frame. Presenting at drawableSize 1×1 here would commit a clear-only
            // drawable and (previously) drop `needsInstanceRebuild`.
            DispatchQueue.main.async { [weak self] in
                self?.presentIfDirty()
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMetalLayerGeometry()
        if !isHidden {
            setNeedsDisplay()
            DispatchQueue.main.async { [weak self] in
                self?.presentIfDirty()
            }
        }
    }

    /// CPU copy of the last drawable submitted by `encodePass`. Requires
    /// `MetalContext.allowsDrawableCapture` to have been set **before** the canvas created its
    /// `CAMetalLayer` (`framebufferOnly = false`). `NSView.cacheDisplay` does not reliably include
    /// CAMetalLayer contents, so returning the present command buffer's own readback is the only
    /// dependable way to observe the frame users were shown.
    func capturePresentedLayer() -> NSBitmapImageRep? {
        displayIfNeeded()
        presentIfDirtyNow()
        return lastPresentedImage
    }

    /// Renders the current opaque Metal scene into an offscreen BGRA texture and reads it back at
    /// the canvas's backing scale. For snapshot tests / PerfHarness only.
    func captureSnapshot() -> NSBitmapImageRep? {
        let context = MetalContext.shared
        guard context.isAvailable,
              let device = context.device,
              let queue = context.commandQueue else {
            return nil
        }
        let scale = effectiveBackingScale
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0 else {
            return nil
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let bytesPerRow = width * 4
        guard let target = device.makeTexture(descriptor: descriptor),
              let readback = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared) else {
            return nil
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = opaqueClearColor
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return nil
        }
        glyphEncoder?.encodeForCapture(
            into: encoder,
            commandBuffer: commandBuffer,
            drawableSize: CGSize(width: width, height: height)
        )
        encoder.endEncoding()
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        blit.copy(
            from: target,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: readback,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: bytesPerRow,
            bitsPerPixel: 32
        ), let pixels = rep.bitmapData else {
            return nil
        }
        memcpy(pixels, readback.contents(), bytesPerRow * height)
        // Texture is BGRA; NSBitmapImageRep above is RGBA. Swap R/B in place.
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            pixels.advanced(by: index).pointee ^= pixels.advanced(by: index + 2).pointee
            pixels.advanced(by: index + 2).pointee ^= pixels.advanced(by: index).pointee
            pixels.advanced(by: index).pointee ^= pixels.advanced(by: index + 2).pointee
        }
        return rep
    }
}

@MainActor
private final class MetalDisplayLinkProxy: NSObject {
    weak var canvas: MetalTextCanvasView?

    @objc func displayLinkFired(_ link: CADisplayLink) {
        canvas?.handleDisplayLink()
    }
}

private extension MetalTextCanvasView {
    var usesDeferredPresent: Bool {
        MetalDeferredPresent.resolved(
            defaults: UserDefaults.standard.object(forKey: MetalDeferredPresent.defaultsKey) as? Bool
        )
    }

    func ensureDisplayLink() {
        guard displayLink == nil else {
            return
        }
        let link = displayLink(target: displayLinkProxy, selector: #selector(MetalDisplayLinkProxy.displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        displayLink = link
    }

    func invalidateDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func pauseDisplayLinkIfIdle() {
        displayLink?.isPaused = true
    }

    func updateMetalLayerGeometry() {
        guard let metalLayer = layer as? CAMetalLayer else {
            return
        }
        let scale = effectiveBackingScale
        metalLayer.colorspace = effectiveColorSpace.cgColorSpace
        metalLayer.contentsScale = scale
        let width = max(bounds.width * scale, 1)
        let height = max(bounds.height * scale, 1)
        if metalLayer.drawableSize.width != width || metalLayer.drawableSize.height != height {
            metalLayer.drawableSize = CGSize(width: width, height: height)
            drawableRetryCount = 0
        }
    }

    @discardableResult
    func encodePass(on metalLayer: CAMetalLayer, waitForReadback: Bool) -> Bool {
        PenumbraSignposts.event("MetalCanvas.encodeStarted")
        let context = MetalContext.shared
        guard let commandQueue = context.commandQueue, let commandBuffer = commandQueue.makeCommandBuffer() else {
            context.markUnavailable(reason: "Failed to create Metal command buffer")
            onRenderingFailure?()
            return false
        }
        guard let drawable = metalLayer.nextDrawable() else {
            return false
        }
        if KeystrokeBudgetMetrics.observerPending {
            KeystrokeBudgetMetrics.recordNextDrawableBeforeObserver()
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = opaqueClearColor
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            glyphEncoder?.encode(
                into: encoder,
                commandBuffer: commandBuffer,
                drawableSize: metalLayer.drawableSize
            )
            encoder.endEncoding()
        } else {
            // Still present so CAMetalLayer's drawable pool is released, then fall back.
            context.markUnavailable(reason: "Failed to create Metal render command encoder")
            commandBuffer.present(drawable)
            commandBuffer.commit()
            commandBuffer.waitUntilScheduled()
            onRenderingFailure?()
            return false
        }
        let captureBuffer: MTLBuffer?
        let captureBytesPerRow: Int
        if MetalContext.shared.allowsDrawableCapture {
            let width = drawable.texture.width
            let height = drawable.texture.height
            captureBytesPerRow = width * 4
            captureBuffer = context.device?.makeBuffer(length: captureBytesPerRow * height, options: .storageModeShared)
            if let captureBuffer, let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(
                    from: drawable.texture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: width, height: height, depth: 1),
                    to: captureBuffer,
                    destinationOffset: 0,
                    destinationBytesPerRow: captureBytesPerRow,
                    destinationBytesPerImage: captureBytesPerRow * height
                )
                blit.endEncoding()
            }
        } else {
            captureBuffer = nil
            captureBytesPerRow = 0
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        if let captureBuffer {
            commandBuffer.waitUntilCompleted()
            let pixels = captureBuffer.contents().bindMemory(to: UInt8.self, capacity: captureBuffer.length)
            var painted = 0
            for index in stride(from: 3, to: captureBuffer.length, by: 4) where pixels[index] != 0 {
                painted += 1
            }
            debugPresentedAlphaPixels = painted
            lastPresentedImage = makePresentedImage(
                pixels: pixels,
                width: drawable.texture.width,
                height: drawable.texture.height,
                bytesPerRow: captureBytesPerRow
            )
        } else if waitForReadback {
            commandBuffer.waitUntilCompleted()
        } else if !usesDeferredPresent {
            PenumbraSignposts.event("MetalCanvas.waitUntilScheduled")
            if EditorPerformanceTrace.shared.isEnabled {
                EditorPerformanceTrace.shared.recordCount(.metalWaits, count: 1)
            }
            commandBuffer.waitUntilScheduled()
        }
        return true
    }

    func makePresentedImage(
        pixels: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: bytesPerRow,
            bitsPerPixel: 32
        ), let destination = rep.bitmapData else {
            return nil
        }
        memcpy(destination, pixels, bytesPerRow * height)
        // The drawable is BGRA while NSBitmapImageRep above exposes RGBA.
        for index in stride(from: 0, to: bytesPerRow * height, by: 4) {
            destination.advanced(by: index).pointee ^= destination.advanced(by: index + 2).pointee
            destination.advanced(by: index + 2).pointee ^= destination.advanced(by: index).pointee
            destination.advanced(by: index).pointee ^= destination.advanced(by: index + 2).pointee
        }
        return rep
    }
}
