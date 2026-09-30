import MetalKit
import SwiftUI

/// Metal point-sprite port of React Bits `Particles.tsx` (200 white particles, hover drift, rotation).
struct IDEWelcomeParticles: View {
    let parallax: IDEWelcomeParallax
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        IDEWelcomeParticlesMetalView(
            parallax: parallax,
            isPaused: reduceMotion || controlActiveState == .inactive
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct IDEWelcomeParticlesMetalView: NSViewRepresentable {
    let parallax: IDEWelcomeParallax
    let isPaused: Bool

    func makeCoordinator() -> IDEWelcomeParticlesRenderer? {
        IDEWelcomeParticlesRenderer()
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

@MainActor
final class IDEWelcomeParticlesRenderer: NSObject, MTKViewDelegate {
    private struct Vertex {
        var position: SIMD3<Float>
        var random: SIMD4<Float>
        var color: SIMD3<Float>
    }

    private struct VertexUniforms {
        var modelMatrix: simd_float4x4
        var viewMatrix: simd_float4x4
        var projectionMatrix: simd_float4x4
        var time: Float
        var spread: Float
        var baseSize: Float
        var sizeRandomness: Float
        var alphaParticles: Float
    }

    let device: MTLDevice
    var parallax: IDEWelcomeParallax?
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private var elapsed: Double = 0
    private var lastFrame: CFTimeInterval?
    private var rotationZ: Float = 0

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }

        guard
            let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
            let vertexFunction = library.makeFunction(name: "particlesVertex"),
            let fragmentFunction = library.makeFunction(name: "particlesFragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        let vertices = Self.makeVertices(count: 200)
        guard let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<Vertex>.stride * vertices.count,
            options: .storageModeShared
        ) else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.vertexBuffer = vertexBuffer
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

        let now = CACurrentMediaTime()
        let paused = view.isPaused
        if !paused, let lastFrame {
            elapsed += min(max(now - lastFrame, 0), 0.1) * 0.1
        }
        lastFrame = paused ? nil : now

        let aspect = Float(max(view.drawableSize.width / max(view.drawableSize.height, 1), 1))
        let hover = hoverOffset(in: view, paused: paused, now: now)
        if !paused {
            rotationZ += 0.01 * 0.1
        }

        let model = Self.modelMatrix(
            hover: hover,
            rotationX: paused ? 0 : sin(Float(elapsed) * 0.0002) * 0.1,
            rotationY: paused ? 0 : cos(Float(elapsed) * 0.0005) * 0.15,
            rotationZ: rotationZ
        )
        let viewMatrix = simd_float4x4(translation: SIMD3(0, 0, -20))
        let projection = Self.perspective(fovYDegrees: 15, aspect: aspect, near: 0.1, far: 100)

        var uniforms = VertexUniforms(
            modelMatrix: model,
            viewMatrix: viewMatrix,
            projectionMatrix: projection,
            time: Float(elapsed),
            spread: 10,
            baseSize: 100,
            sizeRandomness: 1,
            alphaParticles: 0
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<VertexUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 200)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func hoverOffset(in view: MTKView, paused: Bool, now: CFTimeInterval) -> SIMD2<Float> {
        guard let parallax, !paused else { return .zero }
        let tilt = parallax.advance(to: now, in: view.bounds.size)
        return SIMD2(-Float(tilt.dx), -Float(tilt.dy))
    }

    private static func makeVertices(count: Int) -> [Vertex] {
        var vertices: [Vertex] = []
        for _ in 0..<count {
            var x: Float = 0
            var y: Float = 0
            var z: Float = 0
            var lengthSquared: Float = 0
            repeat {
                x = Float.random(in: -1...1)
                y = Float.random(in: -1...1)
                z = Float.random(in: -1...1)
                lengthSquared = x * x + y * y + z * z
            } while lengthSquared > 1 || lengthSquared == 0
            let radius = pow(Float.random(in: 0...1), 1.0 / 3.0)
            vertices.append(Vertex(
                position: SIMD3(x * radius, y * radius, z * radius),
                random: SIMD4(
                    Float.random(in: 0...1),
                    Float.random(in: 0...1),
                    Float.random(in: 0...1),
                    Float.random(in: 0...1)
                ),
                color: SIMD3(1, 1, 1)
            ))
        }
        return vertices
    }

    private static func modelMatrix(
        hover: SIMD2<Float>,
        rotationX: Float,
        rotationY: Float,
        rotationZ: Float
    ) -> simd_float4x4 {
        simd_float4x4(translation: SIMD3(hover.x, hover.y, 0))
        * simd_float4x4(rotationX: rotationX)
        * simd_float4x4(rotationY: rotationY)
        * simd_float4x4(rotationZ: rotationZ)
    }

    private static func perspective(fovYDegrees: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let yScale = 1 / tan(fovYDegrees * .pi / 360)
        let xScale = yScale / aspect
        let zRange = far - near
        return simd_float4x4(columns: (
            SIMD4(xScale, 0, 0, 0),
            SIMD4(0, yScale, 0, 0),
            SIMD4(0, 0, -(far + near) / zRange, -1),
            SIMD4(0, 0, -(2 * far * near) / zRange, 0)
        ))
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct ParticleVertex {
        float3 position;
        float4 random;
        float3 color;
    };

    struct VertexUniforms {
        float4x4 modelMatrix;
        float4x4 viewMatrix;
        float4x4 projectionMatrix;
        float time;
        float spread;
        float baseSize;
        float sizeRandomness;
        float alphaParticles;
    };

    struct VertexOut {
        float4 position [[position]];
        float4 random;
        float3 color;
        float pointSize [[point_size]];
    };

    vertex VertexOut particlesVertex(
        uint id [[vertex_id]],
        constant ParticleVertex *vertices [[buffer(0)]],
        constant VertexUniforms &u [[buffer(1)]]
    ) {
        ParticleVertex v = vertices[id];
        float3 pos = v.position * u.spread;
        pos.z *= 10.0;

        float4 modelPos = u.modelMatrix * float4(pos, 1.0);
        float t = u.time;
        modelPos.x += sin(t * v.random.z + 6.28 * v.random.w) * mix(0.1, 1.5, v.random.x);
        modelPos.y += sin(t * v.random.y + 6.28 * v.random.x) * mix(0.1, 1.5, v.random.w);
        modelPos.z += sin(t * v.random.w + 6.28 * v.random.y) * mix(0.1, 1.5, v.random.z);

        float4 viewPos = u.viewMatrix * modelPos;
        float pointSize = u.baseSize;
        if (u.sizeRandomness != 0.0) {
            pointSize = (u.baseSize * (1.0 + u.sizeRandomness * (v.random.x - 0.5))) / length(viewPos.xyz);
        }

        VertexOut out;
        out.position = u.projectionMatrix * viewPos;
        out.random = v.random;
        out.color = v.color;
        out.pointSize = pointSize;
        return out;
    }

    fragment float4 particlesFragment(
        VertexOut in [[stage_in]],
        float2 pointCoord [[point_coord]],
        constant VertexUniforms &u [[buffer(1)]]
    ) {
        float d = length(pointCoord - float2(0.5));
        float3 tint = in.color + 0.2 * sin(float3(pointCoord.x, pointCoord.y, pointCoord.x) + u.time + in.random.y * 6.28);
        if (u.alphaParticles < 0.5) {
            if (d > 0.5) {
                discard_fragment();
            }
            return float4(tint, 1.0);
        }
        float circle = smoothstep(0.5, 0.4, d) * 0.8;
        return float4(tint, circle);
    }
    """
}

private extension simd_float4x4 {
    init(translation: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(translation.x, translation.y, translation.z, 1)
    }

    init(rotationX angle: Float) {
        let c = cos(angle)
        let s = sin(angle)
        self = simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, c, s, 0),
            SIMD4(0, -s, c, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    init(rotationY angle: Float) {
        let c = cos(angle)
        let s = sin(angle)
        self = simd_float4x4(columns: (
            SIMD4(c, 0, -s, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(s, 0, c, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    init(rotationZ angle: Float) {
        let c = cos(angle)
        let s = sin(angle)
        self = simd_float4x4(columns: (
            SIMD4(c, s, 0, 0),
            SIMD4(-s, c, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }
}
