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

    private var isDisplayDirty = false
    private var drawableRetryCount = 0
    private var presentRetryScheduled = false
    private static let maxDrawableRetries = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isUserInteractionEnabled = false
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        wantsLayer = true
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
        metalLayer.drawableSize = CGSize(
            width: bounds.width * metalLayer.contentsScale,
            height: bounds.height * metalLayer.contentsScale
        )
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.isOpaque = false
        metalLayer.presentsWithTransaction = true
        return metalLayer
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
    /// so layout must invoke this inside its `CATransaction` — `presentsWithTransaction` presents
    /// at that commit.
    func presentIfDirty() {
        guard window != nil, !isHidden, isDisplayDirty else {
            return
        }
        guard let metalLayer = layer as? CAMetalLayer else {
            return
        }
        updateMetalLayerGeometry()
        guard metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0 else {
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
            presentIfDirty()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMetalLayerGeometry()
        if !isHidden {
            setNeedsDisplay()
            presentIfDirty()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        presentIfDirty()
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
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
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
        commandBuffer.present(drawable)
        commandBuffer.commit()
        // presentsWithTransaction presents at CA commit; the GPU must have the buffer first.
        commandBuffer.waitUntilScheduled()
        return true
    }
}
