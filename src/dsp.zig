//! Filters. Butterworth high-pass and low-pass sections as biquads (the bilinear transform
//! with a pre-warped corner, so the -3 dB point is exact), and a band filter built from
//! them: 4th order each side, either side optional.
//!
//! Double precision throughout: a 1 Hz corner at 30 kHz puts the poles within 2e-4 of the
//! unit circle, where single precision is no longer accurate.

const std = @import("std");

/// One second-order section, transposed direct form II. `a0` is normalized to 1.
pub const Biquad = struct {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,

    pub const State = struct { s1: f64 = 0, s2: f64 = 0 };

    pub inline fn step(c: *const Biquad, st: *State, x: f64) f64 {
        const y = c.b0 * x + st.s1;
        st.s1 = c.b1 * x - c.a1 * y + st.s2;
        st.s2 = c.b2 * x - c.a2 * y;
        return y;
    }

    /// Gain for a constant input.
    pub fn dcGain(c: *const Biquad) f64 {
        return (c.b0 + c.b1 + c.b2) / (1 + c.a1 + c.a2);
    }

    /// The state the section settles to for a constant input `x`; returns its output.
    pub fn settle(c: *const Biquad, st: *State, x: f64) f64 {
        const y = c.dcGain() * x;
        st.s2 = c.b2 * x - c.a2 * y;
        st.s1 = c.b1 * x - c.a1 * y + st.s2;
        return y;
    }

    /// A peaking equalizer: `gain_db` at `fc`, width set by `q`; unity elsewhere.
    pub fn peaking(fc: f64, q: f64, gain_db: f64, fs: f64) Biquad {
        const a = std.math.pow(f64, 10.0, gain_db / 40.0);
        const w0 = 2.0 * std.math.pi * fc / fs;
        const al = @sin(w0) / (2.0 * q);
        const a0 = 1.0 + al / a;
        return .{
            .b0 = (1.0 + al * a) / a0,
            .b1 = -2.0 * @cos(w0) / a0,
            .b2 = (1.0 - al * a) / a0,
            .a1 = -2.0 * @cos(w0) / a0,
            .a2 = (1.0 - al / a) / a0,
        };
    }

    pub const Kind = enum { low_pass, high_pass };

    /// A second-order low-pass or high-pass with corner `fc` (Hz) and quality `q` at sample
    /// rate `fs`.
    pub fn design(kind: Kind, fc: f64, q: f64, fs: f64) Biquad {
        const w0 = 2.0 * std.math.pi * fc / fs;
        const cw = @cos(w0);
        const alpha = @sin(w0) / (2.0 * q);
        const a0 = 1.0 + alpha;
        const b1: f64 = switch (kind) {
            .low_pass => 1.0 - cw,
            .high_pass => -(1.0 + cw),
        };
        const b0 = @abs(b1) / 2.0;
        return .{ .b0 = b0 / a0, .b1 = b1 / a0, .b2 = b0 / a0, .a1 = -2.0 * cw / a0, .a2 = (1.0 - alpha) / a0 };
    }
};

/// The quality factors of the two sections of a 4th-order Butterworth filter.
const butterworth4_q = [2]f64{ 0.541196100146197, 1.306562964876377 };

/// A band filter: 4th-order Butterworth high-pass at `low_hz` and low-pass at `high_hz`.
/// A corner of 0 leaves that side out (so 10–0 is a high-pass, 0–0 passes everything).
pub const Band = struct {
    sections: [4]Biquad = undefined,
    len: usize = 0,

    pub const State = [4]Biquad.State;

    pub fn init(low_hz: f64, high_hz: f64, fs: f64) Band {
        var b: Band = .{};
        if (low_hz > 0) {
            for (butterworth4_q) |q| {
                b.sections[b.len] = .design(.high_pass, @min(low_hz, 0.45 * fs), q, fs);
                b.len += 1;
            }
        }
        if (high_hz > 0 and high_hz < 0.499 * fs) {
            for (butterworth4_q) |q| {
                b.sections[b.len] = .design(.low_pass, high_hz, q, fs);
                b.len += 1;
            }
        }
        return b;
    }

    pub inline fn step(self: *const Band, st: *State, x: f64) f64 {
        var v = x;
        for (self.sections[0..self.len], st[0..self.len]) |*c, *s| v = c.step(s, v);
        return v;
    }

    /// Sets the state as if the input had been `x` for ever, so a filter started in the
    /// middle of a signal has no start-up transient from its offset.
    pub fn settle(self: *const Band, st: *State, x: f64) void {
        var v = x;
        for (self.sections[0..self.len], st[0..self.len]) |*c, *s| v = c.settle(s, v);
    }
};

/// Rounds to int16, saturating.
pub inline fn toI16(v: f64) i16 {
    return @intFromFloat(std.math.clamp(@round(v), -32768.0, 32767.0));
}

const testing = std.testing;

/// Amplitude of the output for a sine of `hz`, measured after the filter has settled.
fn gainAt(band: *const Band, hz: f64, fs: f64) f64 {
    var st: Band.State = @splat(.{});
    const n: usize = @intFromFloat(@max(4.0 * fs, 40.0 * fs / hz));
    // From the RMS: at a few samples per cycle the largest sample misses the peak.
    var sum: f64 = 0;
    for (0..n) |i| {
        const y = band.step(&st, @sin(2.0 * std.math.pi * hz * @as(f64, @floatFromInt(i)) / fs));
        if (i >= n / 2) sum += y * y;
    }
    return @sqrt(2.0 * sum / @as(f64, @floatFromInt(n - n / 2)));
}

test "band filter: -3 dB at the corners, flat between, steep outside" {
    const fs = 30000.0;
    const band: Band = .init(300, 6000, fs);
    try testing.expectEqual(4, band.len);
    try testing.expectApproxEqAbs(0.7071, gainAt(&band, 300, fs), 0.01);
    try testing.expectApproxEqAbs(0.7071, gainAt(&band, 6000, fs), 0.01);
    try testing.expectApproxEqAbs(1.0, gainAt(&band, 1500, fs), 0.01);
    // 4th order: 24 dB per octave.
    try testing.expect(gainAt(&band, 75, fs) < 0.005);
    try testing.expect(gainAt(&band, 12000, fs) < 0.03);
}

test "one-sided bands, and a low corner far below the sample rate" {
    const fs = 30000.0;
    const hp: Band = .init(1, 0, fs);
    try testing.expectEqual(2, hp.len);
    try testing.expectApproxEqAbs(0.7071, gainAt(&hp, 1, fs), 0.01);
    try testing.expectApproxEqAbs(1.0, gainAt(&hp, 5000, fs), 0.001);
    const lp: Band = .init(0, 300, fs);
    try testing.expectApproxEqAbs(1.0, gainAt(&lp, 10, fs), 0.001);
    try testing.expectApproxEqAbs(0.7071, gainAt(&lp, 300, fs), 0.01);
    const none: Band = .init(0, 0, fs);
    var st: Band.State = @splat(.{});
    try testing.expectEqual(123.0, none.step(&st, 123.0));
}

test "a settled filter does not ring on a constant offset" {
    const band: Band = .init(300, 6000, 30000);
    var st: Band.State = @splat(.{});
    band.settle(&st, 5000);
    for (0..100) |_| try testing.expectApproxEqAbs(0.0, band.step(&st, 5000), 1e-6);
    // Unsettled, the same offset makes a transient of thousands of counts.
    var cold: Band.State = @splat(.{});
    var transient: f64 = 0;
    for (0..100) |_| transient = @max(transient, @abs(band.step(&cold, 5000)));
    try testing.expect(transient > 1000);
    const lp: Band = .init(0, 100, 30000);
    lp.settle(&st, -700);
    try testing.expectApproxEqAbs(-700.0, lp.step(&st, -700), 1e-6);
    try testing.expectEqual(32767, toI16(1e9));
    try testing.expectEqual(-32768, toI16(-1e9));
}
