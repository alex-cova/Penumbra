import Foundation
import Metal

/// Process-wide Metal device, queue, and shader library.
///
/// Shader compilation is deferred until the first `isAvailable` check that needs the library
/// so XCTest / default-off editors do not pay `makeLibrary` on every `TextView` init.
@MainActor
final class MetalContext {
    static let shared = MetalContext()

    static var isAvailable: Bool {
        shared.isAvailable
    }

    private(set) var device: MTLDevice?
    private(set) var commandQueue: MTLCommandQueue?
    private(set) var library: MTLLibrary?
    private var didFailPermanently = false
    private var didLogFailure = false
    private(set) var failureReason: String?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var _glyphAtlas: GlyphAtlas?

    /// When `true`, `MetalTextCanvasView` creates its `CAMetalLayer` with `framebufferOnly = false`
    /// so the present command buffer can read back the submitted drawable. Off in the shipping
    /// path; PerfHarness / snapshot tests set it before building a `TextView`.
    var allowsDrawableCapture = false

    /// Process-wide glyph atlas, shared by every `MetalRenderer` (one `MTLDevice`, one budget). Nil
    /// until Metal is confirmed available. Created lazily so default-off editors never allocate it.
    var glyphAtlas: GlyphAtlas? {
        guard isAvailable else {
            return nil
        }
        if _glyphAtlas == nil {
            _glyphAtlas = GlyphAtlas(context: self)
        }
        return _glyphAtlas
    }

    var isAvailable: Bool {
        guard !didFailPermanently, device != nil, commandQueue != nil else {
            return false
        }
        ensureLibrary()
        return !didFailPermanently && library != nil
    }

    private init() {
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        if device == nil || commandQueue == nil {
            markUnavailable(reason: "No Metal device or command queue")
        }
        installMemoryPressureSource()
    }

    func markUnavailable(reason: String = "Metal device lost") {
        guard !didFailPermanently else {
            return
        }
        didFailPermanently = true
        failureReason = reason
        library = nil
        logFailureOnce(reason)
    }

    private func ensureLibrary() {
        guard library == nil, !didFailPermanently, let device else {
            return
        }
        let source = "\(Self.shaderSource)"
        do {
            library = try PenumbraSignposts.interval("MetalContext.makeLibrary") {
                try device.makeLibrary(source: source, options: nil)
            }
        } catch {
            markUnavailable(reason: "Failed to compile Metal library: \(error.localizedDescription)")
        }
    }

    private func installMemoryPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            self?.handleMemoryPressure()
        }
        source.resume()
        memoryPressureSource = source
    }

    private func handleMemoryPressure() {
        _glyphAtlas?.handleMemoryPressure()
    }

    private func logFailureOnce(_ message: String) {
        guard !didLogFailure else {
            return
        }
        didLogFailure = true
        NSLog("Penumbra Metal: %@", message)
    }
}

private extension MetalContext {
    static let shaderSource: StaticString = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct ClearVertexOut {
        float4 position [[position]];
    };

    vertex ClearVertexOut penumbra_clear_vertex(uint vid [[vertex_id]]) {
        ClearVertexOut out;
        float2 pos;
        if (vid == 0) {
            pos = float2(-1.0, -1.0);
        } else if (vid == 1) {
            pos = float2(3.0, -1.0);
        } else {
            pos = float2(-1.0, 3.0);
        }
        out.position = float4(pos, 0.0, 1.0);
        return out;
    }

    fragment float4 penumbra_clear_fragment() {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    // Must match `GlyphInstance` (Swift) field-for-field.
    struct GlyphInstanceData {
        float2 origin;
        float2 size;
        float2 uvOrigin;
        float2 uvSize;
        float4 color;
        uint atlasPage;
    };

    // Must match `MetalProjectionUniforms` (Swift).
    struct GlyphUniforms {
        float2 canvasOrigin;
        float2 canvasSize;
        float scale;
    };

    struct GlyphVertexOut {
        float4 position [[position]];
        float2 uv;
        float4 color;
    };

    vertex GlyphVertexOut penumbra_glyph_vertex(uint vid [[vertex_id]],
                                                 uint iid [[instance_id]],
                                                 const device GlyphInstanceData *instances [[buffer(0)]],
                                                 constant GlyphUniforms &u [[buffer(1)]]) {
        // Triangle-strip corners: (0,0) (1,0) (0,1) (1,1).
        float2 corner = float2(float(vid & 1), float(vid >> 1));
        GlyphInstanceData inst = instances[iid];
        float2 contentPos = inst.origin + corner * inst.size;
        // Content space -> NDC. Subtract only the canvas origin; Y is flipped (the view is flipped).
        float2 ndc;
        ndc.x = (contentPos.x - u.canvasOrigin.x) / u.canvasSize.x * 2.0 - 1.0;
        ndc.y = 1.0 - (contentPos.y - u.canvasOrigin.y) / u.canvasSize.y * 2.0;
        GlyphVertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        // Atlas tiles are stored bottom-up (CG raster origin); the quad's content-top vertex
        // (corner.y == 0) samples the tile's last row.
        out.uv = float2(inst.uvOrigin.x + corner.x * inst.uvSize.x,
                        inst.uvOrigin.y + (1.0 - corner.y) * inst.uvSize.y);
        out.color = inst.color;
        return out;
    }

    fragment float4 penumbra_glyph_coverage_fragment(GlyphVertexOut in [[stage_in]],
                                                      texture2d<float> atlas [[texture(0)]],
                                                      sampler s [[sampler(0)]]) {
        float coverage = atlas.sample(s, in.uv).r;
        // `in.color` is premultiplied sRGB (focus alpha already folded in).
        return in.color * coverage;
    }

    fragment float4 penumbra_glyph_color_fragment(GlyphVertexOut in [[stage_in]],
                                                   texture2d<float> atlas [[texture(0)]],
                                                   sampler s [[sampler(0)]]) {
        // Color atlas texels are already premultiplied; instance alpha carries focus dimming.
        float4 texel = atlas.sample(s, in.uv);
        return texel * in.color.a;
    }

    // MARK: Decoration solids (rounded/stroked rectangles)

    // Must match `SolidInstance` (Swift) field-for-field.
    struct SolidInstanceData {
        float2 origin;
        float2 size;
        float4 fillColor;
        float4 strokeColor;
        float cornerRadius;
        float strokeWidth;
        uint roundedCornersMask;
    };

    struct SolidVertexOut {
        float4 position [[position]];
        float2 local;       // point relative to the rect centre, content units
        float2 halfSize;
        float4 fillColor;
        float4 strokeColor;
        float cornerRadius;
        float strokeWidth;
        float scale;
        uint mask;
    };

    vertex SolidVertexOut penumbra_solid_vertex(uint vid [[vertex_id]],
                                                 uint iid [[instance_id]],
                                                 const device SolidInstanceData *instances [[buffer(0)]],
                                                 constant GlyphUniforms &u [[buffer(1)]]) {
        float2 corner = float2(float(vid & 1), float(vid >> 1));
        SolidInstanceData inst = instances[iid];
        float2 contentPos = inst.origin + corner * inst.size;
        float2 ndc;
        ndc.x = (contentPos.x - u.canvasOrigin.x) / u.canvasSize.x * 2.0 - 1.0;
        ndc.y = 1.0 - (contentPos.y - u.canvasOrigin.y) / u.canvasSize.y * 2.0;
        SolidVertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.halfSize = inst.size * 0.5;
        out.local = contentPos - (inst.origin + out.halfSize);
        out.fillColor = inst.fillColor;
        out.strokeColor = inst.strokeColor;
        out.cornerRadius = inst.cornerRadius;
        out.strokeWidth = inst.strokeWidth;
        out.scale = max(u.scale, 0.0001);
        out.mask = inst.roundedCornersMask;
        return out;
    }

    inline float penumbra_rounded_box_sdf(float2 p, float2 b, float r) {
        float2 q = abs(p) - b + r;
        return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    }

    fragment float4 penumbra_solid_fragment(SolidVertexOut in [[stage_in]]) {
        // Pick the corner radius for the quadrant this fragment is in (content axes: +x right,
        // +y down; bit 0 TL, 1 TR, 2 BR, 3 BL).
        bool left = in.local.x < 0.0;
        bool top = in.local.y < 0.0;
        uint bit;
        if (top && left) { bit = 0u; }
        else if (top && !left) { bit = 1u; }
        else if (!top && !left) { bit = 2u; }
        else { bit = 3u; }
        float r = ((in.mask & (1u << bit)) != 0u) ? in.cornerRadius : 0.0;
        r = clamp(r, 0.0, min(in.halfSize.x, in.halfSize.y));
        float d = penumbra_rounded_box_sdf(in.local, in.halfSize, r);
        // ~1px anti-aliasing in device pixels.
        float aa = 1.0 / in.scale;
        float4 outColor = in.fillColor * clamp(0.5 - d / aa, 0.0, 1.0);
        if (in.strokeWidth > 0.0 && in.strokeColor.a > 0.0) {
            float sd = abs(d) - in.strokeWidth * 0.5;
            float sc = clamp(0.5 - sd / aa, 0.0, 1.0);
            // Premultiplied "stroke over fill".
            outColor = in.strokeColor * sc + outColor * (1.0 - sc);
        }
        return outColor;
    }

    // MARK: Decoration polylines (squiggles)

    struct DecorationVertexData {
        float2 position;
        float4 color;
    };

    struct DecorationLineOut {
        float4 position [[position]];
        float4 color;
    };

    vertex DecorationLineOut penumbra_decoration_line_vertex(uint vid [[vertex_id]],
                                                              const device DecorationVertexData *verts [[buffer(0)]],
                                                              constant GlyphUniforms &u [[buffer(1)]]) {
        DecorationVertexData v = verts[vid];
        float2 ndc;
        ndc.x = (v.position.x - u.canvasOrigin.x) / u.canvasSize.x * 2.0 - 1.0;
        ndc.y = 1.0 - (v.position.y - u.canvasOrigin.y) / u.canvasSize.y * 2.0;
        DecorationLineOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.color = v.color;
        return out;
    }

    fragment float4 penumbra_decoration_line_fragment(DecorationLineOut in [[stage_in]]) {
        return in.color;
    }
    """#
}
