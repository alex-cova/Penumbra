@preconcurrency import AppKit
import Metal
import QuartzCore

/// Metal paint backend for the markdown preview. The layout is rasterized with Core Graphics,
/// uploaded to an `MTLTexture`, and blitted into a `CAMetalLayer` drawable.
@MainActor
final class MarkdownPreviewMetalRenderer {
    private let metalView = MarkdownPreviewMetalCanvasView()

    var view: NSView { metalView }

    var isActive: Bool {
        get { !metalView.isHidden }
        set { metalView.isHidden = !newValue }
    }

    func update(
        layout: MarkdownPreviewLayout,
        style: MarkdownPreviewStyle,
        rasterImages: [Int: CGImage],
        highlightedCode: [Int: NSAttributedString] = [:]
    ) {
        let scale = metalView.backingScaleFactor
        let pixelWidth = Int(max(layout.contentSize.width, 1) * scale)
        let pixelHeight = Int(max(layout.contentSize.height, 1) * scale)
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else {
            metalView.contentTexture = nil
            metalView.setNeedsDisplay()
            return
        }

        context.scaleBy(x: scale, y: scale)
        let bounds = CGRect(origin: .zero, size: layout.contentSize)
        MarkdownPreviewCGRenderer.draw(
            layout: layout,
            style: style,
            rasterImages: rasterImages,
            highlightedCode: highlightedCode,
            in: context,
            bounds: bounds
        )

        guard let image = context.makeImage(),
              let device = MetalContext.shared.device,
              let texture = uploadTexture(from: image, device: device) else {
            metalView.contentTexture = nil
            metalView.setNeedsDisplay()
            return
        }

        metalView.contentTexture = texture
        metalView.setNeedsDisplay()
    }

    func clear() {
        metalView.contentTexture = nil
        metalView.setNeedsDisplay()
    }

    private func uploadTexture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = image.width
        let height = image.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
        return texture
    }
}

@MainActor
final class MarkdownPreviewMetalCanvasView: NSView {
    var contentTexture: MTLTexture?

    var backingScaleFactor: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
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
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = backingScaleFactor
        metalLayer.isOpaque = true
        metalLayer.presentsWithTransaction = false
        return metalLayer
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        present()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let metalLayer = layer as? CAMetalLayer {
            let scale = backingScaleFactor
            metalLayer.drawableSize = CGSize(width: max(newSize.width * scale, 1), height: max(newSize.height * scale, 1))
        }
        setNeedsDisplay()
    }

    func setNeedsDisplay() {
        needsDisplay = true
    }

    private func present() {
        guard MetalContext.shared.isAvailable,
              let metalLayer = layer as? CAMetalLayer,
              let source = contentTexture,
              let drawable = metalLayer.nextDrawable(),
              let commandQueue = MetalContext.shared.commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let destWidth = min(source.width, drawable.texture.width)
        let destHeight = min(source.height, drawable.texture.height)
        guard destWidth > 0, destHeight > 0 else { return }

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: source,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: destWidth, height: destHeight, depth: 1),
                to: drawable.texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
