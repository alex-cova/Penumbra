import Foundation
@preconcurrency import AppKit
import Metal
import QuartzCore

/// Encodes glyph/decoration draws into the canvas's render pass. Implemented by `MetalRenderer`.
@MainActor
protocol MetalCanvasGlyphEncoding: AnyObject {
    /// Called inside `MetalTextCanvasView.draw(_:)` with a live encoder whose color attachment is
    /// already cleared to transparent. Must not call `endEncoding` / `present` / `commit`.
    func encode(into encoder: MTLRenderCommandEncoder, drawableSize: CGSize)
    /// Like `encode`, but forces an instance-buffer rebuild first — for offscreen capture, which
    /// may run after an on-screen `draw` already consumed the dirty flag.
    func encodeForCapture(into encoder: MTLRenderCommandEncoder, drawableSize: CGSize)
    /// The canvas left its window (cached / hidden host): release grown instance buffers.
    func hostDidLeaveWindow()
}

/// Transparent `CAMetalLayer` host. When Metal is active `MetalRenderer` paints glyphs here and the
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

    private var isDisplayDirty = false
    private var drawableRetryCount = 0
    private var presentRetryScheduled = false
    private static let maxDrawableRetries = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.isOpaque = false
        // `true` requires presenting inside a CA transaction that is *not*
        // `setDisableActions(true)`. Nested layout transactions swallowed the
        // drawable, leaving a clear canvas (offscreen encode still had glyphs).
        // Present immediately; layout already moved the canvas and carets.
        metalLayer.presentsWithTransaction = false
        return metalLayer
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        presentIfDirty()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Backing scale of the window this canvas is on (not `NSScreen.main`, which would be wrong for
    /// a window on a secondary display). `NSScreen.main` is only the detached-view last resort.
    var effectiveBackingScale: CGFloat {
        window?.backingScaleFactor
            ?? window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    override func setNeedsDisplay() {
        isDisplayDirty = true
        super.setNeedsDisplay()
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        isDisplayDirty = true
        super.setNeedsDisplay(invalidRect)
    }

    /// Encode + present now if a display is pending. AppKit does not reliably call `draw(_:)` on a
    /// view whose backing layer is `CAMetalLayer` (especially under a layer-backed SwiftUI host),
    /// so layout invokes this *after* its disableActions transaction. `presentsWithTransaction`
    /// presents at this method's own CA commit.
    func presentIfDirty() {
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
        if encodePass(on: metalLayer) {
            isDisplayDirty = false
            drawableRetryCount = 0
        } else {
            schedulePresentRetry()
        }
    }

    private func schedulePresentRetry() {
        guard !presentRetryScheduled, drawableRetryCount < Self.maxDrawableRetries else {
            return
        }
        presentRetryScheduled = true
        drawableRetryCount += 1
        DispatchQueue.main.async { [weak self] in
            self?.presentRetryScheduled = false
            self?.presentIfDirty()
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

    /// `NSView.cacheDisplay` of this canvas after a display pass. Requires
    /// `MetalContext.allowsDrawableCapture` to have been set **before** the canvas created its
    /// `CAMetalLayer` (`framebufferOnly = false`). Isolates the presented drawable from the
    /// offscreen encode path in `captureSnapshot()`.
    func capturePresentedLayer() -> NSBitmapImageRep? {
        displayIfNeeded()
        guard bounds.width > 0, bounds.height > 0,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        cacheDisplay(in: bounds, to: rep)
        return rep
    }

    /// Renders the current Metal scene into an offscreen BGRA texture and reads it back — the Metal
    /// glyphs/decorations on a transparent ground, at the canvas's backing scale. For snapshot tests
    /// / PerfHarness only (`CAMetalLayer` content is not captured by `cacheDisplay` unless
    /// `allowsDrawableCapture` was set before the layer was created).
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
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return nil
        }
        glyphEncoder?.encodeForCapture(into: encoder, drawableSize: CGSize(width: width, height: height))
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

private extension MetalTextCanvasView {
    func updateMetalLayerGeometry() {
        guard let metalLayer = layer as? CAMetalLayer else {
            return
        }
        let scale = effectiveBackingScale
        metalLayer.contentsScale = scale
        let width = max(bounds.width * scale, 1)
        let height = max(bounds.height * scale, 1)
        if metalLayer.drawableSize.width != width || metalLayer.drawableSize.height != height {
            metalLayer.drawableSize = CGSize(width: width, height: height)
            drawableRetryCount = 0
        }
    }

    @discardableResult
    func encodePass(on metalLayer: CAMetalLayer) -> Bool {
        let context = MetalContext.shared
        guard let commandQueue = context.commandQueue, let commandBuffer = commandQueue.makeCommandBuffer() else {
            context.markUnavailable(reason: "Failed to create Metal command buffer")
            onRenderingFailure?()
            return false
        }
        guard let drawable = metalLayer.nextDrawable() else {
            return false
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            glyphEncoder?.encode(into: encoder, drawableSize: metalLayer.drawableSize)
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
        } else {
            commandBuffer.waitUntilScheduled()
        }
        return true
    }
}
