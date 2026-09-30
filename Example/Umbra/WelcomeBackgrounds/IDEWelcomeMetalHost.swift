import MetalKit
import SwiftUI

/// Shared `MTKView` host for welcome-page fragment shaders. Renders at 1 drawable pixel
/// per point and 30 fps; holds still under Reduce Motion and while the window is inactive.
struct IDEWelcomeMetalShaderView<Renderer: IDEWelcomeMetalRenderer>: View {
    let parallax: IDEWelcomeParallax
    let isPaused: Bool
    let makeRenderer: () -> Renderer?

    var body: some View {
        IDEWelcomeMetalRepresentable(parallax: parallax, isPaused: isPaused, makeRenderer: makeRenderer)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

@MainActor
protocol IDEWelcomeMetalRenderer: NSObject, MTKViewDelegate {
    var parallax: IDEWelcomeParallax? { get set }
    var device: MTLDevice { get }
}

private struct IDEWelcomeMetalRepresentable<Renderer: IDEWelcomeMetalRenderer>: NSViewRepresentable {
    let parallax: IDEWelcomeParallax
    let isPaused: Bool
    let makeRenderer: () -> Renderer?

    func makeCoordinator() -> Renderer? {
        makeRenderer()
    }

    func makeNSView(context: Context) -> IDEWelcomeMetalMTKView {
        let view = IDEWelcomeMetalMTKView()
        guard let renderer = context.coordinator else { return view }
        renderer.parallax = parallax
        view.device = renderer.device
        view.delegate = renderer
        view.setPaused(isPaused)
        return view
    }

    func updateNSView(_ view: IDEWelcomeMetalMTKView, context: Context) {
        context.coordinator?.parallax = parallax
        view.setPaused(isPaused)
    }
}

final class IDEWelcomeMetalMTKView: MTKView {
    init() {
        super.init(frame: .zero, device: nil)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        autoResizeDrawable = false
        preferredFramesPerSecond = 30
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let size = CGSize(width: max(bounds.width, 1), height: max(bounds.height, 1))
        if drawableSize != size { drawableSize = size }
        if isPaused { needsDisplay = true }
    }

    func setPaused(_ paused: Bool) {
        enableSetNeedsDisplay = paused
        isPaused = paused
        if paused { needsDisplay = true }
    }
}

enum IDEWelcomeMetalTiming {
    static func advance(
        elapsed: inout Double,
        lastFrame: inout CFTimeInterval?,
        paused: Bool,
        now: CFTimeInterval = CACurrentMediaTime()
    ) -> Double {
        if !paused, let lastFrame {
            elapsed += min(max(now - lastFrame, 0), 0.1)
        }
        lastFrame = paused ? nil : now
        return elapsed
    }
}

@MainActor
enum IDEWelcomeMetalPointer {
    /// Normalized 0…1 from the top-left, matching React Bits mouse uniforms.
    static func normalized(
        parallax: IDEWelcomeParallax?,
        paused: Bool,
        now: CFTimeInterval,
        size: CGSize
    ) -> SIMD2<Float> {
        guard let parallax else { return SIMD2(0.5, 0.5) }
        let tilt = paused ? parallax.current : parallax.advance(to: now, in: size)
        return SIMD2(
            Float((tilt.dx + 1) * 0.5),
            Float((1 - tilt.dy) * 0.5)
        )
    }

    static func activeFactor(parallax: IDEWelcomeParallax?) -> Float {
        parallax?.pointer == nil ? 0 : 1
    }
}

enum IDEWelcomeShaderPipelines {
    nonisolated(unsafe) private static var cache: [String: MTLRenderPipelineState] = [:]

    static func pipeline(
        device: MTLDevice,
        fragmentName: String,
        librarySource: String,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        blendEnabled: Bool = false
    ) -> MTLRenderPipelineState? {
        if let cached = cache[fragmentName] { return cached }
        guard let library = try? device.makeLibrary(source: librarySource, options: nil),
              let vertex = library.makeFunction(name: "welcomeVertex"),
              let fragment = library.makeFunction(name: fragmentName)
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        if blendEnabled {
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        cache[fragmentName] = pipeline
        return pipeline
    }
}

/// Procedural noise used by Evil Eye (ported from React Bits `generateNoiseTexture`).
func IDEWelcomeMakeNoiseTexture(device: MTLDevice, size: Int = 256) -> MTLTexture? {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm,
        width: size,
        height: size,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

    var data = [UInt8](repeating: 0, count: size * size * 4)
    func hash(_ x: Int, _ y: Int, _ seed: Int) -> Double {
        // Mirrors React Bits `Math.imul` — 32-bit wrap, not trapping Int multiply.
        var n = UInt32(bitPattern: Int32(truncatingIfNeeded: x * 374_761_393 + y * 668_265_263 + seed * 1_274_126_177))
        n = (n ^ (n >> 13)) &* 1_274_126_177
        n ^= n >> 16
        return Double(n) / 4_294_967_296.0
    }
    func noise(px: Int, py: Int, freq: Int, seed: Int) -> Double {
        let fx = Double(px) / Double(size) * Double(freq)
        let fy = Double(py) / Double(size) * Double(freq)
        let ix = Int(floor(fx))
        let iy = Int(floor(fy))
        let tx = fx - Double(ix)
        let ty = fy - Double(iy)
        let w = freq
        let v00 = hash(((ix % w) + w) % w, ((iy % w) + w) % w, seed)
        let v10 = hash((((ix + 1) % w) + w) % w, ((iy % w) + w) % w, seed)
        let v01 = hash(((ix % w) + w) % w, (((iy + 1) % w) + w) % w, seed)
        let v11 = hash((((ix + 1) % w) + w) % w, (((iy + 1) % w) + w) % w, seed)
        return v00 * (1 - tx) * (1 - ty) + v10 * tx * (1 - ty) + v01 * (1 - tx) * ty + v11 * tx * ty
    }

    for y in 0..<size {
        for x in 0..<size {
            var value = 0.0
            var amp = 0.4
            var totalAmp = 0.0
            for o in 0..<8 {
                let f = 32 * (1 << o)
                value += amp * noise(px: x, py: y, freq: f, seed: o * 31)
                totalAmp += amp
                amp *= 0.65
            }
            value /= totalAmp
            value = (value - 0.5) * 2.2 + 0.5
            value = min(max(value, 0), 1)
            let byte = UInt8(value * 255)
            let index = (y * size + x) * 4
            data[index] = byte
            data[index + 1] = byte
            data[index + 2] = byte
            data[index + 3] = 255
        }
    }
    data.withUnsafeBytes { bytes in
        texture.replace(
            region: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0,
            withBytes: bytes.baseAddress!,
            bytesPerRow: size * 4
        )
    }
    return texture
}
