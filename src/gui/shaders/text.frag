#version 450
layout(set = 0, binding = 0) uniform sampler2D atlas; // coverage, one channel
layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 colour;
layout(location = 0) out vec4 out_colour;
void main() {
    out_colour = vec4(colour.rgb, colour.a * texture(atlas, uv).r);
}
