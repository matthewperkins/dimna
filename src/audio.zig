//! The spike audio monitor's signal chain, independent of any audio device.
//!
//! Two goals pull in different directions: salience (hear single units over the noise
//! floor) and texture (what makes, say, globus pallidus, dense and tonic with narrow fast
//! spikes over thick multi-unit hash, sound unlike barrel cortex, sparse and bursty with
//! broader spikes). Texture lives in the firing pattern, the spike shape (narrow spikes
//! carry energy up to 5 to 7 kHz), the distribution of amplitudes including the hash below
//! threshold, and how all of that drifts with brain state. So every stage here is either
//! linear and time-invariant, or static with a calibration that is measured once and then
//! held. Nothing adapts continuously; there is no automatic gain control.
//!
//!  1. Band-limit, 300 Hz to 7 kHz (Butterworth). Linear.
//!  2. Held gain. The noise sigma (robust against spikes, see `NoiseEstimator`) is measured
//!     for 3 s when channels are chosen or on "recalibrate", then frozen: sigma becomes
//!     0.02 of full scale, so a 10-sigma unit sits near 0.2. Electrodes of different
//!     impedance come out equally loud; changes in firing or state are not tracked.
//!  3. A gentle downward expander keyed on the held sigma. Above `gate_sigma` times sigma
//!     the gain is one; the floor is lowered by `expansion` * 24 dB at most (default 9 dB,
//!     so the hash stays clearly audible). A 0.6 ms look-ahead opens the gain before a
//!     spike's onset; the gain moves in 0.15 ms up and 3 ms down.
//!  4. Presence: +3 dB, wide, at 2.8 kHz, where the ear is most sensitive. Linear and the
//!     same for every channel.
//!  5. A safety limiter that is exactly linear below half of full scale (`softLimit`).
//!  6. Constant-power placement of several channels across the stereo field.
//!  7. Windowed-sinc resampling to the device's rate (`Resampler`), flat through the band.
//!
//! `reference` leaves out 3 and 4, for comparing by ear.
//!
//! (Carried over from oers, where these choices were settled by listening.)

const std = @import("std");
const dsp = @import("dsp.zig");
const types = @import("types.zig");

pub const max_channels = 8;
/// The most channels a reference for one audio channel is averaged over.
pub const max_car_ref = 64;

pub const Settings = struct {
    enabled: bool = true,
    mute: bool = false,
    /// Channels to listen to (indices into a sample), in the order they were added.
    channels: [max_channels]u32 = @splat(0),
    num_channels: usize = 0,
    volume_db: f64 = -6,
    /// Leave out the expander and presence: band-limit, held gain and the limiter only.
    reference: bool = false,
    /// Expander depth 0..1 (0 = off; 1 = the floor at -24 dB).
    expansion: f64 = 0.375,
    gate_sigma: f64 = 3,
    presence_db: f64 = 3,
    /// A common average reference for each channel listened to: the channels whose mean
    /// is subtracted from it before anything else (none: `car_len` 0).
    car_ref: [max_channels][max_car_ref]u32 = undefined,
    car_len: [max_channels]u8 = @splat(0),

    pub fn channelSlice(self: *const Settings) []const u32 {
        return self.channels[0..self.num_channels];
    }
};

/// Noise sigma that spikes do not inflate: median(|x|) / 0.6745 over a window, taken twice,
/// the second time without the stretches around anything over four times the first
/// estimate. Dense firing therefore does not raise it.
pub const NoiseEstimator = struct {
    buf: []f32,
    scratch: []f32,
    mask: []bool,
    len: usize = 0,
    guard: usize,
    decim: usize,
    count: usize = 0,
    sigma: f64 = 0,
    windows: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, fs: f64, window_s: f64) !NoiseEstimator {
        const decim: usize = @max(1, @as(usize, @intFromFloat(fs / 10000.0)));
        const cap: usize = @max(64, @as(usize, @intFromFloat(fs * window_s)) / decim);
        const buf = try gpa.alloc(f32, cap);
        errdefer gpa.free(buf);
        const scratch = try gpa.alloc(f32, cap);
        errdefer gpa.free(scratch);
        return .{
            .buf = buf,
            .scratch = scratch,
            .mask = try gpa.alloc(bool, cap),
            .guard = @max(1, @as(usize, @intFromFloat(fs * 1.0e-3)) / decim),
            .decim = decim,
        };
    }

    pub fn deinit(self: *NoiseEstimator, gpa: std.mem.Allocator) void {
        gpa.free(self.buf);
        gpa.free(self.scratch);
        gpa.free(self.mask);
    }

    pub fn restart(self: *NoiseEstimator) void {
        self.len = 0;
        self.count = 0;
        self.sigma = 0;
        self.windows = 0;
    }

    /// Takes one sample; true when a window completed and `sigma` is new. A provisional
    /// estimate appears after the first 256 values, so there is something at once.
    pub fn update(self: *NoiseEstimator, x: f64) bool {
        self.count += 1;
        if (self.count < self.decim) return false;
        self.count = 0;
        self.buf[self.len] = @floatCast(@abs(x));
        self.len += 1;
        const early = self.windows == 0 and self.len == 256;
        if (self.len < self.buf.len and !early) return false;
        const est = self.twoPass();
        if (early) {
            self.sigma = est;
            return true;
        }
        self.len = 0;
        self.sigma = est;
        self.windows += 1;
        return true;
    }

    fn medianSigma(v: []f32) f64 {
        if (v.len == 0) return 0;
        std.mem.sort(f32, v, {}, std.sort.asc(f32));
        return @as(f64, v[v.len / 2]) / 0.6745;
    }

    fn twoPass(self: *NoiseEstimator) f64 {
        const n = self.len;
        @memcpy(self.scratch[0..n], self.buf[0..n]);
        const s0 = medianSigma(self.scratch[0..n]);
        const thr: f32 = @floatCast(4.0 * s0);
        @memset(self.mask[0..n], false);
        for (self.buf[0..n], 0..) |v, i| {
            if (v > thr) @memset(self.mask[i -| self.guard..@min(i + self.guard + 1, n)], true);
        }
        var kept: usize = 0;
        for (self.buf[0..n], self.mask[0..n]) |v, m| {
            if (m) continue;
            self.scratch[kept] = v;
            kept += 1;
        }
        // Mostly "spikes": not a noise floor one can pick out; keep the first estimate.
        if (kept < n / 4) return s0;
        return medianSigma(self.scratch[0..kept]);
    }
};

const cal_seconds = 3.0;
const lookahead_s = 0.6e-3;

const Chain = struct {
    band: dsp.Band,
    band_state: dsp.Band.State = @splat(.{}),
    presence: dsp.Biquad,
    presence_state: dsp.Biquad.State = .{},
    noise: NoiseEstimator,
    held_sigma: ?f64 = null,
    delay: []f64,
    delay_pos: usize = 0,
    env: f64 = 0,
    gain: f64 = 1,
    pan_l: f64,
    pan_r: f64,
    settled: bool = false,
};

/// Stereo position (-1 left to +1 right) of the `i`-th of `n` channels listened to.
pub fn panPosition(i: usize, n: usize) f64 {
    return if (n <= 1) 0 else -0.8 + 1.6 * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1));
}

pub const Monitor = struct {
    gpa: std.mem.Allocator,
    fs: f64,
    chains: [max_channels]Chain = undefined,
    num_chains: usize = 0,
    /// What the chains were built for.
    built_channels: [max_channels]u32 = @splat(0),
    built_presence: f64 = 0,
    // Smoothing coefficients (per sample).
    release: f64,
    gain_up: f64,
    gain_down: f64,

    pub fn init(gpa: std.mem.Allocator, fs: f64) Monitor {
        const k = struct {
            fn f(rate: f64, tau: f64) f64 {
                return 1.0 - @exp(-1.0 / (rate * tau));
            }
        }.f;
        return .{ .gpa = gpa, .fs = fs, .release = k(fs, 4.0e-3), .gain_up = k(fs, 0.15e-3), .gain_down = k(fs, 3.0e-3) };
    }

    pub fn deinit(self: *Monitor) void {
        self.clear();
    }

    fn clear(self: *Monitor) void {
        for (self.chains[0..self.num_chains]) |*c| {
            c.noise.deinit(self.gpa);
            self.gpa.free(c.delay);
        }
        self.num_chains = 0;
    }

    /// Measures the noise afresh (3 s), then holds it again.
    pub fn recalibrate(self: *Monitor) void {
        for (self.chains[0..self.num_chains]) |*c| {
            c.held_sigma = null;
            c.noise.restart();
        }
    }

    /// The held sigma of the `i`-th channel in sample units, or null while it is measured.
    pub fn heldSigma(self: *const Monitor, i: usize) ?f64 {
        return if (i < self.num_chains) self.chains[i].held_sigma else null;
    }

    fn rebuild(self: *Monitor, s: *const Settings) !void {
        self.clear();
        const n = s.num_channels;
        for (0..n) |i| {
            const th = (panPosition(i, n) + 1.0) * std.math.pi / 4.0;
            const delay = try self.gpa.alloc(f64, @max(1, @as(usize, @intFromFloat(self.fs * lookahead_s))));
            errdefer self.gpa.free(delay);
            @memset(delay, 0);
            self.chains[i] = .{
                .band = .init(300, 7000, self.fs),
                .presence = .peaking(2800, 0.7, s.presence_db, self.fs),
                .noise = try .init(self.gpa, self.fs, cal_seconds),
                .delay = delay,
                .pan_l = @cos(th),
                .pan_r = @sin(th),
            };
            self.num_chains = i + 1;
        }
        self.built_channels = s.channels;
        self.built_presence = s.presence_db;
    }

    /// Turns `count` samples (`nch` interleaved int16) into `count` stereo frames at the
    /// acquisition rate, appended to `out` (left, right, ...).
    pub fn process(self: *Monitor, s: *const Settings, samples: []const i16, nch: usize, out: *std.ArrayList(f32)) !void {
        if (s.num_channels != self.num_chains or !std.mem.eql(u32, s.channelSlice(), self.built_channels[0..self.num_chains]) or s.presence_db != self.built_presence) try self.rebuild(s);
        const count = samples.len / nch;
        try out.ensureUnusedCapacity(self.gpa, 2 * count);
        const vol: f64 = if (s.mute) 0 else std.math.pow(f64, 10.0, s.volume_db / 20.0);
        const floor = std.math.pow(f64, 10.0, -24.0 * std.math.clamp(s.expansion, 0, 1) / 20.0);
        const expand = !s.reference and s.expansion > 0;
        const presence = !s.reference and s.presence_db != 0;
        const norm = 1.0 / @sqrt(@as(f64, @floatFromInt(@max(self.num_chains, 1))));
        for (0..count) |t| {
            const row = samples[t * nch ..][0..nch];
            var l: f64 = 0;
            var r: f64 = 0;
            for (self.chains[0..self.num_chains], s.channelSlice(), 0..) |*c, ch, ci| {
                var x: f64 = if (ch < nch) @floatFromInt(row[ch]) else 0;
                if (s.car_len[ci] > 0) {
                    var sum: f64 = 0;
                    for (s.car_ref[ci][0..s.car_len[ci]]) |rc| sum += if (rc < nch) @as(f64, @floatFromInt(row[rc])) else 0;
                    x -= sum / @as(f64, @floatFromInt(s.car_len[ci]));
                }
                if (!c.settled) {
                    // No start-up thump from the electrode's offset.
                    c.band.settle(&c.band_state, x);
                    c.settled = true;
                }
                const y = c.band.step(&c.band_state, x);
                if (c.held_sigma == null and c.noise.update(y) and c.noise.windows >= 1) {
                    // The first full window: hold it.
                    c.held_sigma = @max(c.noise.sigma, 0.5);
                }
                // While measuring, the running estimate (already robust against spikes).
                const sigma = c.held_sigma orelse @max(c.noise.sigma, 0.5);
                // Look-ahead: the envelope sees the signal before the delay.
                const a = @abs(y);
                c.env += (if (a > c.env) 1.0 else self.release) * (a - c.env);
                const target = if (expand) blk: {
                    const rr = c.env / (s.gate_sigma * sigma);
                    const r4 = rr * rr * rr * rr;
                    break :blk floor + (1.0 - floor) * (r4 / (1.0 + r4));
                } else 1.0;
                c.gain += (if (target > c.gain) self.gain_up else self.gain_down) * (target - c.gain);
                const delayed = c.delay[c.delay_pos];
                c.delay[c.delay_pos] = y;
                c.delay_pos = (c.delay_pos + 1) % c.delay.len;
                var v = delayed * c.gain;
                if (presence) v = c.presence.step(&c.presence_state, v);
                // Noise sigma becomes 0.02 of full scale.
                v *= 0.02 / sigma;
                l += v * c.pan_l;
                r += v * c.pan_r;
            }
            out.appendAssumeCapacity(softLimit(@floatCast(l * vol * norm)));
            out.appendAssumeCapacity(softLimit(@floatCast(r * vol * norm)));
        }
    }
};

/// Exactly linear below `limit_knee` (spikes sit at about 0.05 to 0.4 of full scale and
/// pass untouched); above it a smooth shoulder that approaches 1 catches artefacts.
pub const limit_knee: f32 = 0.5;
pub fn softLimit(x: f32) f32 {
    const a = @abs(x);
    if (a <= limit_knee) return x;
    const h = 1.0 - limit_knee;
    const t = (a - limit_knee) / h;
    const e = @exp(-2.0 * @min(t, 20.0));
    return std.math.copysign(limit_knee + h * (1.0 - e) / (1.0 + e), x);
}

/// Stereo windowed-sinc resampler: 32 taps, 256 phases (interpolated), Kaiser window
/// (beta 9). Flat beyond 10 kHz for 30 kHz input, images below -80 dB. `adjust` trims the
/// ratio by a fraction, for following the audio device's clock.
pub const Resampler = struct {
    const taps = 32;
    const phases = 256;
    /// Its delay, in input samples.
    pub const delay_in = taps / 2;

    table: [(phases + 1) * taps]f32,
    hist: [2 * taps][2]f32 = @splat(.{ 0, 0 }),
    pos: usize = 0,
    frac: f64 = 0,
    adjust: f64 = 0,

    pub fn init() Resampler {
        var self: Resampler = .{ .table = undefined };
        const t: f64 = taps;
        const beta = 9.0;
        const cutoff = 0.9; // of the input's Nyquist frequency
        for (0..phases + 1) |p| {
            const frac = @as(f64, @floatFromInt(p)) / phases;
            var row: [taps]f64 = undefined;
            var sum: f64 = 0;
            for (&row, 0..) |*v, k| {
                // Centred between taps 15 and 16.
                const x = @as(f64, @floatFromInt(k)) - (t / 2.0 - 1.0) - frac;
                const sinc = if (@abs(x) < 1e-9) 1.0 else @sin(std.math.pi * cutoff * x) / (std.math.pi * cutoff * x);
                const w = std.math.clamp(x / (t / 2.0), -1.0, 1.0);
                v.* = sinc * cutoff * bessel0(beta * @sqrt(@max(0.0, 1.0 - w * w))) / bessel0(beta);
                sum += v.*;
            }
            for (row, 0..) |v, k| self.table[p * taps + k] = @floatCast(v / sum);
        }
        return self;
    }

    fn bessel0(x: f64) f64 {
        var sum: f64 = 1;
        var term: f64 = 1;
        for (1..30) |k| {
            term *= (x / 2.0) / @as(f64, @floatFromInt(k));
            sum += term * term;
        }
        return sum;
    }

    /// Resamples interleaved stereo `in` by `ratio` (output rate / input rate), appending
    /// to `out`.
    pub fn process(self: *Resampler, gpa: std.mem.Allocator, in: []const f32, ratio: f64, out: *std.ArrayList(f32)) !void {
        const step = 1.0 / (ratio * (1.0 + self.adjust));
        try out.ensureUnusedCapacity(gpa, @as(usize, @intFromFloat(@as(f64, @floatFromInt(in.len)) / step)) + 8);
        var i: usize = 0;
        while (i + 1 < in.len) : (i += 2) {
            // Written twice, so a contiguous window of `taps` always exists.
            self.hist[self.pos] = .{ in[i], in[i + 1] };
            self.hist[self.pos + taps] = .{ in[i], in[i + 1] };
            self.pos = (self.pos + 1) % taps;
            while (self.frac < 1.0) {
                const ph = self.frac * phases;
                const pi: usize = @intFromFloat(ph);
                const pf: f32 = @floatCast(ph - @as(f64, @floatFromInt(pi)));
                const r0 = self.table[pi * taps ..][0..taps];
                const r1 = self.table[(pi + 1) * taps ..][0..taps];
                const w = self.hist[self.pos..][0..taps]; // oldest to newest
                var l: f32 = 0;
                var r: f32 = 0;
                for (0..taps) |k| {
                    const c = r0[k] + pf * (r1[k] - r0[k]);
                    l += c * w[k][0];
                    r += c * w[k][1];
                }
                out.appendAssumeCapacity(l);
                out.appendAssumeCapacity(r);
                self.frac += step;
            }
            self.frac -= 1.0;
        }
    }
};

const testing = std.testing;

fn toneGain(gpa: std.mem.Allocator, f: f64) !f64 {
    var r: Resampler = .init();
    const in = try gpa.alloc(f32, 60000);
    defer gpa.free(in);
    for (0..30000) |i| {
        const v: f32 = @floatCast(@sin(2.0 * std.math.pi * f * @as(f64, @floatFromInt(i)) / 30000.0));
        in[2 * i] = v;
        in[2 * i + 1] = v;
    }
    var out: std.ArrayList(f32) = .empty;
    defer out.deinit(gpa);
    try r.process(gpa, in, 48000.0 / 30000.0, &out);
    var sum: f64 = 0;
    var n: f64 = 0;
    var i = out.items.len / 2;
    i -= i % 2;
    while (i < out.items.len) : (i += 2) {
        sum += @as(f64, out.items[i]) * out.items[i];
        n += 1;
    }
    return @sqrt(2.0 * sum / n);
}

test "resampler: the right number of samples, flat through the spike band" {
    const gpa = testing.allocator;
    var r: Resampler = .init();
    const in = try gpa.alloc(f32, 60000);
    defer gpa.free(in);
    @memset(in, 0);
    var out: std.ArrayList(f32) = .empty;
    defer out.deinit(gpa);
    try r.process(gpa, in, 48000.0 / 30000.0, &out);
    try testing.expect(@abs(@as(i64, @intCast(out.items.len / 2)) - 48000) <= 2);
    for ([_]f64{ 500, 3000, 7000, 10000 }) |f| try testing.expectApproxEqAbs(1.0, try toneGain(gpa, f), 0.012);
}

test "limiter: monotone, bounded, and exactly linear where spikes are" {
    var last: f32 = -2;
    var i: i32 = -400;
    while (i <= 400) : (i += 1) {
        const x = @as(f32, @floatFromInt(i)) / 100.0;
        const y = softLimit(x);
        try testing.expect(y >= last - 1e-6 and @abs(y) <= 1.0001);
        if (@abs(x) <= limit_knee) try testing.expectEqual(x, y);
        last = y;
    }
}

/// One channel: noise of `sigma` µV plus spike trains (rate in Hz, trough size in µV).
fn synth(gpa: std.mem.Allocator, fs: f64, secs: f64, sigma: f64, spikes: []const [2]f64, seed: u64) ![]i16 {
    const n: usize = @intFromFloat(fs * secs);
    const v = try gpa.alloc(f64, n);
    defer gpa.free(v);
    var rng = std.Random.DefaultPrng.init(seed);
    for (v) |*x| x.* = sigma * rng.random().floatNorm(f64);
    const w: usize = @intFromFloat(fs * 1.0e-3);
    for (spikes) |sp| {
        const period: usize = @intFromFloat(fs / sp[0]);
        var t = period / 3;
        while (t + w < n) : (t += period) {
            for (0..w) |k| {
                const ph = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(w));
                v[t + k] += -sp[1] * @sin(std.math.pi * ph) * (1.0 - 1.6 * ph);
            }
        }
    }
    const out = try gpa.alloc(i16, n);
    for (out, v) |*o, x| o.* = @intFromFloat(std.math.clamp(x / types.electrode_uv_per_bit, -32000, 32000));
    return out;
}

/// The left channel of the chain's output for one channel of samples.
fn run(gpa: std.mem.Allocator, s: Settings, samples: []const i16) ![]f32 {
    var m: Monitor = .init(gpa, 30000);
    defer m.deinit();
    var settings = s;
    settings.num_channels = 1;
    var out: std.ArrayList(f32) = .empty;
    defer out.deinit(gpa);
    try m.process(&settings, samples, 1, &out);
    const left = try gpa.alloc(f32, out.items.len / 2);
    for (left, 0..) |*v, i| v.* = out.items[2 * i];
    return left;
}

/// Peak of the spike-triggered average (noise averages out across spikes).
fn spikePeak(y: []const f32, fs: f64, rate: f64, skip_s: f64) f64 {
    const period: usize = @intFromFloat(fs / rate);
    const w: usize = @intFromFloat(fs * 3.0e-3);
    var avg: [128]f64 = @splat(0);
    var t = period / 3;
    var n: f64 = 0;
    while (t + w < y.len) : (t += period) {
        if (@as(f64, @floatFromInt(t)) <= skip_s * fs) continue;
        for (0..w) |k| avg[k] += y[t + k];
        n += 1;
    }
    var peak: f64 = 0;
    for (avg[0..w]) |v| peak = @max(peak, @abs(v / n));
    return peak;
}

test "the expander keeps the relative sizes of units" {
    // Units of 8 and 16 sigma, recorded separately. The default chain may expand sizes
    // near the threshold a little, but the loudness ratio stays within 15 % of the linear
    // reference chain's.
    const gpa = testing.allocator;
    const fs = 30000.0;
    const small = try synth(gpa, fs, 8, 5, &.{.{ 10, 40 }}, 1);
    defer gpa.free(small);
    const big = try synth(gpa, fs, 8, 5, &.{.{ 10, 80 }}, 1);
    defer gpa.free(big);
    var ratios: [2]f64 = undefined;
    for ([_]bool{ false, true }, &ratios) |reference, *ratio| {
        const s: Settings = .{ .volume_db = -12, .reference = reference };
        const yb = try run(gpa, s, big);
        defer gpa.free(yb);
        const ys = try run(gpa, s, small);
        defer gpa.free(ys);
        ratio.* = spikePeak(yb, fs, 10, 3.5) / spikePeak(ys, fs, 10, 3.5);
    }
    try testing.expect(@abs(ratios[0] / ratios[1] - 1.0) < 0.15);
    try testing.expect(@abs(ratios[1] - 2.0) < 0.2);
}

test "the held gain does not follow the firing rate" {
    // The same electrode noise; one place fires at 5 Hz, another at 80 Hz. After the
    // calibration each spike is as loud in both, so rate is heard as density, not level.
    const gpa = testing.allocator;
    const fs = 30000.0;
    const s: Settings = .{ .volume_db = 0 };
    const sparse = try synth(gpa, fs, 6, 10, &.{.{ 5, 100 }}, 7);
    defer gpa.free(sparse);
    const dense = try synth(gpa, fs, 6, 10, &.{.{ 80, 100 }}, 7);
    defer gpa.free(dense);
    const ys = try run(gpa, s, sparse);
    defer gpa.free(ys);
    const yd = try run(gpa, s, dense);
    defer gpa.free(yd);
    const ps = spikePeak(ys, fs, 5, 4);
    const pd = spikePeak(yd, fs, 80, 4);
    try testing.expect(@abs(pd / ps - 1.0) < 0.15);
}

test "multi-unit hash stays audible at the default depth" {
    // Activity below threshold (2 sigma) is not gated away.
    const gpa = testing.allocator;
    const fs = 30000.0;
    const b = try synth(gpa, fs, 5, 10, &.{.{ 200, 20 }}, 3);
    defer gpa.free(b);
    var rms: [2]f64 = undefined;
    for ([_]bool{ false, true }, &rms) |reference, *v| {
        const y = try run(gpa, .{ .volume_db = 0, .reference = reference }, b);
        defer gpa.free(y);
        var sum: f64 = 0;
        for (y[100_000..]) |x| sum += @as(f64, x) * x;
        v.* = @sqrt(sum / @as(f64, @floatFromInt(y.len - 100_000)));
    }
    try testing.expect(20.0 * @log10(rms[0] / rms[1]) > -10.0);
}

test "the reference chain is linear; sigma is not inflated by dense firing" {
    const gpa = testing.allocator;
    const fs = 30000.0;
    // After the gain is held (the same noise, so the same gain), halving the spikes halves
    // the output.
    const b1 = try synth(gpa, fs, 6, 10, &.{.{ 20, 160 }}, 5);
    defer gpa.free(b1);
    const b2 = try synth(gpa, fs, 6, 10, &.{.{ 20, 80 }}, 5);
    defer gpa.free(b2);
    const s: Settings = .{ .reference = true, .volume_db = -12 };
    const y1 = try run(gpa, s, b1);
    defer gpa.free(y1);
    const y2 = try run(gpa, s, b2);
    defer gpa.free(y2);
    try testing.expectApproxEqAbs(2.0, spikePeak(y1, fs, 20, 4) / spikePeak(y2, fs, 20, 4), 0.1);

    // The estimator on band-limited noise with and without an 80 Hz unit of 10 sigma.
    var sig: [2]f64 = undefined;
    for ([_]f64{ 0, 100 }, &sig) |amp, *out| {
        const b = try synth(gpa, fs, 3.5, 10, &.{.{ 80, amp }}, 11);
        defer gpa.free(b);
        var est = try NoiseEstimator.init(gpa, fs, 3.0);
        defer est.deinit(gpa);
        var band: dsp.Band = .init(300, 7000, fs);
        var st: dsp.Band.State = @splat(.{});
        for (b) |x| _ = est.update(band.step(&st, @floatFromInt(x)));
        try testing.expect(est.windows >= 1);
        out.* = est.sigma;
    }
    try testing.expect(@abs(sig[1] / sig[0] - 1.0) < 0.12);
}

test "a common average reference takes the shared part out of the monitor" {
    // Four electrodes: their own noise (5 µV) plus a shared 400 µV artefact train.
    const gpa = testing.allocator;
    const fs = 30000.0;
    const common = try synth(gpa, fs, 1, 0, &.{.{ 5, 400 }}, 1);
    defer gpa.free(common);
    const n = common.len;
    const block = try gpa.alloc(i16, n * 4);
    defer gpa.free(block);
    for (0..4) |k| {
        const own = try synth(gpa, fs, 1, 5, &.{}, 10 + k);
        defer gpa.free(own);
        for (0..n) |t| block[t * 4 + k] = own[t] + common[t];
    }
    var peaks: [2]f64 = undefined;
    for ([_]bool{ false, true }, &peaks) |car, *peak| {
        var m: Monitor = .init(gpa, fs);
        defer m.deinit();
        var s: Settings = .{ .reference = true, .volume_db = 0, .num_channels = 1 };
        s.channels[0] = 1;
        if (car) {
            s.car_ref[0][0..4].* = .{ 0, 1, 2, 3 };
            s.car_len[0] = 4;
        }
        var out: std.ArrayList(f32) = .empty;
        defer out.deinit(gpa);
        try m.process(&s, block, 4, &out);
        peak.* = 0;
        var i: usize = 6000;
        while (i < out.items.len) : (i += 2) peak.* = @max(peak.*, @abs(out.items[i]));
    }
    try testing.expect(peaks[1] < 0.2 * peaks[0]);
}
