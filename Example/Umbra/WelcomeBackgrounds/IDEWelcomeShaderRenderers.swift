import MetalKit
import SwiftUI

// MARK: - Shared helpers

private enum IDEWelcomeShaderColors {
    static func rgb(_ hex: String) -> SIMD3<Float> {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            return SIMD3(1, 1, 1)
        }
        return SIMD3(
            Float((value >> 16) & 0xFF) / 255,
            Float((value >> 8) & 0xFF) / 255,
            Float(value & 0xFF) / 255
        )
    }
}

private enum IDEWelcomeShaderMouse {
    static func smooth(
        current: inout SIMD2<Float>,
        target: SIMD2<Float>,
        factor: Float = 0.05
    ) -> SIMD2<Float> {
        current += (target - current) * factor
        return current
    }

    /// Evil Eye expects −1…1 with y up, matching React Bits pointer math.
    static func evilEyeTarget(from normalized: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(normalized.x * 2 - 1, 1 - normalized.y * 2)
    }
}

@MainActor
class IDEWelcomeFragmentRendererBase: NSObject {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    var parallax: IDEWelcomeParallax?
    var elapsed: Double = 0
    var lastFrame: CFTimeInterval?
    var smoothedMouse = SIMD2<Float>(0.5, 0.5)

    init?(device: MTLDevice?, fragmentName: String, blendEnabled: Bool = false) {
        guard
            let device,
            let queue = device.makeCommandQueue(),
            let pipeline = IDEWelcomeShaderPipelines.pipeline(
                device: device,
                fragmentName: fragmentName,
                librarySource: IDEWelcomeShaderMetalSource.library,
                blendEnabled: blendEnabled
            )
        else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        super.init()
    }

    @objc func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func drawFullscreenTriangle(
        in view: MTKView,
        configure: (MTLRenderCommandEncoder, CGSize, Double, Bool) -> Void
    ) {
        guard
            let drawable = view.currentDrawable,
            let pass = view.currentRenderPassDescriptor,
            let buffer = queue.makeCommandBuffer(),
            let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let now = CACurrentMediaTime()
        let paused = view.isPaused
        let time = IDEWelcomeMetalTiming.advance(elapsed: &elapsed, lastFrame: &lastFrame, paused: paused, now: now)
        let size = view.drawableSize

        encoder.setRenderPipelineState(pipeline)
        configure(encoder, size, time, paused)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    func normalizedMouse(in view: MTKView, paused: Bool, now: CFTimeInterval) -> SIMD2<Float> {
        let target = IDEWelcomeMetalPointer.normalized(
            parallax: parallax,
            paused: paused,
            now: now,
            size: view.bounds.size
        )
        return IDEWelcomeShaderMouse.smooth(current: &smoothedMouse, target: target)
    }
}

// MARK: - Gradient Waves

@MainActor
final class IDEWelcomeGradientWavesRenderer: IDEWelcomeFragmentRendererBase, IDEWelcomeMetalRenderer {
    private struct Uniforms {
        var resolution: SIMD2<Float>
        var time: Float
        var speed: Float
        var amplitude: Float
        var waveScale: Float
        var waveRatio: Float
        var swell: Float
        var turbulence: Float
        var tilt: Float
        var zoom: Float
        var height: Float
        var fogDepth: Float
        var steps: Float
        var brightness: Float
        var opacity: Float
        var grain: Float
        var grainIntensity: Float
        var enableMouse: Float
        var mouse: SIMD2<Float>
        var parallax: Float
        var pad0: Float = 0
        var horizonColor: SIMD3<Float>
        var pad1: Float = 0
        var waveColor: SIMD3<Float>
        var pad2: Float = 0
        var crestColor: SIMD3<Float>
        var pad3: Float = 0
    }

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        super.init(device: device, fragmentName: "gradientWavesFragment", blendEnabled: true)
    }

    func draw(in view: MTKView) {
        drawFullscreenTriangle(in: view) { encoder, size, time, paused in
            let mouse = normalizedMouse(in: view, paused: paused, now: CACurrentMediaTime())
            var uniforms = Uniforms(
                resolution: SIMD2(Float(size.width), Float(size.height)),
                time: Float(time),
                speed: 0.4,
                amplitude: 2.5,
                waveScale: 0.6,
                waveRatio: 0.9,
                swell: 35,
                turbulence: 20,
                tilt: 1.11,
                zoom: 1.0,
                height: 5.5,
                fogDepth: 15,
                steps: 70,
                brightness: 1.0,
                opacity: 1.0,
                grain: 1.0,
                grainIntensity: 0.05,
                enableMouse: 1.0,
                mouse: mouse,
                parallax: 0.5,
                horizonColor: IDEWelcomeShaderColors.rgb("#5227FF"),
                waveColor: IDEWelcomeShaderColors.rgb("#FF9FFC"),
                crestColor: IDEWelcomeShaderColors.rgb("#FFFFFF")
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        }
    }
}

// MARK: - Molten Metal

@MainActor
final class IDEWelcomeMoltenMetalRenderer: IDEWelcomeFragmentRendererBase, IDEWelcomeMetalRenderer {
    private struct Uniforms {
        var resolution: SIMD2<Float>
        var time: Float
        var speed: Float
        var scale: Float
        var detail: Float
        var glow: Float
        var coreSize: Float
        var swirl: Float
        var fold: Float
        var blackPoint: Float
        var brightness: Float
        var colorMode: Float
        var grain: Float
        var grainIntensity: Float
        var opacity: Float
        var mouseStrength: Float
        var enableMouse: Float
        var lightMode: Float
        var mouse: SIMD2<Float>
        var pad0: Float = 0
        var color1: SIMD3<Float>
        var pad1: Float = 0
        var color2: SIMD3<Float>
        var pad2: Float = 0
        var color3: SIMD3<Float>
        var pad3: Float = 0
        var backgroundColor: SIMD3<Float>
        var pad4: Float = 0
    }

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        super.init(device: device, fragmentName: "moltenMetalFragment", blendEnabled: true)
    }

    func draw(in view: MTKView) {
        drawFullscreenTriangle(in: view) { encoder, size, time, paused in
            let mouse = normalizedMouse(in: view, paused: paused, now: CACurrentMediaTime())
            var uniforms = Uniforms(
                resolution: SIMD2(Float(size.width), Float(size.height)),
                time: Float(time),
                speed: 0.35,
                scale: 4,
                detail: 3,
                glow: 1.6,
                coreSize: 0.1,
                swirl: 1,
                fold: -0.2,
                blackPoint: 0.05,
                brightness: 1.3,
                colorMode: 0,
                grain: 1,
                grainIntensity: 0.05,
                opacity: 1.0,
                mouseStrength: 0.3,
                enableMouse: 1.0,
                lightMode: 0,
                mouse: mouse,
                color1: IDEWelcomeShaderColors.rgb("#5227FF"),
                color2: IDEWelcomeShaderColors.rgb("#FF9FFC"),
                color3: IDEWelcomeShaderColors.rgb("#FFFFFF"),
                backgroundColor: IDEWelcomeShaderColors.rgb("#FFFFFF")
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        }
    }
}

// MARK: - Galaxy

@MainActor
final class IDEWelcomeGalaxyRenderer: IDEWelcomeFragmentRendererBase, IDEWelcomeMetalRenderer {
    private struct Uniforms {
        var resolution: SIMD3<Float>
        var time: Float
        var focal: SIMD2<Float>
        var rotation: SIMD2<Float>
        var starSpeed: Float
        var density: Float
        var hueShift: Float
        var speed: Float
        var mouse: SIMD2<Float>
        var glowIntensity: Float
        var saturation: Float
        var mouseRepulsion: Float
        var twinkleIntensity: Float
        var rotationSpeed: Float
        var repulsionStrength: Float
        var mouseActiveFactor: Float
        var autoCenterRepulsion: Float
        var transparent: Float
        var lightMode: Float
        var pad0: Float = 0
    }

    private var smoothedActive: Float = 0

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        super.init(device: device, fragmentName: "galaxyFragment", blendEnabled: true)
    }

    func draw(in view: MTKView) {
        drawFullscreenTriangle(in: view) { encoder, size, time, paused in
            let mouse = normalizedMouse(in: view, paused: paused, now: CACurrentMediaTime())
            let targetActive = IDEWelcomeMetalPointer.activeFactor(parallax: parallax)
            smoothedActive += (targetActive - smoothedActive) * 0.05
            let width = Float(size.width)
            let height = Float(size.height)
            var uniforms = Uniforms(
                resolution: SIMD3(width, height, width / max(height, 1)),
                time: Float(time),
                focal: SIMD2(0.5, 0.5),
                rotation: SIMD2(1.0, 0.0),
                starSpeed: Float(time) * 0.001 * 0.5 / 10.0,
                density: 1,
                hueShift: 140,
                speed: 1.0,
                mouse: mouse,
                glowIntensity: 0.3,
                saturation: 0,
                mouseRepulsion: 1,
                twinkleIntensity: 0.3,
                rotationSpeed: 0.1,
                repulsionStrength: 2,
                mouseActiveFactor: smoothedActive,
                autoCenterRepulsion: 0,
                transparent: 1,
                lightMode: 0
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        }
    }
}

// MARK: - Liquid Chrome

@MainActor
final class IDEWelcomeLiquidChromeRenderer: IDEWelcomeFragmentRendererBase, IDEWelcomeMetalRenderer {
    private struct Uniforms {
        var resolution: SIMD3<Float>
        var time: Float
        var baseColor: SIMD3<Float>
        var pad0: Float = 0
        var amplitude: Float
        var frequencyX: Float
        var frequencyY: Float
        var pad1: Float = 0
        var mouse: SIMD2<Float>
        var pad2: Float = 0
    }

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        super.init(device: device, fragmentName: "liquidChromeFragment")
    }

    func draw(in view: MTKView) {
        drawFullscreenTriangle(in: view) { encoder, size, time, paused in
            let mouse = normalizedMouse(in: view, paused: paused, now: CACurrentMediaTime())
            let width = Float(size.width)
            let height = Float(size.height)
            var uniforms = Uniforms(
                resolution: SIMD3(width, height, width / max(height, 1)),
                time: Float(time) * 0.2,
                baseColor: SIMD3(0.1, 0.1, 0.1),
                amplitude: 0.3,
                frequencyX: 3,
                frequencyY: 3,
                mouse: mouse
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        }
    }
}

// MARK: - Pixel Snow

@MainActor
final class IDEWelcomePixelSnowRenderer: IDEWelcomeFragmentRendererBase, IDEWelcomeMetalRenderer {
    private struct Uniforms {
        var resolution: SIMD2<Float>
        var time: Float
        var flakeSize: Float
        var minFlakeSize: Float
        var pixelResolution: Float
        var speed: Float
        var depthFade: Float
        var farPlane: Float
        var color: SIMD3<Float>
        var pad0: Float = 0
        var brightness: Float
        var gamma: Float
        var density: Float
        var variant: Float
        var direction: Float
        var pad1: Float = 0
    }

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        super.init(device: device, fragmentName: "pixelSnowFragment")
    }

    func draw(in view: MTKView) {
        drawFullscreenTriangle(in: view) { encoder, size, time, _ in
            var uniforms = Uniforms(
                resolution: SIMD2(Float(size.width), Float(size.height)),
                time: Float(time),
                flakeSize: 0.01,
                minFlakeSize: 1.25,
                pixelResolution: 200,
                speed: 1.25,
                depthFade: 8,
                farPlane: 20,
                color: SIMD3(1, 1, 1),
                brightness: 1,
                gamma: 0.4545,
                density: 0.3,
                variant: 0,
                direction: Float(125 * Double.pi / 180)
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        }
    }
}

// MARK: - Evil Eye

@MainActor
final class IDEWelcomeEvilEyeRenderer: IDEWelcomeFragmentRendererBase, IDEWelcomeMetalRenderer {
    private struct Uniforms {
        var resolution: SIMD3<Float>
        var time: Float
        var pupilSize: Float
        var irisWidth: Float
        var glowIntensity: Float
        var intensity: Float
        var scale: Float
        var noiseScale: Float
        var pupilFollow: Float
        var flameSpeed: Float
        var lightMode: Float
        var mouse: SIMD2<Float>
        var pad0: Float = 0
        var eyeColor: SIMD3<Float>
        var pad1: Float = 0
        var bgColor: SIMD3<Float>
        var pad2: Float = 0
    }

    private let noiseTexture: MTLTexture
    private let sampler: MTLSamplerState

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let noiseTexture = IDEWelcomeMakeNoiseTexture(device: device) else { return nil }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.noiseTexture = noiseTexture
        self.sampler = sampler
        super.init(device: device, fragmentName: "evilEyeFragment")
        smoothedMouse = SIMD2(0, 0)
    }

    func draw(in view: MTKView) {
        drawFullscreenTriangle(in: view) { encoder, size, time, paused in
            let normalized = IDEWelcomeMetalPointer.normalized(
                parallax: parallax,
                paused: paused,
                now: CACurrentMediaTime(),
                size: view.bounds.size
            )
            let target = IDEWelcomeShaderMouse.evilEyeTarget(from: normalized)
            let mouse = IDEWelcomeShaderMouse.smooth(current: &smoothedMouse, target: target)
            let width = Float(size.width)
            let height = Float(size.height)
            var uniforms = Uniforms(
                resolution: SIMD3(width, height, width / max(height, 1)),
                time: Float(time),
                pupilSize: 0.6,
                irisWidth: 0.25,
                glowIntensity: 0.35,
                intensity: 1.5,
                scale: 0.8,
                noiseScale: 1.0,
                pupilFollow: 1.0,
                flameSpeed: 1.0,
                lightMode: 0,
                mouse: mouse,
                eyeColor: IDEWelcomeShaderColors.rgb("#FF6F37"),
                bgColor: SIMD3(0, 0, 0)
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(noiseTexture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
        }
    }
}

// MARK: - Aero Shards

@MainActor
final class IDEWelcomeAeroShardsRenderer: IDEWelcomeFragmentRendererBase, IDEWelcomeMetalRenderer {
    private struct Uniforms {
        var resolution: SIMD2<Float>
        var time: Float
        var mouse: SIMD2<Float>
        var pointerActive: Float
        var parallax: Float
        var pad0: Float = 0
    }

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        super.init(device: device, fragmentName: "aeroShardsFragment")
    }

    func draw(in view: MTKView) {
        drawFullscreenTriangle(in: view) { encoder, size, time, paused in
            let mouse = normalizedMouse(in: view, paused: paused, now: CACurrentMediaTime())
            var uniforms = Uniforms(
                resolution: SIMD2(Float(size.width), Float(size.height)),
                time: Float(time),
                mouse: mouse,
                pointerActive: IDEWelcomeMetalPointer.activeFactor(parallax: parallax),
                parallax: 0.35
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        }
    }
}
