//! A slope trigger: finds the moments one electrode's signal crosses a level, for a
//! triggered-sweep panel that is to show spikes instead of the stretch after a TTL edge.
//!
//! The channel is band-passed 300 Hz to 6 kHz first (the spike band), so slow waves do not
//! carry it across the level. The level is either fixed, or follows the noise: a multiple
//! of sigma, estimated as median(|x|) / 0.6745, which spikes hardly move. After a crossing
//! the trigger is placed at the extreme within the next 0.5 ms (a spike's trough or peak),
//! so sweeps line up on the spike rather than on where it happened to cross; then nothing
//! triggers for 1 ms plus the holdoff.
//!
//! This runs on the display's thread, on the samples it is about to draw. Nothing here
//! reaches the recording.

const std = @import("std");
const dsp = @import("dsp.zig");

pub const Settings = struct {
    /// True: trigger on rising through the level; false: falling.
    rising: bool = false,
    /// The level follows the noise (`auto_sigmas` times sigma, on the side the slope
    /// crosses towards) instead of `level`.
    auto: bool = true,
    auto_sigmas: f64 = 4.5,
    /// The fixed level, in sample units (LSB).
    level: f64 = -256,
    /// Time after a trigger during which no other is taken, on top of the 1 ms dead time.
    holdoff_ms: f64 = 0,
    /// Place the trigger at the extreme after the crossing (else at the crossing).
    align_extreme: bool = true,

    pub fn eql(a: Settings, b: Settings) bool {
        return std.meta.eql(a, b);
    }
};

pub const Slope = struct {
    fs: f64,
    settings: Settings = .{},
    band: dsp.Band,
    state: dsp.Band.State = @splat(.{}),
    started: bool = false,
    /// Samples seen; nothing triggers during the filter's first 20 ms.
    seen: u64 = 0,
    /// Running estimate of median(|x|) of the filtered signal.
    mad: f64 = 0,
    prev: f64 = 0,
    searching: bool = false,
    cross_at: i64 = 0,
    best: f64 = 0,
    best_at: i64 = 0,
    dead_until: i64 = std.math.minInt(i64),

    pub fn init(fs: f64, settings: Settings) Slope {
        return .{ .fs = fs, .settings = settings, .band = .init(300, 6000, fs) };
    }

    /// Sigma of the filtered signal, in sample units.
    pub fn sigma(self: *const Slope) f64 {
        return self.mad / 0.6745;
    }

    /// The level in use, in sample units (signed: negative for a falling trigger on noise).
    pub fn level(self: *const Slope) f64 {
        if (!self.settings.auto) return self.settings.level;
        const l = self.settings.auto_sigmas * self.sigma();
        return if (self.settings.rising) l else -l;
    }

    /// Feeds channel `ch` of a block of `nch` interleaved samples that starts at sample
    /// number `first`; calls `sink.push(t0)` for each trigger. `ref`: channels whose mean
    /// is subtracted first (a common average reference), or none.
    pub fn feed(self: *Slope, first: i64, samples: []const i16, nch: usize, ch: usize, ref: []const u32, sink: anytype) void {
        const count = samples.len / nch;
        if (count == 0 or ch >= nch) return;
        if (!self.started) {
            self.band.settle(&self.state, referenced(samples[0..nch], ch, ref));
            self.started = true;
        }
        const align_n: i64 = if (self.settings.align_extreme) @intFromFloat(@round(0.0005 * self.fs)) else 0;
        const dead_n: i64 = @intFromFloat(@round((0.001 + self.settings.holdoff_ms * 1e-3) * self.fs));
        const warm: u64 = @intFromFloat(0.02 * self.fs);
        // Seen from the side the slope comes from, every trigger is "falling through".
        const sign: f64 = if (self.settings.rising) -1 else 1;
        for (0..count) |i| {
            const n = first + @as(i64, @intCast(i));
            const y = self.band.step(&self.state, referenced(samples[i * nch ..][0..nch], ch, ref));
            // The median of |y| by small steps towards it: up when |y| is above, down when
            // below. Starts at the first values' size, then moves about 0.1 % per sample.
            const a = @abs(y);
            if (self.seen < 64) {
                self.mad += (a - self.mad) / @as(f64, @floatFromInt(self.seen + 1));
            } else {
                const stride = @max(self.mad, 0.5) * 0.001;
                self.mad += if (a > self.mad) stride else -stride;
            }
            self.seen += 1;
            const u = sign * y;
            const lu = sign * self.level();
            if (self.searching) {
                if (u < self.best) {
                    self.best = u;
                    self.best_at = n;
                }
                if (n - self.cross_at >= align_n) {
                    self.searching = false;
                    self.dead_until = self.best_at + dead_n;
                    sink.push(self.best_at);
                }
            } else if (self.seen > warm and n >= self.dead_until and self.prev > lu and u <= lu) {
                self.searching = true;
                self.cross_at = n;
                self.best = u;
                self.best_at = n;
                if (align_n == 0) {
                    self.searching = false;
                    self.dead_until = n + dead_n;
                    sink.push(n);
                }
            }
            self.prev = u;
        }
    }
};

/// One sample of channel `ch`, less the mean of the `ref` channels.
inline fn referenced(row: []const i16, ch: usize, ref: []const u32) f64 {
    const x: f64 = @floatFromInt(row[ch]);
    if (ref.len == 0) return x;
    var sum: f64 = 0;
    for (ref) |rc| sum += if (rc < row.len) @as(f64, @floatFromInt(row[rc])) else 0;
    return x - sum / @as(f64, @floatFromInt(ref.len));
}

const testing = std.testing;

const Collect = struct {
    at: [64]i64 = undefined,
    len: usize = 0,
    pub fn push(self: *Collect, t0: i64) void {
        if (self.len < self.at.len) {
            self.at[self.len] = t0;
            self.len += 1;
        }
    }
};

/// Noise (sigma about `noise` LSB) on a slow wave, with spikes (a 1 ms biphasic wave of
/// `amp` LSB, trough first) at the given sample numbers.
fn synth(buf: []i16, first: i64, spikes: []const i64, amp: f64, noise: f64, rng: *std.Random.DefaultPrng) void {
    const r = rng.random();
    for (buf, 0..) |*s, i| {
        const n = first + @as(i64, @intCast(i));
        const t = @as(f64, @floatFromInt(n)) / 30000.0;
        var v = 3000.0 * @sin(2.0 * std.math.pi * 3.0 * t) + noise * r.floatNorm(f64);
        for (spikes) |at| {
            const d = n - at;
            // Trough at `at` (a quarter of the way into the 1 ms wave).
            if (d >= -7 and d < 23) v -= amp * @sin(2.0 * std.math.pi * @as(f64, @floatFromInt(d + 7)) / 30.0);
        }
        s.* = @intFromFloat(std.math.clamp(v, -32000, 32000));
    }
}

test "triggers at the troughs of spikes, not on noise or slow waves; sigma follows the noise" {
    var rng = std.Random.DefaultPrng.init(7);
    const spikes = [_]i64{ 9000, 12000, 12021, 15000, 21000 };
    var slope: Slope = .init(30000, .{});
    var got: Collect = .{};
    var buf: [256]i16 = undefined;
    var n: i64 = 0;
    while (n < 30000) : (n += 256) {
        synth(&buf, n, &spikes, 400, 20, &rng);
        slope.feed(n, &buf, 1, 0, &.{}, &got);
    }
    // Sigma of the band-passed noise: white noise of 20 keeps about 0.38 of its power in
    // 300 Hz to 6 kHz at 30 kHz, so about 12.
    try testing.expect(slope.sigma() > 9 and slope.sigma() < 16);
    // Every spike is found at its trough, except the one at 12021, which is within the
    // 1 ms dead time of the one at 12000.
    for ([_]i64{ 9000, 12000, 15000, 21000 }) |want| {
        var found = false;
        for (got.at[0..got.len]) |at| found = found or @abs(at - want) <= 3;
        try testing.expect(found);
    }
    // And nothing triggers away from a spike. (A 30-sigma spike makes the band-pass ring
    // for a few ms, which may trigger once more after the dead time; that is the signal,
    // not noise.)
    for (got.at[0..got.len]) |at| {
        var near = false;
        for (spikes) |sp| near = near or (at >= sp - 3 and at <= sp + 120);
        try testing.expect(near);
        try testing.expect(@abs(at - 12021) > 3);
    }
    try testing.expect(got.len <= 8);
}

test "rising slope, a fixed level, the crossing itself, and holdoff" {
    var rng = std.Random.DefaultPrng.init(3);
    const spikes = [_]i64{ 9000, 9150, 12000 };
    // Rising through +150 on the spike's second (positive) phase, at the crossing; 10 ms
    // of holdoff swallows the spike 5 ms after the first.
    var slope: Slope = .init(30000, .{ .rising = true, .auto = false, .level = 150, .align_extreme = false, .holdoff_ms = 10 });
    var got: Collect = .{};
    var buf: [256]i16 = undefined;
    var n: i64 = 0;
    while (n < 20000) : (n += 256) {
        synth(&buf, n, &spikes, 400, 10, &rng);
        slope.feed(n, &buf, 1, 0, &.{}, &got);
    }
    try testing.expectEqual(2, got.len);
    // The positive phase crosses +150 about half a millisecond after the trough.
    try testing.expect(got.at[0] > 9005 and got.at[0] < 9025);
    try testing.expect(got.at[1] > 12005 and got.at[1] < 12025);
    try testing.expectEqual(150.0, slope.level());
}
