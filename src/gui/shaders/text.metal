// Text and solid rectangles, in Metal Shading Language: what text.vert and text.frag do on
// Linux, for gpu_metal.zig. Quads in pixel coordinates (`font.Vertex`), textured from the
// glyph atlas (one channel of coverage), blended over what is drawn.
//
// And the display's fills (`gpu.Fill`), which Vulkan draws with vkCmdClearAttachments: a
// triangle that covers the whole viewport, cut to the fill's rectangle by the scissor, so
// it replaces exactly the rectangle's pixels with its colour (no blending).
//
// gpu_metal.zig appends static_asserts that `TextVertex` has `font.Vertex`'s layout.

#include <metal_stdlib>
using namespace metal;

struct TextVertex {
    packed_float2 pos;  // pixels, from the top-left corner
    packed_float2 uv;   // in the atlas, 0..1
    uchar4 colour;      // RGBA, 0..255
};

struct TextOut {
    float4 position [[position]];
    float2 uv;
    float4 colour;
};

vertex TextOut text_vertex(
    uint vid [[vertex_id]],
    device const TextVertex *v [[buffer(0)]],
    constant float2 &size [[buffer(1)]]) // the drawable, in pixels
{
    TextVertex t = v[vid];
    float2 ndc = float2(t.pos) / size * 2.0 - 1.0;
    TextOut out;
    // Pixel rows run down; Metal's clip space has y up.
    out.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
    out.uv = float2(t.uv);
    out.colour = float4(t.colour) / 255.0;
    return out;
}

fragment float4 text_fragment(TextOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    // Glyph quads sit on whole pixels, so texels map one to one.
    constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge);
    return float4(in.colour.rgb, in.colour.a * atlas.sample(s, in.uv).r);
}

struct FillOut {
    float4 position [[position]];
};

vertex FillOut fill_vertex(uint vid [[vertex_id]]) {
    // (-1, -1), (3, -1), (-1, 3): one triangle over the whole viewport.
    FillOut out;
    out.position = float4(vid == 1u ? 3.0 : -1.0, vid == 2u ? 3.0 : -1.0, 0.0, 1.0);
    return out;
}

fragment float4 fill_fragment(constant float4 &colour [[buffer(0)]]) {
    return colour;
}
