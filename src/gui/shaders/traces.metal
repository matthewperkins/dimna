// The traces, in Metal Shading Language: what traces.vert and traces.frag do on Linux, line
// for line, for gpu_metal.zig. One instance per row (channel); a triangle strip with two
// vertices per pixel column that spans the column's minimum to maximum, so the strip is
// the trace's envelope.
//
// The sample history is a ring of interleaved int16 (sample-major), two per uint. Positions
// are absolute sample numbers modulo the ring's capacity (a power of two).
//
// Everything is worked out in Vulkan's clip space (y down: -1 is the top of the panel), as
// in traces.vert, and only the position given to the rasterizer is turned over at the end
// (Metal's clip space has y up). The library is compiled with fast math off.
//
// gpu_metal.zig appends static_asserts that this struct has `gpu.TraceParams`'s layout,
// field by field, followed by the palette (`theme.trace`).

#include <metal_stdlib>
using namespace metal;

struct TraceParams {
    uint nch;          // channels per sample in the history
    uint cap_mask;     // capacity in samples - 1
    uint newest;       // sample number one past the newest sample (low 32 bits)
    uint first_ch;     // channel of row 0
    uint cols;         // pixel columns
    uint rows;         // rows drawn
    float span;        // samples across the window
    float lsb_per_row; // sample units per row height
    float half_px;     // half the line thickness, in NDC y
    float phase;       // < 0: scroll (newest at the right edge). >= 0: sweep; samples since
                       // the current pass began, the write cursor's place in the window
    float future;      // samples at the right end of the window that do not exist yet (a
                       // triggered sweep still filling); those columns are not drawn
    float gain;        // brightness (older overlaid sweeps are dimmer)
    uint gain_base;    // where the panel's row factors start in `gains`
    uint dec_mask;     // buckets in `dec` - 1; 0: draw from samples whatever the time base;
                       // all ones: `dec` holds one word per pixel column, from `newest` on
    float pal[12];     // the four trace colours (rgb each), by channel & 3: `theme.trace`
};

// Pixel columns that hold this many samples or more are drawn from buckets: 4 to some
// tens of reads per column instead of hundreds. A column then also takes in what its
// first and last bucket hold beyond its own samples (15 samples at most at each end).
constant float bucket_cols = 64.0;

static inline int s16(uint v) { return int(v ^ 0x8000u) - 0x8000; }

static inline float trace_at(int off, uint ch, constant TraceParams &p, device const uint *hist) {
    // off <= -1: samples before `newest`.
    uint s = (p.newest + uint(off)) & p.cap_mask;
    uint e = s * p.nch + ch;
    uint v = (hist[e >> 1] >> ((e & 1u) * 16u)) & 0xFFFFu;
    return float(int(v ^ 0x8000u) - 0x8000);
}

static inline float trace_lerp_at(float pos, uint ch, constant TraceParams &p, device const uint *hist) {
    float f = floor(pos);
    int i = int(f);
    float a = trace_at(min(i, -1), ch, p, hist);
    float b = trace_at(min(i + 1, -1), ch, p, hist);
    return mix(a, b, pos - f);
}

struct TraceOut {
    float4 position [[position]];
    float3 colour [[flat]];
};

vertex TraceOut trace_vertex(
    uint vid [[vertex_id]],
    uint row [[instance_id]],
    device const uint *hist [[buffer(0)]],
    // Per-row factors on the vertical scale (1 = the panel's own), `max_rows` per panel.
    device const float *gains [[buffer(1)]],
    // The decimated history (decimate.zig): a ring of buckets of 16 samples, one word per
    // channel, the bucket's minimum in the low 16 bits and its maximum in the high. Bucket
    // b is samples [16 b, 16 b + 16), at index b modulo the ring's capacity.
    device const uint *dec [[buffer(2)]],
    constant TraceParams &p [[buffer(3)]])
{
    uint col = vid >> 1;
    bool top = (vid & 1u) == 1u;
    uint ch = p.first_ch + row;

    float per_col = p.span / float(p.cols);
    if (p.future > 0.0) {
        // Fold the columns that are still in the future onto the last one that exists.
        float last = floor((p.span - p.future) / per_col) - 1.0;
        col = uint(clamp(last, 0.0, float(col)));
    }
    float fa = -p.span + per_col * float(col);
    if (p.phase >= 0.0) {
        // Sweep: columns left of the cursor are from this pass, the rest from the last one.
        float o = per_col * float(col);
        fa = o + per_col <= p.phase ? o - p.phase : o - p.phase - p.span;
    }
    float fb = fa + per_col;
    float mn;
    float mx;
    if (p.dec_mask == 0xFFFFFFFFu) {
        // Review of a long stretch: the minimum and maximum of every pixel column were
        // worked out on the CPU (from the overview) and are in `dec`, from column
        // `newest` on.
        uint v = dec[(p.newest + col) * p.nch + ch];
        mn = float(s16(v & 0xFFFFu));
        mx = float(s16(v >> 16));
    } else if (p.dec_mask != 0u && per_col >= bucket_cols) {
        // Every bucket that holds one of the column's samples; the neighbouring columns
        // share its end buckets, so the trace stays connected. Sample numbers and bucket
        // numbers are taken modulo 2^32 and 2^28.
        uint ba = (p.newest + uint(int(floor(fa)))) >> 4;
        uint bb = (p.newest + uint(min(int(floor(fb)), -1))) >> 4;
        uint n = min((bb - ba) & 0x0FFFFFFFu, 4096u);
        mn = 32767.0;
        mx = -32768.0;
        for (uint k = 0u; k <= n; ++k) {
            uint v = dec[((ba + k) & p.dec_mask) * p.nch + ch];
            mn = min(mn, float(s16(v & 0xFFFFu)));
            mx = max(mx, float(s16(v >> 16)));
        }
    } else {
        // The column's ends by interpolation, so traces stay connected when a column holds
        // less than one sample; every whole sample in between.
        float va = trace_lerp_at(fa, ch, p, hist);
        float vb = trace_lerp_at(fb, ch, p, hist);
        mn = min(va, vb);
        mx = max(va, vb);
        int ia = int(floor(fa)) + 1;
        int ib = min(int(floor(fb)), -1);
        for (int i = ia; i <= ib; ++i) {
            float v = trace_at(i, ch, p, hist);
            mn = min(mn, v);
            mx = max(mx, v);
        }
    }

    float row_h = 2.0 / float(p.rows);
    float centre = -1.0 + (float(row) + 0.5) * row_h;
    // Positive is up; a trace may reach 1.5 rows from its centre before it is clipped.
    float per_row = p.lsb_per_row * gains[p.gain_base + min(row, 255u)];
    float lo = clamp(mn / per_row, -1.5, 1.5);
    float hi = clamp(mx / per_row, -1.5, 1.5);
    float y = top ? centre - hi * row_h - p.half_px : centre - lo * row_h + p.half_px;
    // Off scale: the whole column lies beyond what is drawn (1.5 rows from the centre).
    // Instead of a flat line far from its row, a dashed line near the row's own upper or
    // lower edge says which way the signal has gone.
    bool above = mn / per_row > 1.5;
    bool below = mx / per_row < -1.5;
    bool off_scale = above || below;
    if (off_scale) {
        float edge = centre + (above ? -0.42 : 0.42) * row_h;
        bool dash = ((col >> 2) & 1u) == 0u;
        y = dash ? (top ? edge - p.half_px : edge + p.half_px) : edge;
    }
    float x = -1.0 + 2.0 * (float(col) + 0.5) / float(p.cols);

    TraceOut out;
    // Vulkan's y down turned into Metal's y up.
    out.position = float4(x, -y, 0.0, 1.0);
    uint pi = (ch & 3u) * 3u;
    out.colour = float3(p.pal[pi], p.pal[pi + 1u], p.pal[pi + 2u]) * p.gain;
    return out;
}

fragment float4 trace_fragment(TraceOut in [[stage_in]]) {
    return float4(in.colour, 1.0);
}
