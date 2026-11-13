//! Spike detection for the tiles: every electrode channel band-passed 300 Hz to 6 kHz,
//! each channel's threshold (thresholds.zig: following the noise, a multiple of sigma with
//! sigma from a running median of the absolute signal, so spikes hardly move it; or fixed,
//! its sign the slope), each crossing aligned on the extreme that follows (the trough of a
//! falling crossing, the peak of a rising one), and the waveform around it kept: the last
//! few per channel, to be drawn on top of each other.
//!
//! The same detection as a panel's slope trigger (slope.zig), for all channels at once
//! and keeping the waveforms. It runs on the tile window's thread; nothing here reaches
//! the recording.

const std = @import("std");
const dsp = @import("dsp.zig");
const types = @import("types.zig");
const Thresholds = @import("thresholds.zig").Thresholds;

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
    /// The filtered signal's previous sample (as it is, whatever the slope).
    prev: f64 = 0,
    searching: bool = false,
    /// The slope the search in progress is for: 1 falling, -1 rising (see `feed`).
    search_sign: f64 = 1,
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
    /// Every channel's threshold (set by the tile window's thread from the display's).
    thresholds: Thresholds = .{},
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

    /// The threshold of channel `ch` in use, in sample units (negative: falling; positive:
    /// rising).
    pub fn threshold(self: *const Detector, ch: usize) f64 {
        return self.thresholds.level(ch, self.units[ch].sigma(), types.electrode_uv_per_bit);
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
                // Seen from the side the slope comes from, every crossing is "falling
                // through" (as in slope.zig): `sign` folds a rising one over.
                const level = self.threshold(ch);
                const sign: f64 = if (level > 0) -1 else 1;
                if (u.searching and sign != u.search_sign) {
                    // The threshold changed sides during a search: what it was looking for
                    // is not this slope's extreme. It is dropped, not kept.
                    u.searching = false;
                } else if (u.searching) {
                    if (sign * y < sign * u.best) {
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
                } else if (u.seen > warm and n >= u.dead_until and sign * u.prev > sign * level and sign * y <= sign * level) {
                    // `prev` is the signal itself, so a threshold that has just moved is only
                    // crossed where the signal really goes through it.
                    u.searching = true;
                    u.search_sign = sign;
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

/// Feeds `det` 4 s of three channels: channel 0 noise (sigma about 20) on a slow wave, and
/// a 10 Hz unit of 400 (one cycle of a sine, trough first); channel 1 noise only; channel 2
/// (not an electrode here) a constant, ignored. The same stream every time.
fn feedUnitStream(det: *Detector) !void {
    const fs = 30000.0;
    var rng = std.Random.DefaultPrng.init(5);
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
}

/// Where the extreme of the first part of waveform `w` is (lowest, or with `peak` the
/// highest), and its value.
fn extremeOf(w: *const [max_len]f32, end: usize, peak: bool) struct { at: usize, v: f32 } {
    var at: usize = 0;
    for (w[0..end], 0..) |v, i| {
        if (if (peak) v > w[at] else v < w[at]) at = i;
    }
    return .{ .at = at, .v = w[at] };
}

test "spikes are found, their waveforms kept trough-aligned, and counted" {
    const gpa = testing.allocator;
    const fs = 30000.0;
    var det = try Detector.init(gpa, fs, 2);
    defer det.deinit();
    try testing.expectEqual(48, det.len);
    try testing.expectEqual(12, det.pre);
    try feedUnitStream(&det);
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

/// The newest of a unit's waveforms whose trough is a spike's (below -150): up to 8.
fn realWaves(u: *const Unit, pre: usize, out: *[8]*const [max_len]f32) usize {
    var n: usize = 0;
    for (0..max_waves) |k| {
        const w = u.wave(k) orelse break;
        if (extremeOf(w, pre + 10, false).v > -150) continue;
        out[n] = w;
        n += 1;
        if (n == out.len) break;
    }
    return n;
}

test "a fixed level finds what the sigma rule found; one beyond the spikes finds none" {
    const gpa = testing.allocator;
    var by_sigma = try Detector.init(gpa, 30000, 2);
    defer by_sigma.deinit();
    try feedUnitStream(&by_sigma);
    // Each channel fixed where the sigma rule's threshold ended up.
    var fixed = try Detector.init(gpa, 30000, 2);
    defer fixed.deinit();
    for (0..2) |ch| fixed.thresholds.set(ch, by_sigma.threshold(ch) * types.electrode_uv_per_bit);
    try testing.expect(fixed.thresholds.isFixed(0) and fixed.thresholds.fixed_uv[0] < 0);
    try feedUnitStream(&fixed);
    // The level in use is the fixed one, in sample units.
    try testing.expectApproxEqRel(by_sigma.threshold(0), fixed.threshold(0), 1e-6);
    // The same spikes: about as many waveforms (the sigma rule's level moved a little on the
    // way, which ringing near it can tell), and the newest real ones the very same.
    const a = by_sigma.units[0].wave_count;
    const b = fixed.units[0].wave_count;
    try testing.expect(a >= 38 and b >= 38 and @max(a, b) - @min(a, b) <= 3);
    var wa: [8]*const [max_len]f32 = undefined;
    var wb: [8]*const [max_len]f32 = undefined;
    const na = realWaves(&by_sigma.units[0], by_sigma.pre, &wa);
    const nb = realWaves(&fixed.units[0], fixed.pre, &wb);
    try testing.expect(na >= 6 and na == nb);
    for (wa[0..na], wb[0..nb]) |x, y| try testing.expectEqualSlices(f32, x[0..by_sigma.len], y[0..fixed.len]);
    try testing.expect(fixed.units[1].wave_count <= 2);

    // -1000 µV is far beyond the spikes (400 LSB, 78 µV): nothing.
    var beyond = try Detector.init(gpa, 30000, 2);
    defer beyond.deinit();
    beyond.thresholds.set(0, -1000);
    try feedUnitStream(&beyond);
    try testing.expectEqual(0, beyond.units[0].wave_count);
    try testing.expectEqual(@as(f64, -1000) / 0.195, beyond.threshold(0));
}

test "a positive level is crossed rising and aligned on the peak" {
    const gpa = testing.allocator;
    var det = try Detector.init(gpa, 30000, 2);
    defer det.deinit();
    // +40 µV (205 LSB): about 17 sigma, below the spike's positive phase.
    det.thresholds.set(0, 40);
    det.thresholds.set(1, 40);
    try feedUnitStream(&det);
    try testing.expect(det.threshold(0) > 0);
    const u = &det.units[0];
    try testing.expect(u.wave_count >= 38 and u.wave_count <= 80);
    // Every waveform of the unit has its highest point of the first part at `pre`.
    var real: usize = 0;
    for (0..max_waves) |k| {
        const peak = extremeOf(u.wave(k).?, det.pre + 10, true);
        if (peak.v < 150) continue;
        real += 1;
        try testing.expect(peak.at >= det.pre - 1 and peak.at <= det.pre + 1);
    }
    try testing.expect(real >= 8);
    // Noise alone does not reach 40 µV.
    try testing.expectEqual(0, det.units[1].wave_count);
}

test "6 sigma finds no more than 4.5" {
    const gpa = testing.allocator;
    var low = try Detector.init(gpa, 30000, 2);
    defer low.deinit();
    var high = try Detector.init(gpa, 30000, 2);
    defer high.deinit();
    high.thresholds.sigmas = 6;
    try feedUnitStream(&low);
    try feedUnitStream(&high);
    for (0..2) |ch| try testing.expect(high.units[ch].wave_count <= low.units[ch].wave_count);
    // The same noise, a level a third further below zero.
    try testing.expectApproxEqRel(6.0 / 4.5, high.threshold(0) / low.threshold(0), 1e-6);
    try testing.expect(high.units[0].wave_count >= 38);
}

/// One channel: noise of sigma 10 and one spike (400, trough first) with its trough at
/// sample 3000, fed one sample at a time, the threshold -40 µV; when a search begins, the
/// thresholds change to `then`. Returns the detector's unit after 6000 samples.
fn searchInterrupted(then: Thresholds) !Unit {
    var det = try Detector.init(testing.allocator, 30000, 1);
    defer det.deinit();
    det.thresholds.set(0, -40);
    var rng = std.Random.DefaultPrng.init(11);
    var changed = false;
    var n: i64 = 0;
    while (n < 6000) : (n += 1) {
        var v = 10.0 * rng.random().floatNorm(f64);
        const d = n - 3000;
        if (d >= -7 and d < 23) v -= 400.0 * @sin(2.0 * std.math.pi * @as(f64, @floatFromInt(d + 7)) / 30.0);
        const s = [1]i16{@intFromFloat(v)};
        try det.feed(n, &s, 1, null);
        if (det.units[0].searching and !changed) {
            det.thresholds = then;
            changed = true;
        }
    }
    try testing.expect(changed);
    return det.units[0];
}

test "a threshold changed during a search: the other slope drops it, the same slope keeps it" {
    // To +1000 µV (rising, far above anything here) while a falling crossing is being
    // followed to its trough: no waveform, although the search had begun.
    var up: Thresholds = .{};
    up.set(0, 1000);
    const u = try searchInterrupted(up);
    try testing.expectEqual(0, u.wave_count);
    try testing.expect(u.capture_at == null and !u.searching);
    // To -50 µV, the same slope: the crossing was real, the spike is kept, trough-aligned.
    var down: Thresholds = .{};
    down.set(0, -50);
    const v = try searchInterrupted(down);
    try testing.expectEqual(1, v.wave_count);
    try testing.expect(v.capture_t0 >= 2998 and v.capture_t0 <= 3002);
}
