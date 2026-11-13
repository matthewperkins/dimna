//! Spike detection for the tiles: every electrode channel band-passed 300 Hz to 6 kHz,
//! a threshold that follows the noise (a multiple of sigma, sigma from a running median
//! of the absolute signal, so spikes hardly move it), each crossing aligned on the trough
//! that follows, and the waveform around it kept: the last few per channel, to be drawn
//! on top of each other.
//!
//! The same detection as a panel's slope trigger (slope.zig), for all channels at once
//! and keeping the waveforms. It runs on the tile window's thread; nothing here reaches
//! the recording.

const std = @import("std");
const dsp = @import("dsp.zig");

pub const max_waves = 16;
pub const max_len = 64;
const hist_len = 256;

/// A common average reference for the detection: for each channel, which group's mean
/// is subtracted from it (-1: none), and the channels each group averages.
pub const Car = struct {
    pub const max_groups = 16;
    pub const max_ref = 64;
    group_of: [512]i8 = @splat(-1),
    ref: [max_groups][max_ref]u32 = undefined,
    ref_len: [max_groups]u8 = @splat(0),
};

pub const Unit = struct {
    band: dsp.Band,
    state: dsp.Band.State = @splat(.{}),
    started: bool = false,
    seen: u64 = 0,
    /// Running estimate of median(|x|) of the filtered signal, in sample units.
    mad: f64 = 0,
    prev: f64 = 0,
    searching: bool = false,
    cross_at: i64 = 0,
    best: f64 = 0,
    best_at: i64 = 0,
    dead_until: i64 = std.math.minInt(i64),
    /// The filtered signal's last samples, by sample number.
    hist: [hist_len]f32 = @splat(0),
    /// A spike found at `capture_t0` whose waveform is complete at sample `capture_at`.
    capture_at: ?i64 = null,
    capture_t0: i64 = 0,
    /// The last waveforms (a ring; `wave_count` is how many there have been in all).
    waves: [max_waves][max_len]f32 = undefined,
    wave_count: u64 = 0,
    /// Spikes in the second being counted, and the rate shown (spikes/s, smoothed).
    second_count: u32 = 0,
    rate: f32 = 0,

    pub fn sigma(self: *const Unit) f64 {
        return self.mad / 0.6745;
    }

    /// The `i`-th most recent waveform (0 = newest).
    pub fn wave(self: *const Unit, i: usize) ?*const [max_len]f32 {
        if (i >= @min(self.wave_count, max_waves)) return null;
        return &self.waves[@intCast((self.wave_count - 1 - i) % max_waves)];
    }
};

pub const Detector = struct {
    gpa: std.mem.Allocator,
    fs: f64,
    units: []Unit,
    /// The threshold, in sigmas below zero.
    sigmas: f64 = 4.5,
    /// Samples of a waveform before its trough, and in all.
    pre: usize,
    len: usize,
    /// Scratch: each reference group's mean for the samples of one block.
    means: []f64 = &.{},
    seconds_end: i64 = 0,
    /// Set when a waveform was added or a rate changed; cleared by whoever draws.
    changed: bool = false,

    /// For the first `n` channels of a sample (the electrodes).
    pub fn init(gpa: std.mem.Allocator, fs: f64, n: usize) !Detector {
        const units = try gpa.alloc(Unit, n);
        for (units) |*u| u.* = .{ .band = .init(300, 6000, fs) };
        const len: usize = @min(max_len, @as(usize, @intFromFloat(@round(1.6e-3 * fs))));
        return .{ .gpa = gpa, .fs = fs, .units = units, .pre = @min(len / 3, @as(usize, @intFromFloat(@round(0.4e-3 * fs)))), .len = len };
    }

    pub fn deinit(self: *Detector) void {
        self.gpa.free(self.units);
        self.gpa.free(self.means);
    }

    /// The threshold of a unit, in sample units (negative).
    pub fn threshold(self: *const Detector, u: *const Unit) f64 {
        return -self.sigmas * u.sigma();
    }

    /// Takes a block of `nch` interleaved samples that starts at sample number `first`.
    pub fn feed(self: *Detector, first: i64, samples: []const i16, nch: usize, car: ?*const Car) !void {
        const count = samples.len / nch;
        if (count == 0) return;
        // The reference groups' means, sample by sample.
        if (car) |c| {
            if (self.means.len < Car.max_groups * count) {
                self.gpa.free(self.means);
                self.means = &.{};
                self.means = try self.gpa.alloc(f64, Car.max_groups * count);
            }
            for (0..Car.max_groups) |g| {
                const n = c.ref_len[g];
                if (n == 0) continue;
                const mean = self.means[g * count ..][0..count];
                @memset(mean, 0);
                for (c.ref[g][0..n]) |rc| {
                    if (rc >= nch) continue;
                    for (mean, 0..) |*m, i| m.* += @floatFromInt(samples[i * nch + rc]);
                }
                for (mean) |*m| m.* /= @floatFromInt(n);
            }
        }
        const align_n: i64 = @intFromFloat(@round(0.0005 * self.fs));
        const dead_n: i64 = @intFromFloat(@round(0.001 * self.fs));
        const warm: u64 = @intFromFloat(0.02 * self.fs);
        const post: i64 = @intCast(self.len - self.pre);
        for (self.units, 0..) |*u, ch| {
            if (ch >= nch) break;
            const group: i8 = if (car) |c| (if (ch < c.group_of.len) c.group_of[ch] else -1) else -1;
            const mean: ?[]const f64 = if (group >= 0 and car.?.ref_len[@intCast(group)] > 0)
                self.means[@as(usize, @intCast(group)) * count ..][0..count]
            else
                null;
            if (!u.started) {
                u.band.settle(&u.state, @as(f64, @floatFromInt(samples[ch])) - (if (mean) |m| m[0] else 0));
                u.started = true;
            }
            for (0..count) |i| {
                const n = first + @as(i64, @intCast(i));
                const x = @as(f64, @floatFromInt(samples[i * nch + ch])) - (if (mean) |m| m[i] else 0);
                const y = u.band.step(&u.state, x);
                u.hist[@intCast(@as(u64, @bitCast(n)) % hist_len)] = @floatCast(y);
                // The median of |y| by small steps towards it (see slope.zig).
                const a = @abs(y);
                if (u.seen < 64) {
                    u.mad += (a - u.mad) / @as(f64, @floatFromInt(u.seen + 1));
                } else {
                    const stride = @max(u.mad, 0.5) * 0.001;
                    u.mad += if (a > u.mad) stride else -stride;
                }
                u.seen += 1;
                // A waveform whose last sample has now arrived.
                if (u.capture_at) |at| {
                    if (n >= at) {
                        const w = &u.waves[@intCast(u.wave_count % max_waves)];
                        for (0..self.len) |k| {
                            const s = u.capture_t0 - @as(i64, @intCast(self.pre)) + @as(i64, @intCast(k));
                            w[k] = u.hist[@intCast(@as(u64, @bitCast(s)) % hist_len)];
                        }
                        u.wave_count += 1;
                        u.second_count += 1;
                        u.capture_at = null;
                        self.changed = true;
                    }
                }
                const level = -self.sigmas * u.mad / 0.6745;
                if (u.searching) {
                    if (y < u.best) {
                        u.best = y;
                        u.best_at = n;
                    }
                    if (n - u.cross_at >= align_n) {
                        u.searching = false;
                        u.dead_until = u.best_at + dead_n;
                        // One waveform at a time: a spike inside another's window is
                        // part of that waveform.
                        if (u.capture_at == null) {
                            u.capture_t0 = u.best_at;
                            u.capture_at = u.best_at + post - 1;
                        }
                    }
                } else if (u.seen > warm and n >= u.dead_until and u.prev > level and y <= level) {
                    u.searching = true;
                    u.cross_at = n;
                    u.best = y;
                    u.best_at = n;
                }
                u.prev = y;
            }
        }
        // Rates: once a second, half the old value and half the last second's count.
        const end = first + @as(i64, @intCast(count));
        if (self.seconds_end == 0) self.seconds_end = first + @as(i64, @intFromFloat(self.fs));
        while (end >= self.seconds_end) {
            for (self.units) |*u| {
                u.rate = if (u.seen < @as(u64, @intFromFloat(2 * self.fs)))
                    @floatFromInt(u.second_count)
                else
                    0.5 * u.rate + 0.5 * @as(f32, @floatFromInt(u.second_count));
                u.second_count = 0;
            }
            self.seconds_end += @intFromFloat(self.fs);
            self.changed = true;
        }
    }
};

const testing = std.testing;

test "spikes are found, their waveforms kept trough-aligned, and counted" {
    const gpa = testing.allocator;
    const fs = 30000.0;
    var det = try Detector.init(gpa, fs, 2);
    defer det.deinit();
    try testing.expectEqual(48, det.len);
    try testing.expectEqual(12, det.pre);
    var rng = std.Random.DefaultPrng.init(5);
    // Channel 0: noise (sigma about 20) and a 10 Hz unit of 400; channel 1: noise only;
    // channel 2 (not an electrode here): ignored.
    var block: [256 * 3]i16 = undefined;
    var n: i64 = 0;
    const total: i64 = 4 * 30000;
    while (n < total) : (n += 256) {
        for (0..256) |i| {
            const s = n + @as(i64, @intCast(i));
            var v = 20.0 * rng.random().floatNorm(f64) + 2000.0 * @sin(2.0 * std.math.pi * 2.0 * @as(f64, @floatFromInt(s)) / fs);
            const d = @mod(s, 3000) - 1500;
            if (d >= -7 and d < 23) v -= 400.0 * @sin(2.0 * std.math.pi * @as(f64, @floatFromInt(d + 7)) / 30.0);
            block[i * 3] = @intFromFloat(v);
            block[i * 3 + 1] = @intFromFloat(20.0 * rng.random().floatNorm(f64));
            block[i * 3 + 2] = 12345;
        }
        try det.feed(n, &block, 3, null);
    }
    const u = &det.units[0];
    // 40 spikes in 4 s (give or take the first, and ringing that re-triggers).
    try testing.expect(u.wave_count >= 38 and u.wave_count <= 80);
    try testing.expect(u.rate > 8 and u.rate < 21);
    try testing.expect(u.sigma() > 9 and u.sigma() < 16);
    // Every kept waveform of the unit itself has the trough it was found by where it
    // belongs: the lowest point of the waveform's first part is at `pre`. (The test's
    // spike is one cycle of a sine; band-passed, its second negative swing is the deeper
    // one, and comes later in the waveform. And a spike this large can make the filter
    // ring across the threshold once more: those small waveforms are kept too.)
    var real: usize = 0;
    for (0..max_waves) |k| {
        const w = u.wave(k).?;
        var lowest: usize = 0;
        for (w[0 .. det.pre + 10], 0..) |v, i| {
            if (v < w[lowest]) lowest = i;
        }
        if (w[lowest] > -150) continue;
        real += 1;
        try testing.expect(lowest >= det.pre - 1 and lowest <= det.pre + 1);
    }
    try testing.expect(real >= 8);
    // Noise alone hardly ever crosses 4.5 sigma.
    try testing.expect(det.units[1].wave_count <= 2);
    try testing.expect(det.changed);
}

test "a reference takes a shared artefact out of the detection" {
    const gpa = testing.allocator;
    const fs = 30000.0;
    var with = try Detector.init(gpa, fs, 4);
    defer with.deinit();
    var without = try Detector.init(gpa, fs, 4);
    defer without.deinit();
    var car: Car = .{};
    for (0..4) |c| car.group_of[c] = 0;
    car.ref[0][0..4].* = .{ 0, 1, 2, 3 };
    car.ref_len[0] = 4;
    var rng = std.Random.DefaultPrng.init(9);
    var block: [128 * 4]i16 = undefined;
    var n: i64 = 0;
    while (n < 3 * 30000) : (n += 128) {
        for (0..128) |i| {
            const s = n + @as(i64, @intCast(i));
            // A sharp artefact on every channel, 5 times a second.
            const d = @mod(s, 6000) - 3000;
            const common: f64 = if (d >= -7 and d < 23) -600.0 * @sin(2.0 * std.math.pi * @as(f64, @floatFromInt(d + 7)) / 30.0) else 0;
            for (0..4) |c| block[i * 4 + c] = @intFromFloat(common + 15.0 * rng.random().floatNorm(f64));
        }
        try with.feed(n, &block, 4, &car);
        try without.feed(n, &block, 4, null);
    }
    try testing.expect(without.units[1].wave_count >= 12);
    try testing.expect(with.units[1].wave_count <= 3);
}
