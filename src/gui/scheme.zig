//! A colour scheme taken from an image (`scheme_image` in the config, `dimna --print-scheme`).
//!
//! The image is shrunk to at most 96x96 cells by box-averaging in linear light, each cell
//! becomes an Oklab colour, and k-means (k = 8, k-means++ seeded from a fixed seed) finds
//! the image's main colours. Roles are then assigned in OkLCh: neutrals take the hue of the
//! heaviest cluster at a fixed lightness and low chroma; the four trace colours are the most
//! chromatic, most present clusters whose hues differ; the accent is the first trace
//! colour's hue. Text and traces are raised in lightness until they contrast with the
//! background by a fixed ratio. The same pixels always give the same scheme.
//!
//! Everything except `decode`, `loadFile` and `writeSwatch`'s PNG encoder is pure and is
//! tested from pixel arrays.

const std = @import("std");
const stb = @import("stb");
const dimna = @import("dimna");
const files = @import("files.zig");
const Io = std.Io;
const Colour = [4]u8;
const Fill = [4]f32;

pub const max_cells = 96;
pub const k_clusters = 8;
/// Larger files are refused before they are read.
pub const max_file_bytes = 64 << 20;

/// What `theme.apply` takes: every themed colour, under the name `theme.zig` gives it.
pub const Scheme = struct {
    text_bright: Colour,
    text_dim: Colour,
    label_backing: Colour,
    help_backing: Colour,
    help_title: Colour,
    help_key: Colour,
    help_text: Colour,
    background: Fill,
    sweep_cursor: Fill,
    panel_divider: Fill,
    target_bar: Fill,
    tile_bg: Colour,
    tile_bg_hover: Colour,
    tile_wave: Colour,
    tile_range_text: Colour,
    button_idle: Colour,
    button_hover: Colour,
    button_on: Colour,
    button_on_hover: Colour,
    rule: Colour,
    heading_idle: Colour,
    heading_hover: Colour,
    /// The four trace colours (channel & 3), as the shader takes them.
    trace: [4][3]f32,
};

/// One cluster of the image: its mean in Oklab and how many cells it holds.
pub const Cluster = struct { lab: [3]f32, count: u32 };

/// A scheme with how it was found.
pub const Result = struct {
    scheme: Scheme,
    clusters: [k_clusters]Cluster,
    n_clusters: usize,
    /// The hue (degrees) of the heaviest cluster, which the neutrals take.
    base_hue: f32,
    /// How far, at most, any colour fell outside 0..1 before it was rounded (0 = every
    /// colour was inside sRGB as mapped).
    overshoot: f32,
};

// ---- colour maths ----

const Lab = [3]f32;

fn srgbToLinear(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(v: f32) f32 {
    return if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
}

fn linearToLab(r: f32, g: f32, b: f32) Lab {
    const l = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return .{
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    };
}

/// Linear sRGB of an Oklab colour, not clamped.
fn labToLinear(lab: Lab) [3]f32 {
    const l_ = lab[0] + 0.3963377774 * lab[1] + 0.2158037573 * lab[2];
    const m_ = lab[0] - 0.1055613458 * lab[1] - 0.0638541728 * lab[2];
    const s_ = lab[0] - 0.0894841775 * lab[1] - 1.2914855480 * lab[2];
    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;
    return .{
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    };
}

const Lch = struct { l: f32, c: f32, h: f32 };

fn labToLch(lab: Lab) Lch {
    var h = std.math.atan2(lab[2], lab[1]) * (180.0 / std.math.pi);
    if (h < 0) h += 360;
    return .{ .l = lab[0], .c = std.math.hypot(lab[1], lab[2]), .h = h };
}

fn lchToLab(l: f32, c: f32, h: f32) Lab {
    const r = h * (std.math.pi / 180.0);
    return .{ l, c * @cos(r), c * @sin(r) };
}

/// sRGB (0..1 per channel, gamma-encoded) of an OkLCh colour with its chroma reduced until
/// the colour is inside sRGB.
fn gamutMap(l: f32, c: f32, h: f32) [3]f32 {
    const tol = 0.0005;
    const inside = struct {
        fn f(rgb: [3]f32) bool {
            for (rgb) |v| if (v < -tol or v > 1 + tol) return false;
            return true;
        }
    }.f;
    var lo: f32 = 0;
    var hi: f32 = @max(c, 0);
    var chroma = hi;
    if (!inside(labToLinear(lchToLab(l, hi, h)))) {
        for (0..24) |_| {
            const mid = 0.5 * (lo + hi);
            if (inside(labToLinear(lchToLab(l, mid, h)))) lo = mid else hi = mid;
        }
        chroma = lo;
    }
    const lin = labToLinear(lchToLab(l, chroma, h));
    var out: [3]f32 = undefined;
    for (&out, lin) |*o, v| o.* = linearToSrgb(std.math.clamp(v, 0, 1));
    return out;
}

fn byte(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// WCAG relative luminance of an 8-bit sRGB colour.
pub fn luminance(c: [3]u8) f32 {
    const r = srgbToLinear(@as(f32, @floatFromInt(c[0])) / 255);
    const g = srgbToLinear(@as(f32, @floatFromInt(c[1])) / 255);
    const b = srgbToLinear(@as(f32, @floatFromInt(c[2])) / 255);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// WCAG contrast ratio of two colours (1 to 21).
pub fn contrast(a: [3]u8, b: [3]u8) f32 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

// ---- the image, shrunk ----

pub const Cells = struct {
    lab: [max_cells * max_cells]Lab,
    n: usize,
};

/// Box-averages `rgb` (w x h, three bytes a pixel) in linear light into at most 96x96 cells
/// and converts them to Oklab. Every cell holds about the same number of pixels, so a cell is
/// one unit of weight.
pub fn shrink(rgb: []const u8, w: usize, h: usize, cells: *Cells) void {
    std.debug.assert(w > 0 and h > 0 and rgb.len >= w * h * 3);
    var lut: [256]f32 = undefined;
    for (&lut, 0..) |*v, i| v.* = srgbToLinear(@as(f32, @floatFromInt(i)) / 255);
    const cw = @min(w, max_cells);
    const ch = @min(h, max_cells);
    var n: usize = 0;
    for (0..ch) |cy| {
        const y0 = cy * h / ch;
        const y1 = (cy + 1) * h / ch;
        for (0..cw) |cx| {
            const x0 = cx * w / cw;
            const x1 = (cx + 1) * w / cw;
            var sum = [3]f64{ 0, 0, 0 };
            for (y0..y1) |y| {
                const row = rgb[(y * w + x0) * 3 .. (y * w + x1) * 3];
                var r: f32 = 0;
                var g: f32 = 0;
                var b: f32 = 0;
                var i: usize = 0;
                while (i < row.len) : (i += 3) {
                    r += lut[row[i]];
                    g += lut[row[i + 1]];
                    b += lut[row[i + 2]];
                }
                sum[0] += r;
                sum[1] += g;
                sum[2] += b;
            }
            const count: f64 = @floatFromInt((y1 - y0) * (x1 - x0));
            cells.lab[n] = linearToLab(@floatCast(sum[0] / count), @floatCast(sum[1] / count), @floatCast(sum[2] / count));
            n += 1;
        }
    }
    cells.n = n;
}

// ---- k-means ----

fn dist2(a: Lab, b: Lab) f32 {
    const d0 = a[0] - b[0];
    const d1 = a[1] - b[1];
    const d2 = a[2] - b[2];
    return d0 * d0 + d1 * d1 + d2 * d2;
}

/// Clusters the cells: k-means++ seeding from a fixed seed, at most 20 iterations or until no
/// assignment changes. The clusters come heaviest first; empty ones are dropped.
pub fn cluster(cells: *const Cells, out: *[k_clusters]Cluster) usize {
    const pts = cells.lab[0..cells.n];
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rng = prng.random();

    var centres: [k_clusters]Lab = undefined;
    var d2: [max_cells * max_cells]f32 = undefined;
    var k: usize = 1;
    centres[0] = pts[rng.uintLessThan(usize, pts.len)];
    for (pts, 0..) |p, i| d2[i] = dist2(p, centres[0]);
    while (k < k_clusters) {
        var total: f64 = 0;
        for (d2[0..pts.len]) |v| total += v;
        if (total < 1e-12) break; // fewer distinct colours than clusters
        var pick = rng.float(f64) * total;
        var chosen: usize = pts.len - 1;
        for (d2[0..pts.len], 0..) |v, i| {
            if (v > 0 and pick < v) {
                chosen = i;
                break;
            }
            pick -= v;
        }
        centres[k] = pts[chosen];
        for (pts, 0..) |p, i| d2[i] = @min(d2[i], dist2(p, centres[k]));
        k += 1;
    }

    var owner: [max_cells * max_cells]u8 = @splat(255);
    var counts: [k_clusters]u32 = @splat(0);
    for (0..20) |_| {
        var changed = false;
        for (pts, 0..) |p, i| {
            var best: usize = 0;
            var best_d = std.math.inf(f32);
            for (centres[0..k], 0..) |c, j| {
                const d = dist2(p, c);
                if (d < best_d) {
                    best_d = d;
                    best = j;
                }
            }
            if (owner[i] != best) changed = true;
            owner[i] = @intCast(best);
        }
        if (!changed) break;
        var sums: [k_clusters][3]f64 = @splat(.{ 0, 0, 0 });
        counts = @splat(0);
        for (pts, 0..) |p, i| {
            const j = owner[i];
            counts[j] += 1;
            for (0..3) |c| sums[j][c] += p[c];
        }
        for (0..k) |j| {
            if (counts[j] == 0) continue; // keeps its place
            const n: f64 = @floatFromInt(counts[j]);
            centres[j] = .{ @floatCast(sums[j][0] / n), @floatCast(sums[j][1] / n), @floatCast(sums[j][2] / n) };
        }
    }
    // Counts of the final assignment (the loop may have ended on its iteration limit).
    counts = @splat(0);
    for (owner[0..pts.len]) |j| counts[j] += 1;

    var n: usize = 0;
    for (0..k) |j| {
        if (counts[j] == 0) continue;
        out[n] = .{ .lab = centres[j], .count = counts[j] };
        n += 1;
    }
    // Heaviest first (insertion sort: stable, so ties keep their seeding order).
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const x = out[i];
        var j = i;
        while (j > 0 and out[j - 1].count < x.count) : (j -= 1) out[j] = out[j - 1];
        out[j] = x;
    }
    return n;
}

// ---- roles ----

const Builder = struct {
    overshoot: f32 = 0,

    /// An 8-bit colour of this OkLCh, mapped into sRGB.
    fn rgb(self: *Builder, l: f32, c: f32, h: f32) [3]u8 {
        const f = gamutMap(l, c, h);
        for (f) |v| self.overshoot = @max(self.overshoot, @max(-v, v - 1));
        return .{ byte(f[0]), byte(f[1]), byte(f[2]) };
    }

    fn colour(self: *Builder, l: f32, c: f32, h: f32, alpha: u8) Colour {
        const v = self.rgb(l, c, h);
        return .{ v[0], v[1], v[2], alpha };
    }

    fn fill(self: *Builder, l: f32, c: f32, h: f32) Fill {
        const v = self.rgb(l, c, h);
        return .{ @as(f32, @floatFromInt(v[0])) / 255, @as(f32, @floatFromInt(v[1])) / 255, @as(f32, @floatFromInt(v[2])) / 255, 1 };
    }

    /// Like `rgb`, with the lightness raised in 0.01 steps until it contrasts with `bg` by `min_ratio`.
    fn contrasting(self: *Builder, l0: f32, c: f32, h: f32, bg: [3]u8, min_ratio: f32) [3]u8 {
        var l = l0;
        var v = self.rgb(l, c, h);
        while (contrast(v, bg) < min_ratio and l < 1.0) {
            l += 0.01;
            v = self.rgb(l, c, h);
        }
        return v;
    }
};

fn hueDistance(a: f32, b: f32) f32 {
    const d = @abs(a - b);
    return @min(d, 360 - d);
}

fn wrapHue(h: f32) f32 {
    return @mod(h, 360);
}

/// The scheme for these clusters (heaviest first, at least one).
pub fn assign(clusters: []const Cluster) Result {
    var bld: Builder = .{};
    const base = labToLch(clusters[0].lab);
    const bh = base.h;
    const bc = base.c;

    // Neutrals: the base hue at low chroma.
    const bg3 = bld.rgb(0.16, @min(bc, 0.02), bh);
    var s: Scheme = undefined;
    s.background = bld.fill(0.16, @min(bc, 0.02), bh);
    s.label_backing = bld.colour(0.16, @min(bc, 0.02), bh, 200);
    s.help_backing = bld.colour(0.18, @min(bc, 0.02), bh, 245);
    s.tile_bg = bld.colour(0.19, @min(bc, 0.03), bh, 255);
    s.tile_bg_hover = bld.colour(0.23, @min(bc, 0.03), bh, 255);
    s.heading_idle = bld.colour(0.21, @min(bc, 0.03), bh, 255);
    s.heading_hover = bld.colour(0.32, @min(bc, 0.03), bh, 255);
    s.button_idle = bld.colour(0.27, @min(bc, 0.03), bh, 255);
    s.button_hover = bld.colour(0.34, @min(bc, 0.03), bh, 255);
    s.rule = bld.colour(0.30, @min(bc, 0.03), bh, 255);
    s.panel_divider = bld.fill(0.30, @min(bc, 0.03), bh);
    s.sweep_cursor = bld.fill(0.60, @min(bc, 0.03), bh);
    const tb = bld.contrasting(0.93, @min(bc, 0.02), bh, bg3, 10);
    s.text_bright = .{ tb[0], tb[1], tb[2], 255 };
    s.help_title = s.text_bright;
    const hx = bld.rgb(0.80, @min(bc, 0.02), bh);
    s.help_text = .{ hx[0], hx[1], hx[2], 255 };
    const td = bld.contrasting(0.72, @min(bc, 0.02), bh, bg3, 4.5);
    s.text_dim = .{ td[0], td[1], td[2], 255 };
    s.tile_range_text = bld.colour(0.62, @min(bc, 0.025), bh, 255);

    // Trace colours: the most chromatic, most present clusters, with hues apart.
    var picks: [4]Lch = undefined;
    var np: usize = 0;
    var used: [k_clusters]bool = @splat(false);
    for ([_]f32{ 40, 25 }) |sep| {
        while (np < 4) {
            var best: ?usize = null;
            var best_score: f32 = 0;
            for (clusters, 0..) |c, i| {
                if (used[i]) continue;
                const lch = labToLch(c.lab);
                if (lch.c < 0.04) continue;
                var far = true;
                for (picks[0..np]) |p| if (hueDistance(p.h, lch.h) < sep) {
                    far = false;
                };
                if (!far) continue;
                const score = lch.c * @sqrt(@as(f32, @floatFromInt(c.count)));
                if (best == null or score > best_score) {
                    best = i;
                    best_score = score;
                }
            }
            const i = best orelse break;
            used[i] = true;
            picks[np] = labToLch(clusters[i].lab);
            np += 1;
        }
    }
    // Still short (a dull image): rotate the first pick's hue (or the base hue) in 90 degree steps.
    const first: Lch = if (np > 0) picks[0] else .{ .l = 0.80, .c = 0.12, .h = bh };
    var step: f32 = 1;
    while (np < 4) : (np += 1) {
        picks[np] = .{ .l = first.l, .c = first.c, .h = wrapHue(first.h + 90 * step) };
        step += 1;
    }
    var trace_rgb: [4][3]u8 = undefined;
    for (picks, 0..) |p, i| {
        const l = std.math.clamp(p.l, 0.74, 0.86);
        const c = std.math.clamp(p.c, 0.09, 0.17);
        trace_rgb[i] = bld.contrasting(l, c, p.h, bg3, 6);
        for (0..3) |k| s.trace[i][k] = @as(f32, @floatFromInt(trace_rgb[i][k])) / 255;
    }
    s.tile_wave = .{ trace_rgb[0][0], trace_rgb[0][1], trace_rgb[0][2], 255 };

    // Accent: the first trace colour's hue.
    const ah = picks[0].h;
    const ac = std.math.clamp(picks[0].c, 0.08, 0.14);
    s.button_on = bld.colour(0.45, ac, ah, 255);
    s.button_on_hover = bld.colour(0.52, ac, ah, 255);
    const hk = bld.contrasting(0.82, ac, ah, bg3, 6);
    s.help_key = .{ hk[0], hk[1], hk[2], 255 };
    s.target_bar = bld.fill(0.60, ac, ah);

    var r: Result = .{ .scheme = s, .clusters = undefined, .n_clusters = clusters.len, .base_hue = bh, .overshoot = bld.overshoot };
    @memcpy(r.clusters[0..clusters.len], clusters);
    return r;
}

/// The scheme of an image: `rgb` is w x h pixels of three bytes. Null for an empty image.
pub fn derive(rgb: []const u8, w: usize, h: usize) ?Result {
    if (w == 0 or h == 0 or rgb.len < w * h * 3) return null;
    var cells: Cells = undefined;
    shrink(rgb, w, h, &cells);
    return deriveCells(&cells);
}

pub fn deriveCells(cells: *const Cells) Result {
    var cl: [k_clusters]Cluster = undefined;
    const n = cluster(cells, &cl);
    return assign(cl[0..n]);
}

// ---- files ----

pub const Image = struct {
    w: usize,
    h: usize,
    /// Three bytes a pixel; freed with `deinit`.
    rgb: []const u8,

    pub fn deinit(self: Image) void {
        stb.stbi_image_free(@ptrCast(@constCast(self.rgb.ptr)));
    }
};

pub const DecodeError = error{ NotAnImage, TooLarge };

/// Decodes a JPEG or PNG held in memory, as three channels.
pub fn decode(bytes: []const u8) DecodeError!Image {
    if (bytes.len == 0 or bytes.len > max_file_bytes) return error.TooLarge;
    var w: c_int = 0;
    var h: c_int = 0;
    var n: c_int = 0;
    const p = stb.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &n, 3) orelse return error.NotAnImage;
    return .{ .w = @intCast(w), .h = @intCast(h), .rgb = p[0 .. @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 3] };
}

/// Why a scheme image could not be used: one line for the log.
pub const Diagnostics = struct {
    buf: [600]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diagnostics) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Diagnostics, comptime fmt: []const u8, args: anytype) void {
        const text: []const u8 = std.fmt.bufPrint(&self.buf, fmt, args) catch self.buf[0..];
        self.len = text.len;
    }
};

/// Where the config's `scheme_image` is: `~/` is the home folder, a relative path is
/// relative to the config file's folder. Null if it does not fit `buf`.
pub fn resolvePath(buf: []u8, path: []const u8, home: []const u8, config_dir: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, path, "~/")) return std.fmt.bufPrint(buf, "{s}/{s}", .{ home, path[2..] }) catch null;
    if (std.mem.startsWith(u8, path, "/")) return std.fmt.bufPrint(buf, "{s}", .{path}) catch null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ config_dir, path }) catch null;
}

/// Reads and decodes the image at `path` (already resolved).
pub fn loadImage(io: Io, gpa: std.mem.Allocator, path: []const u8, diag: *Diagnostics) ?Image {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch |e| {
        diag.set("scheme image '{s}': {s}", .{ path, switch (e) {
            error.FileNotFound => "no such file",
            error.StreamTooLong => "the file is over 64 MB",
            else => @errorName(e),
        } });
        return null;
    };
    defer gpa.free(bytes);
    return decode(bytes) catch |e| {
        diag.set("scheme image '{s}': {s}", .{ path, switch (e) {
            error.NotAnImage => "not a JPEG or PNG that could be decoded",
            error.TooLarge => "empty or over 64 MB",
        } });
        return null;
    };
}

/// The scheme of the image at `path` (already resolved), or null with the reason in `diag`.
pub fn loadFile(io: Io, gpa: std.mem.Allocator, path: []const u8, diag: *Diagnostics) ?Result {
    const img = loadImage(io, gpa, path, diag) orelse return null;
    defer img.deinit();
    return derive(img.rgb, img.w, img.h) orelse {
        diag.set("scheme image '{s}': the image has no pixels", .{path});
        return null;
    };
}

// ---- printing and the swatch ----

pub const Entry = struct { name: []const u8, rgb: [3]u8, alpha: u8 = 255 };

fn fillEntry(name: []const u8, f: Fill) Entry {
    return .{ .name = name, .rgb = .{ byte(f[0]), byte(f[1]), byte(f[2]) } };
}

fn colourEntry(name: []const u8, c: Colour) Entry {
    return .{ .name = name, .rgb = .{ c[0], c[1], c[2] }, .alpha = c[3] };
}

pub const n_entries = 22;

/// Every themed colour with its name, for printing and the swatch.
pub fn entries(s: *const Scheme) [n_entries]Entry {
    return .{
        fillEntry("background", s.background),
        colourEntry("label_backing", s.label_backing),
        colourEntry("help_backing", s.help_backing),
        colourEntry("tile_bg", s.tile_bg),
        colourEntry("tile_bg_hover", s.tile_bg_hover),
        colourEntry("heading_idle", s.heading_idle),
        colourEntry("heading_hover", s.heading_hover),
        colourEntry("button_idle", s.button_idle),
        colourEntry("button_hover", s.button_hover),
        colourEntry("button_on", s.button_on),
        colourEntry("button_on_hover", s.button_on_hover),
        colourEntry("rule", s.rule),
        fillEntry("panel_divider", s.panel_divider),
        fillEntry("sweep_cursor", s.sweep_cursor),
        fillEntry("target_bar", s.target_bar),
        colourEntry("text_bright", s.text_bright),
        colourEntry("help_title", s.help_title),
        colourEntry("help_text", s.help_text),
        colourEntry("text_dim", s.text_dim),
        colourEntry("tile_range_text", s.tile_range_text),
        colourEntry("help_key", s.help_key),
        colourEntry("tile_wave", s.tile_wave),
    };
}

pub fn traceRgb(s: *const Scheme, i: usize) [3]u8 {
    return .{ byte(s.trace[i][0]), byte(s.trace[i][1]), byte(s.trace[i][2]) };
}

/// The text `--print-scheme` prints: each colour, the cluster centres, the contrasts.
pub fn describe(w: *Io.Writer, r: *const Result) !void {
    const bg = entries(&r.scheme)[0].rgb;
    try w.print("base hue {d:.0} deg; clusters (heaviest first):\n", .{r.base_hue});
    for (r.clusters[0..r.n_clusters]) |c| {
        const lch = labToLch(c.lab);
        const g = gamutMap(lch.l, lch.c, lch.h);
        try w.print("  #{x:0>2}{x:0>2}{x:0>2}  weight {d:>5}  L {d:.2} C {d:.3} h {d:>3.0}\n", .{ byte(g[0]), byte(g[1]), byte(g[2]), c.count, lch.l, lch.c, lch.h });
    }
    try w.writeAll("colours:\n");
    for (entries(&r.scheme)) |e| {
        try w.print("  {s:<16} #{x:0>2}{x:0>2}{x:0>2}", .{ e.name, e.rgb[0], e.rgb[1], e.rgb[2] });
        if (e.alpha != 255) try w.print("  alpha {d}", .{e.alpha});
        try w.writeAll("\n");
    }
    for (0..4) |i| {
        const t = traceRgb(&r.scheme, i);
        try w.print("  trace {d}           #{x:0>2}{x:0>2}{x:0>2}  contrast {d:.1}\n", .{ i, t[0], t[1], t[2], contrast(t, bg) });
    }
    const e = entries(&r.scheme);
    try w.print("contrast with the background: text_bright {d:.1}, text_dim {d:.1}, help_key {d:.1}\n", .{
        contrast(e[15].rgb, bg), contrast(e[18].rgb, bg), contrast(e[20].rgb, bg),
    });
    try w.print("largest excursion outside sRGB before rounding: {d:.5}\n", .{r.overshoot});
}

pub const swatch_w = 800;
pub const swatch_h = 400;

/// Draws the swatch: the background, a grid of every themed colour, and four noise traces in
/// the trace colours over it. `pixels` is swatch_w x swatch_h x 3.
pub fn drawSwatch(pixels: []u8, s: *const Scheme) void {
    std.debug.assert(pixels.len == swatch_w * swatch_h * 3);
    const es = entries(s);
    const bg = es[0].rgb;
    var i: usize = 0;
    while (i < pixels.len) : (i += 3) @memcpy(pixels[i .. i + 3], &bg);
    // Eight swatches a row, 100 x 36 px each with a 4 px gap, over the background.
    for (es, 0..) |e, n| {
        const x0 = (n % 8) * 100 + 4;
        const y0 = (n / 8) * 40 + 4;
        for (y0..y0 + 36) |y| for (x0..x0 + 92) |x| {
            const o = (y * swatch_w + x) * 3;
            for (0..3) |c| {
                const a: f32 = @as(f32, @floatFromInt(e.alpha)) / 255;
                const v = @as(f32, @floatFromInt(e.rgb[c])) * a + @as(f32, @floatFromInt(bg[c])) * (1 - a);
                pixels[o + c] = @intFromFloat(@round(v));
            }
        };
    }
    // Four traces, a random walk with spikes, each in its own band below the swatches.
    var prng = std.Random.DefaultPrng.init(0xc01);
    const rng = prng.random();
    const top = 136;
    const band = (swatch_h - top) / 4;
    for (0..4) |t| {
        const col = traceRgb(s, t);
        const centre: f32 = @floatFromInt(top + t * band + band / 2);
        var prev: f32 = centre;
        for (0..swatch_w) |x| {
            var y = centre + (rng.float(f32) - 0.5) * 10;
            if (rng.float(f32) < 0.012) y += (rng.float(f32) - 0.7) * @as(f32, @floatFromInt(band)) * 0.9;
            const lo: usize = @intFromFloat(std.math.clamp(@min(y, prev), @as(f32, @floatFromInt(top + t * band)), @as(f32, @floatFromInt(swatch_h - 1))));
            const hi: usize = @intFromFloat(std.math.clamp(@max(y, prev), @as(f32, @floatFromInt(top + t * band)), @as(f32, @floatFromInt(swatch_h - 1))));
            for (lo..hi + 1) |yy| @memcpy(pixels[(yy * swatch_w + x) * 3 ..][0..3], &col);
            prev = y;
        }
    }
}

fn pngSink(ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
    const list: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx.?));
    const p: [*]const u8 = @ptrCast(data.?);
    list.appendSlice(sink_gpa, p[0..@intCast(size)]) catch {
        sink_failed = true;
    };
}
var sink_gpa: std.mem.Allocator = undefined;
var sink_failed = false;

/// PNG bytes of an RGB image; freed by the caller.
pub fn encodePng(gpa: std.mem.Allocator, pixels: []const u8, w: usize, h: usize) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    sink_gpa = gpa;
    sink_failed = false;
    const ok = stb.stbi_write_png_to_func(pngSink, &list, @intCast(w), @intCast(h), 3, pixels.ptr, @intCast(w * 3));
    if (ok == 0 or sink_failed) return error.PngEncodeFailed;
    return list.toOwnedSlice(gpa);
}

/// `dimna --print-scheme IMAGE [--swatch OUT.png]`: prints the scheme and the times, writes
/// the swatch. The exit code.
pub fn printCommand(io: Io, gpa: std.mem.Allocator, image_path: []const u8, swatch_path: []const u8) u8 {
    var diag: Diagnostics = .{};
    const t0 = dimna.clock.nowNs();
    const img = loadImage(io, gpa, image_path, &diag) orelse {
        std.debug.print("{s}\n", .{diag.message()});
        return 1;
    };
    defer img.deinit();
    const t1 = dimna.clock.nowNs();
    var cells: Cells = undefined;
    shrink(img.rgb, img.w, img.h, &cells);
    const t2 = dimna.clock.nowNs();
    const r = deriveCells(&cells);
    const t3 = dimna.clock.nowNs();

    var buf: [8192]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    describe(&w, &r) catch {};
    w.print("image {d}x{d}: decode {d:.1} ms, shrink {d:.1} ms, cluster and roles {d:.2} ms\n", .{
        img.w,                                  img.h,
        @as(f64, @floatFromInt(t1 - t0)) / 1e6, @as(f64, @floatFromInt(t2 - t1)) / 1e6,
        @as(f64, @floatFromInt(t3 - t2)) / 1e6,
    }) catch {};
    Io.File.stdout().writeStreamingAll(io, w.buffered()) catch {};

    if (swatch_path.len > 0) {
        const pixels = gpa.alloc(u8, swatch_w * swatch_h * 3) catch return 1;
        defer gpa.free(pixels);
        drawSwatch(pixels, &r.scheme);
        const png = encodePng(gpa, pixels, swatch_w, swatch_h) catch {
            std.debug.print("swatch: could not encode the PNG\n", .{});
            return 1;
        };
        defer gpa.free(png);
        files.writeAtomic(io, swatch_path, png) catch |e| {
            std.debug.print("swatch '{s}': {t}\n", .{ swatch_path, e });
            return 1;
        };
        std.debug.print("swatch written to {s}\n", .{swatch_path});
    }
    return 0;
}

// ---- tests ----

const testing = std.testing;

/// A w x h image of pixels from `f(x, y)`, three bytes each.
fn makeImage(comptime w: usize, comptime h: usize, comptime f: fn (usize, usize) [3]u8) [w * h * 3]u8 {
    var img: [w * h * 3]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        img[(y * w + x) * 3 ..][0..3].* = f(x, y);
    };
    return img;
}

fn plain(_: usize, _: usize) [3]u8 {
    return .{ 200, 60, 60 };
}
fn greys(x: usize, _: usize) [3]u8 {
    const v: u8 = @intCast(x * 255 / 119);
    return .{ v, v, v };
}
fn twoHues(x: usize, _: usize) [3]u8 {
    return if (x < 60) .{ 30, 60, 200 } else .{ 220, 170, 30 };
}
fn rainbow(x: usize, y: usize) [3]u8 {
    const h: f32 = @as(f32, @floatFromInt(x)) / 120.0 * 6;
    const k: usize = @intFromFloat(h);
    const f: f32 = h - @as(f32, @floatFromInt(k));
    const up: u8 = @intFromFloat(255 * f);
    const down: u8 = 255 - up;
    _ = y;
    return switch (k % 6) {
        0 => .{ 255, up, 0 },
        1 => .{ down, 255, 0 },
        2 => .{ 0, 255, up },
        3 => .{ 0, down, 255 },
        4 => .{ up, 0, 255 },
        else => .{ 255, 0, down },
    };
}
fn nearBlack(x: usize, y: usize) [3]u8 {
    return .{ @intCast(x % 3), @intCast(y % 4), 2 };
}
fn nearWhite(x: usize, y: usize) [3]u8 {
    return .{ @intCast(255 - x % 3), @intCast(254 - y % 3), 253 };
}

fn checkGuarantees(r: Result) !void {
    const bg = entries(&r.scheme)[0].rgb;
    const es = entries(&r.scheme);
    try testing.expect(contrast(es[15].rgb, bg) >= 10); // text_bright
    try testing.expect(contrast(es[18].rgb, bg) >= 4.5); // text_dim
    try testing.expect(contrast(es[20].rgb, bg) >= 6); // help_key
    for (0..4) |i| try testing.expect(contrast(traceRgb(&r.scheme, i), bg) >= 6);
    try testing.expect(r.overshoot <= 0.001);
}

test "the contrast guarantees hold on synthetic images" {
    const imgs = .{
        makeImage(120, 80, plain),
        makeImage(120, 80, greys),
        makeImage(120, 80, twoHues),
        makeImage(120, 80, rainbow),
        makeImage(120, 80, nearBlack),
        makeImage(120, 80, nearWhite),
    };
    inline for (imgs) |img| try checkGuarantees(derive(&img, 120, 80).?);
}

test "the same pixels give the same scheme" {
    const img = makeImage(120, 80, rainbow);
    const a = derive(&img, 120, 80).?;
    const b = derive(&img, 120, 80).?;
    try testing.expectEqualDeep(a.scheme, b.scheme);
    try testing.expectEqualDeep(a.clusters, b.clusters);
}

test "trace hues are at least 25 degrees apart when the image has four distinct hues" {
    const img = makeImage(120, 80, rainbow);
    const r = derive(&img, 120, 80).?;
    var hues: [4]f32 = undefined;
    for (0..4) |i| {
        const t = r.scheme.trace[i];
        const lin = [3]f32{ srgbToLinear(t[0]), srgbToLinear(t[1]), srgbToLinear(t[2]) };
        hues[i] = labToLch(linearToLab(lin[0], lin[1], lin[2])).h;
    }
    for (0..4) |i| for (i + 1..4) |j| try testing.expect(hueDistance(hues[i], hues[j]) >= 25);
}

test "trace hues stay apart when the image's strongest colours are close in hue" {
    // Three oranges of nearly one hue make up most of the image; green, blue and magenta
    // are small. Picking by strength alone would take the three oranges.
    const f = struct {
        fn f(x: usize, _: usize) [3]u8 {
            return if (x < 25) .{ 230, 60, 40 } else if (x < 50) .{ 230, 90, 40 } else if (x < 75) .{ 230, 120, 40 } else if (x < 90) .{ 40, 200, 80 } else if (x < 105) .{ 50, 90, 230 } else .{ 200, 60, 200 };
        }
    }.f;
    const img = makeImage(120, 80, f);
    const r = derive(&img, 120, 80).?;
    var hues: [4]f32 = undefined;
    for (0..4) |i| {
        const t = r.scheme.trace[i];
        hues[i] = labToLch(linearToLab(srgbToLinear(t[0]), srgbToLinear(t[1]), srgbToLinear(t[2]))).h;
    }
    for (0..4) |i| for (i + 1..4) |j| try testing.expect(hueDistance(hues[i], hues[j]) >= 25);
}

test "the first trace colour is the strongest pick, with the others apart from it" {
    // Blue is half the image, amber a quarter, green a quarter: blue leads.
    const f = struct {
        fn f(x: usize, _: usize) [3]u8 {
            return if (x < 60) .{ 20, 50, 220 } else if (x < 90) .{ 230, 170, 20 } else .{ 30, 200, 60 };
        }
    }.f;
    const img = makeImage(120, 80, f);
    const r = derive(&img, 120, 80).?;
    const t = r.scheme.trace[0];
    try testing.expect(t[2] > t[0] and t[2] > t[1]);
}

test "every colour is inside sRGB as mapped, with nothing clamped" {
    const imgs = .{ makeImage(120, 80, rainbow), makeImage(120, 80, twoHues), makeImage(120, 80, plain) };
    inline for (imgs) |img| {
        const r = derive(&img, 120, 80).?;
        try testing.expect(r.overshoot <= 0.001);
    }
}

test "k-means on a two-colour image finds both colours" {
    const img = makeImage(120, 80, twoHues);
    const r = derive(&img, 120, 80).?;
    try testing.expectEqual(@as(usize, 2), r.n_clusters);
    try testing.expectEqual(@as(u32, 48 * 80), r.clusters[0].count);
    try testing.expectEqual(@as(u32, 48 * 80), r.clusters[1].count);
    // The centres are the two colours: compare in Oklab.
    const want = [2]Lab{
        linearToLab(srgbToLinear(30.0 / 255.0), srgbToLinear(60.0 / 255.0), srgbToLinear(200.0 / 255.0)),
        linearToLab(srgbToLinear(220.0 / 255.0), srgbToLinear(170.0 / 255.0), srgbToLinear(30.0 / 255.0)),
    };
    for (want) |w| {
        var near = false;
        for (r.clusters[0..2]) |c| near = near or dist2(c.lab, w) < 1e-4;
        try testing.expect(near);
    }
}

test "the neutrals follow the base hue and stay dark" {
    const img = makeImage(120, 80, twoHues);
    const r = derive(&img, 120, 80).?;
    const bg = r.scheme.background;
    try testing.expect(bg[0] < 0.2 and bg[1] < 0.2 and bg[2] < 0.2);
    try testing.expectEqual(@as(f32, 1), bg[3]);
}

test "resolvePath expands ~/ and a relative path" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/home/a/pics/x.jpg", resolvePath(&buf, "~/pics/x.jpg", "/home/a", "/cfg").?);
    try testing.expectEqualStrings("/cfg/x.jpg", resolvePath(&buf, "x.jpg", "/home/a", "/cfg").?);
    try testing.expectEqualStrings("/abs/x.jpg", resolvePath(&buf, "/abs/x.jpg", "/home/a", "/cfg").?);
}

test "a missing scheme image gives no scheme and a warning that names the file" {
    var diag: Diagnostics = .{};
    const r = loadFile(testing.io, testing.allocator, "/nonexistent-dimna-test/none.png", &diag);
    try testing.expect(r == null);
    try testing.expect(std.mem.indexOf(u8, diag.message(), "/nonexistent-dimna-test/none.png") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message(), "no such file") != null);
}

test "something that is not an image is refused" {
    try testing.expectError(error.NotAnImage, decode("this is not an image at all"));
}

test "a PNG written by the swatch encoder decodes back to the same pixels" {
    var px: [4 * 3 * 3]u8 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast(i * 7);
    const png = try encodePng(testing.allocator, &px, 4, 3);
    defer testing.allocator.free(png);
    const img = try decode(png);
    defer img.deinit();
    try testing.expectEqual(@as(usize, 4), img.w);
    try testing.expectEqual(@as(usize, 3), img.h);
    try testing.expectEqualSlices(u8, &px, img.rgb);
}
