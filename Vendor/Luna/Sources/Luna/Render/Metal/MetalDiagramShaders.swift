import Foundation

/// Metal shader source for Luna's diagram backend, compiled at runtime with
/// `makeLibrary(source:)` (same pattern as Penumbra's `MetalContext`, so no
/// `.metal` build rules are needed in the vendored target).
///
/// One vertex layout serves solid fills and label-atlas samples: `mode` 0
/// draws the interpolated color, 1 multiplies the atlas coverage mask by it.
/// Coordinates arrive in device pixels, origin top-left.
///
/// `DiagramVertex` contains a `float4`, so Metal pads its array stride to 16
/// bytes: 48 bytes (12 floats) per vertex. The CPU side
/// (`MetalTessellator.vertex`) MUST append 3 padding floats after `mode` to
/// match — packing only the 9 meaningful floats reads 36-byte strides on the
/// GPU and silently corrupts every vertex past the first. Do not "optimize"
/// the padding away.
enum MetalDiagramShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct DiagramVertex {
        float2 pos;
        float2 uv;
        float4 color;
        float mode;
    };

    struct DiagramVarying {
        float4 pos [[position]];
        float2 uv;
        float4 color;
        float mode;
    };

    struct DiagramUniforms {
        float2 viewport;
    };

    vertex DiagramVarying diagram_vs(
        uint vid [[vertex_id]],
        constant DiagramVertex *verts [[buffer(0)]],
        constant DiagramUniforms &u [[buffer(1)]])
    {
        DiagramVarying out;
        DiagramVertex v = verts[vid];
        float2 ndc = float2(
            v.pos.x / u.viewport.x * 2.0 - 1.0,
            1.0 - v.pos.y / u.viewport.y * 2.0);
        out.pos = float4(ndc, 0.0, 1.0);
        out.uv = v.uv;
        out.color = v.color;
        out.mode = v.mode;
        return out;
    }

    fragment float4 diagram_fs(
        DiagramVarying in [[stage_in]],
        texture2d<float> atlas [[texture(0)]],
        sampler samp [[sampler(0)]])
    {
        if (in.mode > 0.5) {
            float4 t = atlas.sample(samp, in.uv);
            float a = t.a * in.color.a;
            return float4(in.color.rgb * a, a);
        }
        return in.color;
    }
    """
}
