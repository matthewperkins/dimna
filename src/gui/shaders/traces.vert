#version 450
// One instance per row (channel); a triangle strip with two vertices per pixel column that
// spans the column's minimum to maximum, so the strip is the trace's envelope.
//
// The sample history is a ring of interleaved int16 (sample-major), two per uint. Positions
// are absolute sample numbers modulo the ring's capacity (a power of two).

layout(set = 0, binding = 0) readonly buffer History { uint w[]; } hist;

layout(push_constant) uniform Params {
    uint nch;          // channels per sample in the history
    uint cap_mask;     // capacity in samples - 1
    uint newest;       // sample number one past the newest sample (low 32 bits)
    uint first_ch;     // channel of row 0
    uint cols;         // pixel columns
    uint rows;         // rows drawn
    float span;        // samples across the window
    float lsb_per_row; // sample units per row height
    float half_px;     // half the line thickness, in NDC y
} p;

layout(location = 0) out vec3 colour;

float at(int off, uint ch) {
    // off <= -1: samples before `newest`.
    uint s = (p.newest + uint(off)) & p.cap_mask;
    uint e = s * p.nch + ch;
    uint v = (hist.w[e >> 1] >> ((e & 1u) * 16u)) & 0xFFFFu;
    return float(int(v ^ 0x8000u) - 0x8000);
}

float lerpAt(float pos, uint ch) {
    float f = floor(pos);
    int i = int(f);
    float a = at(min(i, -1), ch);
    float b = at(min(i + 1, -1), ch);
    return mix(a, b, pos - f);
}

void main() {
    uint col = uint(gl_VertexIndex) >> 1;
    bool top = (gl_VertexIndex & 1) == 1;
    uint row = uint(gl_InstanceIndex);
    uint ch = p.first_ch + row;

    float per_col = p.span / float(p.cols);
    float fa = -p.span + per_col * float(col);
    float fb = fa + per_col;
    // The column's ends by interpolation, so traces stay connected when a column holds less
    // than one sample; every whole sample in between.
    float va = lerpAt(fa, ch);
    float vb = lerpAt(fb, ch);
    float mn = min(va, vb);
    float mx = max(va, vb);
    int ia = int(floor(fa)) + 1;
    int ib = min(int(floor(fb)), -1);
    for (int i = ia; i <= ib; ++i) {
        float v = at(i, ch);
        mn = min(mn, v);
        mx = max(mx, v);
    }

    float row_h = 2.0 / float(p.rows);
    float centre = -1.0 + (float(row) + 0.5) * row_h;
    // Positive is up; a trace may reach 1.5 rows from its centre before it is clipped.
    float lo = clamp(mn / p.lsb_per_row, -1.5, 1.5);
    float hi = clamp(mx / p.lsb_per_row, -1.5, 1.5);
    float y = top ? centre - hi * row_h - p.half_px : centre - lo * row_h + p.half_px;
    float x = -1.0 + 2.0 * (float(col) + 0.5) / float(p.cols);
    gl_Position = vec4(x, y, 0.0, 1.0);

    const vec3 palette[4] = vec3[4](vec3(0.55, 0.85, 1.0), vec3(1.0, 0.82, 0.45), vec3(0.6, 1.0, 0.65), vec3(1.0, 0.6, 0.75));
    colour = palette[ch & 3u];
}
