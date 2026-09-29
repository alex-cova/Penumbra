import MetalKit
import SwiftUI

/// A procedural view of deep space behind the welcome page, drawn by an `MTKView`: a
/// Milky Way band with dust lanes, a domain-warped nebula, and four star layers (colored
/// by temperature, the brightest with diffraction spikes). Every layer sits at its own
/// depth, so the pointer shifts them by different amounts (parallax), and each drifts at
/// its own speed. Renders at one drawable pixel per point and 30 fps; holds still under
/// Reduce Motion and while the window isn't active.
struct IDEWelcomeDeepSpace: View {
    let parallax: IDEWelcomeParallax
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        IDEDeepSpaceMetalView(
            parallax: parallax,
            isPaused: reduceMotion || controlActiveState == .inactive
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct IDEDeepSpaceMetalView: NSViewRepresentable {
    let parallax: IDEWelcomeParallax
    let isPaused: Bool

    func makeCoordinator() -> IDEDeepSpaceRenderer? {
        IDEDeepSpaceRenderer()
    }

    func makeNSView(context: Context) -> IDEDeepSpaceMTKView {
        let view = IDEDeepSpaceMTKView()
        guard let renderer = context.coordinator else { return view }
        renderer.parallax = parallax
        view.device = renderer.device
        view.delegate = renderer
        view.setPaused(isPaused)
        return view
    }

    func updateNSView(_ view: IDEDeepSpaceMTKView, context: Context) {
        context.coordinator?.parallax = parallax
        view.setPaused(isPaused)
    }
}

final class IDEDeepSpaceMTKView: MTKView {
    /// Drawable pixels per point.
    private static let renderScale: CGFloat = 1

    init() {
        super.init(frame: .zero, device: nil)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        autoResizeDrawable = false
        preferredFramesPerSecond = 30
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        let size = CGSize(
            width: max(bounds.width * Self.renderScale, 1),
            height: max(bounds.height * Self.renderScale, 1)
        )
        if drawableSize != size { drawableSize = size }
        if isPaused { needsDisplay = true }
    }

    /// A paused view redraws only on demand, so a resize still paints one frame.
    func setPaused(_ paused: Bool) {
        enableSetNeedsDisplay = paused
        isPaused = paused
        if paused { needsDisplay = true }
    }
}

@MainActor
final class IDEDeepSpaceRenderer: NSObject, MTKViewDelegate {
    /// Mirrors `Uniforms` in the shader.
    private struct Uniforms {
        var resolution: SIMD2<Float>
        var tilt: SIMD2<Float>
        var time: Float
        var padding: Float = 0
    }

    let device: MTLDevice
    var parallax: IDEWelcomeParallax?
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var elapsed: Double = 0
    private var lastFrame: CFTimeInterval?

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard
            let device,
            let queue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "deepSpaceVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "deepSpaceFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let pass = view.currentRenderPassDescriptor,
            let buffer = queue.makeCommandBuffer(),
            let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        // Time only moves while frames are being asked for, so pausing freezes the scene.
        let now = CACurrentMediaTime()
        let paused = view.isPaused
        if !paused, let lastFrame {
            elapsed += min(max(now - lastFrame, 0), 0.1)
        }
        lastFrame = paused ? nil : now

        var tilt = CGVector.zero
        if let parallax {
            tilt = paused ? parallax.current : parallax.advance(to: now, in: view.bounds.size)
        }
        let size = view.drawableSize
        var uniforms = Uniforms(
            resolution: SIMD2(Float(size.width), Float(size.height)),
            tilt: SIMD2(Float(tilt.dx), Float(tilt.dy)),
            time: Float(elapsed)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    // Everything is in drawable pixels with y down, so star sizes don't depend on the
    // window. `tilt` is the eased pointer position (-1...1); a layer samples at
    // `frag + tilt * depth`, so nearer layers slide further against the pointer.
    // Each layer is an endless hashed grid, one candidate star per cell, and drifts on
    // its own. No texture: the nebula is hashed value noise, so nothing tiles.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 resolution;
        float2 tilt;
        float time;
        float padding;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut deepSpaceVertex(uint id [[vertex_id]]) {
        float2 corner = float2((id << 1) & 2, id & 2);
        VertexOut out;
        out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(corner.x, 1.0 - corner.y);
        return out;
    }

    static float hash21(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    static float2 hash22(float2 p) {
        float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.xx + p3.yz) * p3.zy);
    }

    static float valueNoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(
            mix(hash21(i), hash21(i + float2(1.0, 0.0)), u.x),
            mix(hash21(i + float2(0.0, 1.0)), hash21(i + float2(1.0, 1.0)), u.x),
            u.y
        );
    }

    static float fbm(float2 p, int octaves) {
        const float2x2 turn = float2x2(float2(0.8, 0.6), float2(-0.6, 0.8));
        float sum = 0.0;
        float amplitude = 0.5;
        for (int i = 0; i < octaves; ++i) {
            sum += amplitude * valueNoise(p);
            p = turn * p * 2.03 + float2(17.1, 9.2);
            amplitude *= 0.5;
        }
        return sum;
    }

    // Blackbody-ish: blue-white, white, yellow, orange.
    static float3 starColor(float t) {
        float3 c = mix(float3(0.62, 0.74, 1.0), float3(1.0, 0.96, 0.9), smoothstep(0.0, 0.45, t));
        c = mix(c, float3(1.0, 0.82, 0.55), smoothstep(0.5, 0.8, t));
        return mix(c, float3(1.0, 0.58, 0.36), smoothstep(0.85, 1.0, t));
    }

    // One depth layer of stars. `reach` is how many neighbouring cells can spill into this
    // pixel (0 for pinpoints, 1 when there is a halo or spikes).
    static float3 starLayer(
        float2 p, float cell, float density, float radius, float gain,
        float seed, float time, int reach, float spikeLength
    ) {
        float2 id = floor(p / cell);
        float3 acc = float3(0.0);
        for (int dy = -reach; dy <= reach; ++dy) {
            for (int dx = -reach; dx <= reach; ++dx) {
                float2 c = id + float2(dx, dy);
                float2 s = c + seed;
                if (hash21(s) > density) continue;
                float2 h2 = hash22(s * 1.37 + 11.0);
                float2 d = p - (c + 0.15 + 0.7 * h2) * cell;
                // Few bright stars, many faint ones.
                float mag = pow(hash21(s * 2.11 + 3.0), 2.5);
                float b = gain * (0.25 + 0.75 * mag);
                float rr = radius * (0.7 + 0.8 * mag);
                float dist = length(d);
                float shape = exp(-dist * dist / (rr * rr)) + 0.18 * exp(-dist / (rr * 3.5));
                if (spikeLength > 0.0 && mag > 0.2) {
                    float2 a = abs(d);
                    float len = spikeLength * (0.4 + mag);
                    shape += 0.9 * mag * (exp(-a.y / 0.55) * exp(-a.x / len) + exp(-a.x / 0.55) * exp(-a.y / len));
                }
                float shimmer = 1.0 + 0.06 * sin(time * (0.8 + 2.5 * h2.x) + h2.y * 60.0);
                acc += starColor(hash21(s * 3.7 + 7.0)) * b * shimmer * shape;
            }
        }
        return acc;
    }

    fragment float4 deepSpaceFragment(
        VertexOut in [[stage_in]],
        constant Uniforms &u [[buffer(0)]]
    ) {
        float2 res = u.resolution;
        float2 frag = in.uv * res;
        float t = u.time;

        // Milky Way: a tilted band, patchy, with dark dust lanes cut through it.
        float2 bp = (frag + u.tilt * 3.0 - res * 0.5) / res.y;
        bp = float2(cos(-0.42) * bp.x - sin(-0.42) * bp.y, sin(-0.42) * bp.x + cos(-0.42) * bp.y);
        float bandCore = exp(-bp.y * bp.y / 0.045);
        float bandDensity = bandCore * (0.35 + 0.9 * fbm(bp * float2(3.0, 9.0) + 1.3 + t * 0.002, 5));
        float lanes = smoothstep(0.52, 0.72, fbm(bp * float2(4.0, 11.0) + 8.0, 4)) * bandCore;
        float3 band = mix(float3(0.55, 0.6, 0.85), float3(1.0, 0.8, 0.6), bandCore * bandCore)
            * bandDensity * 0.2 * (1.0 - 0.85 * lanes);

        // Nebula: fbm warped by fbm, in blue, magenta and teal, confined to regions so
        // most of the sky stays empty.
        float2 n = (frag + u.tilt * 8.0) / res.y * 1.6 + float2(t * 0.004, -t * 0.002);
        float2 q = float2(fbm(n, 4), fbm(n + float2(5.2, 1.3), 4));
        float2 r = float2(
            fbm(n + 3.5 * q + float2(1.7, 9.2) + t * 0.01, 4),
            fbm(n + 3.5 * q + float2(8.3, 2.8) - t * 0.008, 4)
        );
        float f = fbm(n + 3.5 * r, 5);
        float region = smoothstep(0.42, 0.72, fbm(n * 0.45 + 20.0, 3));
        float body = pow(smoothstep(0.3, 0.85, f), 2.0);
        float3 hue = mix(float3(0.10, 0.20, 0.55), float3(0.55, 0.12, 0.40), smoothstep(0.3, 0.8, r.x));
        hue = mix(hue, float3(0.05, 0.45, 0.50), smoothstep(0.5, 0.9, r.y) * 0.6);
        float3 nebula = hue * body * (0.12 + 0.55 * region) * 1.4;

        float3 col = float3(0.004, 0.005, 0.012) + nebula + band;

        // Stars, far to near. The band packs the far ones tighter; dust dims them.
        float crowd = 1.0 + 2.2 * bandCore * (1.0 - lanes);
        float veil = 1.0 - 0.7 * lanes;
        col += veil * starLayer(frag + u.tilt * 4.0 + float2(0.4, 0.14) * t, 14.0, min(0.16 * crowd, 0.6), 0.55, 0.5, 0.0, t, 0, 0.0);
        col += veil * starLayer(frag + u.tilt * 10.0 + float2(1.0, 0.35) * t, 40.0, min(0.25 * crowd, 0.7), 0.8, 0.75, 31.0, t, 1, 0.0);
        col += starLayer(frag + u.tilt * 22.0 + float2(2.0, 0.7) * t, 110.0, 0.3, 1.1, 1.0, 57.0, t, 1, 0.0);
        col += starLayer(frag + u.tilt * 40.0 + float2(3.5, 1.2) * t, 300.0, 0.5, 1.6, 1.8, 89.0, t, 1, 28.0);

        float2 centered = in.uv - 0.5;
        col *= 1.0 - 0.9 * dot(centered, centered);
        col = 1.0 - exp(-col * 1.4);
        col += (hash21(frag) - 0.5) / 255.0;
        return float4(saturate(col), 1.0);
    }
    """
}
