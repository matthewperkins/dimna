//! The spike detection threshold of every electrode: one per channel, for what the spike
//! tiles show and what a triggered panel's slope trigger triggers on alike.
//!
//! A channel's threshold either follows the noise, `-sigmas` times that channel's sigma
//! (`sigmas` one number for all channels), or is fixed: a signed number of µV whose sign
//! is the slope. A negative threshold is crossed falling (a trough follows), a positive one
//! rising (a peak follows). The display thread owns these; the tile window is told them.
//!
//! In views.toml:
//!
//!   [thresholds]
//!   sigmas = 4.5                  # 4, 4.5, 5, 5.5 or 6
//!   fixed_uv = [0, -62.5, 80]     # per electrode, in order: µV, the sign the slope;
//!                                 # 0 = that channel follows the noise

const std = @import("std");
const toml = @import("toml.zig");

pub const max = @import("tile_view.zig").max_tiles;

/// The values `sigmas` can take.
pub const sigma_steps = [_]f32{ 4, 4.5, 5, 5.5, 6 };

/// The span of a fixed threshold's size, µV.
pub const min_uv = 5.0;
pub const max_uv = 5000.0;

/// What the tile window last reported: every electrode's threshold in use, µV. The first
/// `len` are valid.
pub const Reported = struct {
    uv: [max]f32 = @splat(0),
    len: usize = 0,

    pub fn get(self: *const Reported, ch: usize) ?f32 {
        return if (ch < self.len) self.uv[ch] else null;
    }
};

pub const Thresholds = struct {
    /// Below zero, in sigmas, for every channel that follows the noise.
    sigmas: f32 = 4.5,
    /// Per electrode: the fixed threshold in µV, or 0 (follows the noise).
    fixed_uv: [max]f32 = @splat(0),

    pub fn isFixed(self: *const Thresholds, ch: usize) bool {
        return ch < max and self.fixed_uv[ch] != 0;
    }

    /// The threshold of channel `ch` in the unit `sigma` (that channel's noise) is in, of
    /// which one is `uv_per_unit` µV (1 for µV, `types.electrode_uv_per_bit` for samples).
    /// A fixed threshold is converted; one that follows the noise is `-sigmas * sigma`.
    pub fn level(self: *const Thresholds, ch: usize, sigma: f64, uv_per_unit: f64) f64 {
        if (self.isFixed(ch)) return self.fixed_uv[ch] / uv_per_unit;
        return -@as(f64, self.sigmas) * sigma;
    }

    /// The threshold of channel `ch` in µV, given that channel's noise sigma in µV.
    pub fn levelUv(self: *const Thresholds, ch: usize, sigma_uv: f64) f64 {
        return self.level(ch, sigma_uv, 1);
    }

    /// The threshold in µV if it is known: the fixed value, or else what the tile window
    /// reported for that channel.
    pub fn known(self: *const Thresholds, reported: *const Reported, ch: usize) ?f32 {
        if (self.isFixed(ch)) return self.fixed_uv[ch];
        return reported.get(ch);
    }

    /// One step up or down through `sigma_steps` (from a value between two steps, to the
    /// next one in that direction).
    pub fn stepSigmas(self: *Thresholds, up: bool) void {
        if (up) {
            for (sigma_steps) |s| {
                if (s > self.sigmas) {
                    self.sigmas = s;
                    return;
                }
            }
        } else {
            var i = sigma_steps.len;
            while (i > 0) {
                i -= 1;
                if (sigma_steps[i] < self.sigmas) {
                    self.sigmas = sigma_steps[i];
                    return;
                }
            }
        }
    }

    /// Fixes channel `ch` at `uv` (its sign the slope), its size kept within `min_uv` to
    /// `max_uv`. 0 (or not a number) returns it to the noise.
    pub fn set(self: *Thresholds, ch: usize, uv: f64) void {
        if (ch >= max) return;
        if (uv == 0 or !std.math.isFinite(uv)) {
            self.fixed_uv[ch] = 0;
            return;
        }
        const size = std.math.clamp(@abs(uv), min_uv, max_uv);
        self.fixed_uv[ch] = @floatCast(if (uv < 0) -size else size);
    }

    /// Returns channel `ch` to the noise.
    pub fn follow(self: *Thresholds, ch: usize) void {
        self.set(ch, 0);
    }

    pub fn eql(a: *const Thresholds, b: *const Thresholds) bool {
        return a.sigmas == b.sigmas and std.mem.eql(f32, &a.fixed_uv, &b.fixed_uv);
    }

    /// Reads the `[thresholds]` table of a view file. Anything missing or wrong keeps its
    /// default: an old or hand-edited file must not stop the program.
    pub fn read(doc: toml.Document) Thresholds {
        var t: Thresholds = .{};
        if (doc.number("thresholds", 0, "sigmas")) |s| {
            for (sigma_steps) |step| {
                if (s == step) t.sigmas = step;
            }
        }
        if (doc.numbers("thresholds", 0, "fixed_uv")) |list| {
            for (list, 0..) |x, i| {
                if (i < max and std.math.isFinite(x) and @abs(x) >= min_uv and @abs(x) <= max_uv) t.fixed_uv[i] = @floatCast(x);
            }
        }
        return t;
    }

    /// Writes the `[thresholds]` table for `n` electrodes.
    pub fn render(self: *const Thresholds, w: *std.Io.Writer, n: usize) !void {
        try w.print("\n[thresholds]\nsigmas = {d}\nfixed_uv = [", .{self.sigmas});
        for (self.fixed_uv[0..@min(n, max)], 0..) |v, i| {
            if (i > 0) try w.writeAll(", ");
            // To a hundredth of a µV, as the tiles' ranges.
            try w.print("{d}", .{@round(@as(f64, v) * 100) / 100});
        }
        try w.writeAll("]\n");
    }
};

const testing = std.testing;

test "a threshold follows the noise or is fixed, its sign the slope" {
    var t: Thresholds = .{};
    try testing.expect(!t.isFixed(3));
    // 4.5 sigma below zero, in whatever unit sigma is in.
    try testing.expectEqual(-45.0, t.levelUv(3, 10));
    try testing.expectEqual(-4.5 * 7.0, t.level(3, 7, 0.195));
    t.set(3, -62);
    try testing.expect(t.isFixed(3));
    try testing.expectEqual(-62.0, t.levelUv(3, 10));
    // In sample units: µV over µV per LSB.
    try testing.expectEqual(@as(f64, -62.0) / 0.195, t.level(3, 7, 0.195));
    t.set(4, 80);
    try testing.expectEqual(80.0, t.levelUv(4, 10));
    // Clamped in size, either sign; 0 and follow() go back to the noise.
    t.set(5, -1);
    try testing.expectEqual(-5.0, t.fixed_uv[5]);
    t.set(5, 1e6);
    try testing.expectEqual(5000.0, t.fixed_uv[5]);
    t.set(5, 0);
    try testing.expect(!t.isFixed(5));
    t.follow(3);
    try testing.expect(!t.isFixed(3));
    t.set(5, std.math.nan(f64));
    try testing.expect(!t.isFixed(5));
    // Beyond the channels there are: nothing, and never fixed.
    t.set(max, -50);
    try testing.expect(!t.isFixed(max));
    // Known: fixed, else the reported value, else not known.
    var r: Reported = .{};
    try testing.expectEqual(null, t.known(&r, 0));
    r.uv[0] = -33;
    r.uv[4] = -21;
    r.len = 5;
    try testing.expectEqual(-33, t.known(&r, 0).?);
    try testing.expectEqual(80, t.known(&r, 4).?);
    try testing.expectEqual(null, t.known(&r, 5));
}

test "sigmas steps through 4 to 6 by halves, and stops at the ends" {
    var t: Thresholds = .{};
    t.stepSigmas(true);
    try testing.expectEqual(5, t.sigmas);
    t.stepSigmas(true);
    t.stepSigmas(true);
    t.stepSigmas(true);
    try testing.expectEqual(6, t.sigmas);
    for (0..6) |_| t.stepSigmas(false);
    try testing.expectEqual(4, t.sigmas);
    t.sigmas = 4.7;
    t.stepSigmas(false);
    try testing.expectEqual(4.5, t.sigmas);
}

test "the thresholds are written and read back the same; nonsense gives the defaults" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var t: Thresholds = .{ .sigmas = 5.5 };
    t.set(1, -62.5);
    t.set(3, 80.123);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try t.render(&w, 4);
    try testing.expectEqualStrings("\n[thresholds]\nsigmas = 5.5\nfixed_uv = [0, -62.5, 0, 80.12]\n", w.buffered());
    const back = Thresholds.read(try toml.parse(a, w.buffered(), null));
    try testing.expectEqual(5.5, back.sigmas);
    try testing.expectEqual(-62.5, back.fixed_uv[1]);
    try testing.expectApproxEqAbs(80.12, back.fixed_uv[3], 1e-4);
    try testing.expect(!back.isFixed(0) and !back.isFixed(2));
    // A file without the table, or with nonsense in it.
    const none: Thresholds = .{};
    try testing.expect(Thresholds.read(try toml.parse(a, "", null)).eql(&none));
    const odd = Thresholds.read(try toml.parse(a, "[thresholds]\nsigmas = 4.7\nfixed_uv = [2, -1e9, -40, 7000]", null));
    try testing.expectEqual(4.5, odd.sigmas);
    try testing.expect(!odd.isFixed(0) and !odd.isFixed(1) and !odd.isFixed(3));
    try testing.expectEqual(-40, odd.fixed_uv[2]);
    const wrong = Thresholds.read(try toml.parse(a, "[thresholds]\nsigmas = \"high\"\nfixed_uv = 3", null));
    try testing.expect(wrong.eql(&none));
}
