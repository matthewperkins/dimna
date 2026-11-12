#version 450
// Text and solid rectangles: quads in pixel coordinates, textured from the glyph atlas.
layout(push_constant) uniform Params { vec2 size; } p; // the surface, in pixels
layout(location = 0) in vec2 pos;
layout(location = 1) in vec2 uv;
layout(location = 2) in vec4 colour;
layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_colour;
void main() {
    gl_Position = vec4(pos / p.size * 2.0 - 1.0, 0.0, 1.0);
    out_uv = uv;
    out_colour = colour;
}
