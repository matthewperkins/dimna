//! The spike audio monitor's output: two threads beside the display.
//!
//!   feeder: reads the acquisition ring with a lossy reader of its own (so sound never
//!     depends on the display's frame rate, and never holds acquisition back), runs the
//!     chain in `audio.zig`, resamples to the device's rate and puts the result in a small
//!     queue;
//!   output: hands the device one period at a time (ALSA, `audio_alsa.zig`; on this
//!     machine PipeWire's ALSA device), with silence when the queue is empty.
//!
//! What goes to the device is made by one function, `render`: it fills as many frames as
//! the device asks for from the queue. The ALSA thread calls it once a period and then
//! writes the period; a device that pulls frames through a callback calls it from there.
//!
//! The board's clock and the sound card's differ slightly, so the feeder trims the
//! resampling ratio to keep the queue just above empty: it steers on the least that was
//! left after any period in the last 100 ms (what protects against late input), towards
//! a margin. The margin itself adapts: each gap in the sound raises it by 1 ms (input came
//! later than it allowed for), and 30 s without one lowers it by 0.5 ms, between 1.5 and
//! 25 ms. So latency settles at what this machine's timing needs, instead of gaps going on.
//! If the queue ever holds much more than that (a stall upstream, start-up),
//! a block's output is dropped instead of letting latency sit high for a minute.
//!
//! Latency, as reported: what waits in the queue (about 5 ms: the margin, a period, and
//! the burstiness of USB delivery), what the device says is still to be played (about
//! 10 ms here through PipeWire at a 128-frame quantum, most of it the sound card's own
//! path, which an application cannot shorten; writing to the device only when its buffer
//! was nearly empty changed nothing), plus 1 ms for the resampler and the look-ahead.
//!
//! Settings come from the display thread and statistics go back through `Shared`, without
//! locks.

const std = @import("std");
const dimna = @import("dimna");
const audio = dimna.audio;
const audio_alsa = @import("audio_alsa.zig");
const Atomic = std.atomic.Value;
const log = std.log.scoped(.audio);

pub const Shared = struct {
    settings: dimna.published.Published(audio.Settings) = .{},
    recalibrate: Atomic(bool) = .init(false),
    /// Sound an alarm (a short tone every second) over whatever else is playing, also
    /// when the monitor is off or muted: samples are being lost.
    alarm: Atomic(bool) = .init(false),

    running: Atomic(bool) = .init(false),
    underruns: Atomic(u64) = .init(0),
    dropped: Atomic(u64) = .init(0),
    latency_us: Atomic(u32) = .init(0),
    /// Its two main parts: what waits in our queue, and what the device says it holds.
    queue_us: Atomic(u32) = .init(0),
    device_us: Atomic(u32) = .init(0),
    /// The margin the feeder is keeping in the queue at the moment (it grows when gaps
    /// happen, see `feed`), in microseconds.
    margin_us: Atomic(u32) = .init(0),
    /// For finding what causes gaps; each is the largest since it was last read (swap 0):
    /// the longest wait between two blocks reaching the feeder, and the oldest a block
    /// was (since it was acquired) when the feeder got to it.
    max_block_gap_us: Atomic(u32) = .init(0),
    max_block_age_us: Atomic(u32) = .init(0),
    /// Held noise sigma of the first channel, in hundredths of a sample unit; 0 while it
    /// is being measured.
    held_sigma_c: Atomic(u32) = .init(0),
    device_rate: Atomic(u32) = .init(0),

    /// Display thread: new settings for the audio threads.
    pub fn publish(self: *Shared, s: *const audio.Settings) void {
        self.settings.publish(s);
    }

    fn read(self: *Shared, out: *audio.Settings, seen: *u32) void {
        _ = self.settings.read(out, seen);
    }
};

/// Single-producer, single-consumer queue of samples.
const Fifo = struct {
    buf: []f32,
    head: Atomic(usize) = .init(0),
    tail: Atomic(usize) = .init(0),

    fn used(self: *const Fifo) usize {
        return self.tail.load(.acquire) -% self.head.load(.acquire);
    }
    fn push(self: *Fifo, data: []const f32) usize {
        const t = self.tail.load(.monotonic);
        const free = self.buf.len - (t -% self.head.load(.acquire));
        const n = @min(free, data.len);
        for (data[0..n], 0..) |v, i| self.buf[(t +% i) & (self.buf.len - 1)] = v;
        self.tail.store(t +% n, .release);
        return n;
    }
    fn pop(self: *Fifo, out: []f32) usize {
        const h = self.head.load(.monotonic);
        const n = @min(self.tail.load(.acquire) -% h, out.len);
        for (out[0..n], 0..) |*v, i| v.* = self.buf[(h +% i) & (self.buf.len - 1)];
        self.head.store(h +% n, .release);
        return n;
    }
};

/// The period dimna asks the device for, in frames (`audio_period` in the config,
/// `--audio-period`): a power of two from `min_period` to `max_period`. The device's buffer
/// is two of them. What the device accepted is what is used (`max_request`).
pub const default_period: u32 = 128;
pub const min_period: u32 = 16;
pub const max_period: u32 = 1024;

/// Whether `frames` is a period dimna accepts.
pub fn validPeriod(frames: u64) bool {
    return frames >= min_period and frames <= max_period and std.math.isPowerOfTwo(frames);
}

/// The least kept in the queue when all is quiet, and the most the feeder will go to.
const margin_min_ms = 1.5;
const margin_max_ms = 25.0;

pub const AudioOut = struct {
    gpa: std.mem.Allocator,
    shared: *Shared,
    ring: *dimna.ring.BlockRing,
    fs_in: f64,
    nch: usize,
    block_samples: usize,
    alsa: ?audio_alsa.Device = null,
    fs_out: f64 = 48000,
    /// The largest request the device makes, in frames: what the feeder keeps room for
    /// (the drop limit, `primed`), read from its own thread. ALSA: its period, fixed once
    /// the device is open. A device with requests of varying size sets what it expects;
    /// `render` raises it if a request is ever larger.
    max_request: Atomic(u32) = .init(128),
    /// The device's own buffer, in frames (two periods are asked for).
    device_buffer: usize = 256,
    fifo: Fifo,
    stop_flag: Atomic(bool) = .init(false),
    /// The least left in the queue after a period, in frames, since the feeder last looked.
    min_fill: Atomic(u32) = .init(std.math.maxInt(u32)),
    fill: Atomic(u32) = .init(0),
    device_delay: Atomic(u32) = .init(0),
    active: Atomic(bool) = .init(false),
    /// The queue has been filled to its margin at least once since the monitor came on.
    primed: Atomic(bool) = .init(false),
    /// Where the alarm tone is in its second, in frames of the device's rate. Only
    /// `render` uses it.
    alarm_phase: usize = 0,
    /// Frames handed to the device so far (`render`).
    rendered: Atomic(u64) = .init(0),
    feeder: ?std.Thread = null,
    output: ?std.Thread = null,

    /// Opens the default output device, asking for periods of `period` frames, and starts
    /// both threads. Null (with a warning) if there is no usable device: everything else
    /// works without sound.
    pub fn start(
        gpa: std.mem.Allocator,
        shared: *Shared,
        ring: *dimna.ring.BlockRing,
        fs_in: f64,
        nch: usize,
        block_samples: usize,
        period: u32,
    ) ?*AudioOut {
        const self = gpa.create(AudioOut) catch return null;
        self.* = .{
            .gpa = gpa,
            .shared = shared,
            .ring = ring,
            .fs_in = fs_in,
            .nch = nch,
            .block_samples = block_samples,
            .fifo = .{ .buf = &.{} },
        };
        self.alsa = audio_alsa.open(self, period) catch |e| {
            log.warn("no audio output ({t}); the monitor is silent", .{e});
            gpa.destroy(self);
            return null;
        };
        // A fifth of a second of stereo frames, rounded up to a power of two.
        const cap = std.math.ceilPowerOfTwo(usize, @as(usize, @intFromFloat(self.fs_out / 5)) * 2) catch 32768;
        self.fifo.buf = gpa.alloc(f32, cap) catch {
            audio_alsa.close(self.alsa.?);
            gpa.destroy(self);
            return null;
        };
        self.output = std.Thread.spawn(.{}, audio_alsa.outputLoop, .{self}) catch null;
        self.feeder = std.Thread.spawn(.{}, feederLoop, .{self}) catch null;
        shared.device_rate.store(@intFromFloat(self.fs_out), .monotonic);
        shared.running.store(self.output != null and self.feeder != null, .release);
        log.info("audio output: {d} Hz, {d} frames per period, device buffer {d}", .{ self.fs_out, self.max_request.load(.monotonic), self.device_buffer });
        return self;
    }

    pub fn stop(self: *AudioOut) void {
        self.stop_flag.store(true, .release);
        if (self.feeder) |t| t.join();
        if (self.output) |t| t.join();
        self.shared.running.store(false, .release);
        if (self.alsa) |d| audio_alsa.close(d);
        self.gpa.free(self.fifo.buf);
        self.gpa.destroy(self);
    }

    /// Fills `out[0 .. 2 * frames]` (interleaved stereo) with the next `frames` frames from
    /// the queue, silence where it has none, and the alarm tone over it while the alarm is
    /// on. Called by the device's own thread or callback, once for each request, with any
    /// number of frames. Fit for a real-time callback: atomics only, no lock, no
    /// allocation, no logging, no system call.
    pub fn render(self: *AudioOut, out: []f32, frames: usize) void {
        const buf = out[0 .. 2 * frames];
        if (frames > self.max_request.load(.monotonic)) _ = self.max_request.fetchMax(@intCast(frames), .monotonic);
        const avail = self.fifo.used() / 2;
        // What is left after this request is the headroom against late input.
        const left: u32 = @intCast(avail -| frames);
        _ = self.min_fill.fetchMin(left, .monotonic);
        self.fill.store(@intCast(avail), .monotonic);
        const got = self.fifo.pop(buf[0 .. @min(avail, frames) * 2]);
        @memset(buf[got..], 0);
        // A gap only counts once sound has started arriving (not the silence before
        // the first block, or while the monitor is off).
        if (got < buf.len and self.active.load(.monotonic) and
            self.primed.load(.monotonic)) _ = self.shared.underruns.fetchAdd(1, .monotonic);
        if (self.shared.alarm.load(.monotonic)) {
            // 0.15 s of 880 Hz at the start of every second.
            const rate: usize = @intFromFloat(self.fs_out);
            for (0..frames) |i| {
                const n = (self.alarm_phase + i) % rate;
                if (n < rate * 15 / 100) {
                    const v: f32 = 0.25 * @sin(2.0 * std.math.pi * 880.0 * @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(rate)));
                    buf[2 * i] += v;
                    buf[2 * i + 1] += v;
                }
            }
            self.alarm_phase = (self.alarm_phase + frames) % rate;
        } else self.alarm_phase = 0;
        self.rendered.store(self.rendered.load(.monotonic) + frames, .monotonic);
    }

    fn feederLoop(self: *AudioOut) void {
        self.feed() catch |e| log.warn("the audio feeder stopped: {t}", .{e});
        self.active.store(false, .release);
    }

    fn feed(self: *AudioOut) !void {
        const gpa = self.gpa;
        var reader = dimna.ring.LossyReader.init(self.ring);
        var blk = try dimna.types.Block.init(gpa, self.nch, self.block_samples);
        defer blk.deinit(gpa);
        var monitor: audio.Monitor = .init(gpa, self.fs_in);
        defer monitor.deinit();
        var resampler: audio.Resampler = .init();
        var mixed: std.ArrayList(f32) = .empty;
        defer mixed.deinit(gpa);
        var out: std.ArrayList(f32) = .empty;
        defer out.deinit(gpa);
        var settings: audio.Settings = .{};
        var seen: u32 = 0;
        var integ: f64 = 0;
        var last_ctl = nowNs();
        // The margin adapts: every gap means input came later than the margin allowed
        // for, so it grows by 1 ms; after 30 s without one it comes back down by 0.5 ms.
        // Latency follows what the machine can actually deliver, without gaps going on.
        var margin_ms: f64 = margin_min_ms;
        var seen_underruns = self.shared.underruns.load(.monotonic);
        var quiet_ticks: u32 = 0;
        var last_block = nowNs();
        const ratio = self.fs_out / self.fs_in;
        while (!self.stop_flag.load(.acquire)) {
            if (!reader.next(&blk)) {
                sleepUs(500);
                continue;
            }
            if (blk.len == 0) continue;
            {
                const t = nowNs();
                _ = self.shared.max_block_gap_us.fetchMax(
                    @intCast(@min(@divTrunc(t - last_block, 1000), std.math.maxInt(u32))),
                    .monotonic,
                );
                _ = self.shared.max_block_age_us.fetchMax(
                    @intCast(std.math.clamp(@divTrunc(t - blk.acquired_ns, 1000), 0, std.math.maxInt(u32))),
                    .monotonic,
                );
                last_block = t;
            }
            self.shared.read(&settings, &seen);
            const on = settings.enabled and settings.num_channels > 0;
            self.active.store(on, .monotonic);
            if (!on) {
                self.primed.store(false, .monotonic);
                continue;
            }
            if (self.shared.recalibrate.swap(false, .acq_rel)) monitor.recalibrate();
            mixed.clearRetainingCapacity();
            try monitor.process(&settings, blk.samples(), self.nch, &mixed);
            self.shared.held_sigma_c.store(if (monitor.heldSigma(0)) |s| @intFromFloat(@min(s * 100.0, 4e9)) else 0, .monotonic);

            // Every 100 ms: steer the ratio on the least left in the queue.
            const now = nowNs();
            if (now - last_ctl > 100 * std.time.ns_per_ms) {
                last_ctl = now;
                const underruns = self.shared.underruns.load(.monotonic);
                if (underruns != seen_underruns) {
                    seen_underruns = underruns;
                    margin_ms = @min(margin_ms + 1.0, margin_max_ms);
                    quiet_ticks = 0;
                } else {
                    quiet_ticks += 1;
                    if (quiet_ticks >= 300) {
                        quiet_ticks = 0;
                        margin_ms = @max(margin_min_ms, margin_ms - 0.5);
                    }
                }
                self.shared.margin_us.store(@intFromFloat(margin_ms * 1000), .monotonic);
                const least = self.min_fill.swap(std.math.maxInt(u32), .monotonic);
                if (least != std.math.maxInt(u32)) {
                    const margin = margin_ms * 1e-3 * self.fs_out;
                    const err = (@as(f64, @floatFromInt(least)) - margin) / self.fs_out; // s too many
                    integ = std.math.clamp(integ + err * 0.1, -0.05, 0.05);
                    resampler.adjust = std.math.clamp(-(0.5 * err + 0.05 * integ), -0.005, 0.005);
                }
                const frames: f64 = @floatFromInt(self.fill.load(.monotonic) + self.device_delay.load(.monotonic));
                const lat = frames / self.fs_out + @as(f64, audio.Resampler.delay_in) / self.fs_in + 0.6e-3;
                self.shared.latency_us.store(@intFromFloat(lat * 1e6), .monotonic);
                self.shared.queue_us.store(
                    @intFromFloat(@as(f64, @floatFromInt(self.fill.load(.monotonic))) / self.fs_out * 1e6),
                    .monotonic,
                );
                self.shared.device_us.store(
                    @intFromFloat(@as(f64, @floatFromInt(self.device_delay.load(.monotonic))) / self.fs_out * 1e6),
                    .monotonic,
                );
            }
            out.clearRetainingCapacity();
            try resampler.process(gpa, mixed.items, ratio, &out);
            // Far more queued than needed (start-up, a stall upstream): drop this block's
            // sound, one audible skip, rather than carry the latency for a minute. The
            // slack covers the board's bursty USB delivery.
            const limit: usize = @as(usize, @intFromFloat(margin_ms * 1e-3 * self.fs_out)) + 2 * self.max_request.load(.monotonic) +
                @as(usize, @intFromFloat(self.fs_out * 0.012));
            if (self.fifo.used() / 2 > limit) {
                _ = self.shared.dropped.fetchAdd(1, .monotonic);
                continue;
            }
            const n = self.fifo.push(out.items);
            if (!self.primed.load(.monotonic) and
                self.fifo.used() / 2 >
                    @as(usize, @intFromFloat(margin_ms * 1e-3 * self.fs_out)) + self.max_request.load(.monotonic)) self.primed.store(true, .monotonic);
            if (n < out.items.len) _ = self.shared.dropped.fetchAdd(1, .monotonic);
        }
    }
};

const nowNs = dimna.clock.nowNs;

fn sleepUs(us: u32) void {
    dimna.os.sleepNsOnce(@as(u64, us) * 1000);
}

// ---- tests: `render` without a device ----

const testing = std.testing;

/// An `AudioOut` with a queue of `buf` (a power of two of samples) and no device, ring or
/// threads: only `render` and the queue are used.
fn testOut(shared: *Shared, buf: []f32, fs_out: f64) AudioOut {
    return .{
        .gpa = testing.allocator,
        .shared = shared,
        .ring = undefined,
        .fs_in = 30000,
        .nch = 1,
        .block_samples = 128,
        .fs_out = fs_out,
        .fifo = .{ .buf = buf },
    };
}

test "render: an empty queue gives zeros; a gap counts only when active and primed" {
    var shared: Shared = .{};
    var q: [256]f32 = undefined;
    var a = testOut(&shared, &q, 48000);
    var out: [128]f32 = undefined;
    for ([_][2]bool{ .{ false, false }, .{ true, false }, .{ false, true } }) |state| {
        a.active.store(state[0], .monotonic);
        a.primed.store(state[1], .monotonic);
        @memset(&out, 7);
        a.render(&out, 64);
        for (out) |v| try testing.expectEqual(0, v);
        try testing.expectEqual(0, shared.underruns.load(.monotonic));
    }
    a.active.store(true, .monotonic);
    a.primed.store(true, .monotonic);
    a.render(&out, 64);
    try testing.expectEqual(1, shared.underruns.load(.monotonic));
    // Part of a request: what there is, then zeros, and a gap.
    var some: [20]f32 = undefined;
    for (&some, 0..) |*v, i| v.* = @floatFromInt(i + 1);
    try testing.expectEqual(20, a.fifo.push(&some));
    @memset(&out, 7);
    a.render(&out, 64);
    try testing.expectEqualSlices(f32, &some, out[0..20]);
    for (out[20..]) |v| try testing.expectEqual(0, v);
    try testing.expectEqual(2, shared.underruns.load(.monotonic));
    // A whole request from the queue is no gap.
    for (0..4) |_| _ = a.fifo.push(&some);
    a.render(&out, 40);
    try testing.expectEqual(2, shared.underruns.load(.monotonic));
    try testing.expectEqual(5 * 64 + 40, a.rendered.load(.monotonic));
}

test "render: frames come out in the order pushed, across the queue's wrap, whatever the request" {
    var shared: Shared = .{};
    var q: [256]f32 = undefined; // 128 frames
    var a = testOut(&shared, &q, 48000);
    a.active.store(true, .monotonic);
    a.primed.store(true, .monotonic);
    const out = try testing.allocator.alloc(f32, 2 * 1024);
    defer testing.allocator.free(out);
    var pushed: usize = 0; // samples pushed so far; each sample's value is its index
    var popped: usize = 0;
    var gaps: u64 = 0;
    for (0..12) |round| {
        for ([_]usize{ 1, 64, 100, 128, 1024 }) |frames| {
            // Fill the queue up (an odd number of samples now and then would break the
            // frames apart: push whole frames, as the feeder does).
            var chunk: [256]f32 = undefined;
            const free = (q.len - a.fifo.used()) & ~@as(usize, 1);
            const want = if (round % 3 == 0) @min(free, 2 * 37) else free;
            for (chunk[0..want], 0..) |*v, i| v.* = @floatFromInt(pushed + i);
            try testing.expectEqual(want, a.fifo.push(chunk[0..want]));
            pushed += want;
            const avail = a.fifo.used() / 2;
            @memset(out, -1);
            a.render(out, frames);
            const got = @min(avail, frames);
            for (out[0 .. 2 * got], 0..) |v, i| try testing.expectEqual(@as(f32, @floatFromInt(popped + i)), v);
            for (out[2 * got .. 2 * frames]) |v| try testing.expectEqual(0, v);
            // Nothing beyond the request is touched.
            for (out[2 * frames ..]) |v| try testing.expectEqual(-1, v);
            popped += 2 * got;
            if (got < frames) gaps += 1;
            try testing.expectEqual(gaps, shared.underruns.load(.monotonic));
            // The largest request so far (the queue's default, 128, until 1024 comes).
            try testing.expectEqual(@as(u32, if (round == 0 and frames < 1024) 128 else 1024), a.max_request.load(.monotonic));
        }
    }
    // The queue's indices went round it many times.
    try testing.expect(popped > 20 * q.len);
}

test "render: fill is what was queued before the request, min_fill the least left after one" {
    var shared: Shared = .{};
    var q: [512]f32 = undefined;
    var a = testOut(&shared, &q, 48000);
    var frames100: [200]f32 = @splat(0.5);
    _ = a.fifo.push(&frames100);
    var out: [256]f32 = undefined;
    a.render(&out, 64);
    try testing.expectEqual(100, a.fill.load(.monotonic));
    try testing.expectEqual(36, a.min_fill.load(.monotonic));
    a.render(&out, 16);
    try testing.expectEqual(36, a.fill.load(.monotonic));
    try testing.expectEqual(20, a.min_fill.load(.monotonic));
    a.render(&out, 64); // more than there is: nothing left
    try testing.expectEqual(20, a.fill.load(.monotonic));
    try testing.expectEqual(0, a.min_fill.load(.monotonic));
    // The feeder takes the least and starts again.
    try testing.expectEqual(0, a.min_fill.swap(std.math.maxInt(u32), .monotonic));
    _ = a.fifo.push(frames100[0..100]);
    a.render(&out, 10);
    try testing.expectEqual(50, a.fill.load(.monotonic));
    try testing.expectEqual(40, a.min_fill.load(.monotonic));
    a.render(&out, 128);
    try testing.expectEqual(0, a.min_fill.load(.monotonic));
}

test "render: splitting a request changes nothing (the queue, the alarm's phase)" {
    // The same queue contents each time, the alarm on: 128 frames asked for at once, as
    // 64 + 64, and as 37 + 91, come out the same.
    const splits = [_][]const usize{ &.{128}, &.{ 64, 64 }, &.{ 37, 91 }, &.{ 1, 100, 27 } };
    var results: [splits.len][2 * 128 * 3]f32 = undefined;
    for (splits, 0..) |split, k| {
        var shared: Shared = .{};
        var q: [1024]f32 = undefined;
        var a = testOut(&shared, &q, 48000);
        shared.alarm.store(true, .monotonic);
        var sound: [2 * 300]f32 = undefined;
        for (&sound, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i % 50)) / 100.0 - 0.25;
        _ = a.fifo.push(&sound);
        // Three rounds of 128: the third runs past the 300 frames queued.
        var at: usize = 0;
        for (0..3) |_| for (split) |n| {
            a.render(results[k][2 * at ..], n);
            at += n;
        };
        try testing.expectEqual(3 * 128, at);
    }
    for (results[1..]) |r| try testing.expectEqualSlices(f32, &results[0], &r);
}

/// The alarm tone at frame `n` of a second at `rate` frames per second: what `render` adds.
fn alarmAt(n: usize, rate: usize) f32 {
    if (n % rate >= rate * 15 / 100) return 0;
    const k = n % rate;
    return 0.25 * @sin(2.0 * std.math.pi * 880.0 * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(rate)));
}

test "render: the alarm tone, 0.15 s at the start of each second, continuous across requests of any size" {
    for ([_]usize{ 48000, 44100 }) |rate| {
        var shared: Shared = .{};
        var q: [4096]f32 = undefined;
        var a = testOut(&shared, &q, @floatFromInt(rate));
        const total = 2 * rate + rate / 4;
        const got = try testing.allocator.alloc(f32, 2 * total);
        defer testing.allocator.free(got);
        shared.alarm.store(true, .monotonic);
        const sizes = [_]usize{ 1, 64, 100, 128, 1024, 37, 91 };
        var at: usize = 0;
        var k: usize = 0;
        while (at < total) : (k += 1) {
            const n = @min(sizes[k % sizes.len], total - at);
            a.render(got[2 * at ..], n);
            at += n;
        }
        var on: usize = 0;
        for (0..total) |i| {
            const want = alarmAt(i, rate);
            try testing.expectApproxEqAbs(want, got[2 * i], 1e-6);
            try testing.expectEqual(got[2 * i], got[2 * i + 1]);
            if (got[2 * i] != 0) on += 1;
        }
        // Sounding for (nearly: the sine's zero crossings) 0.15 s of each of the three
        // seconds begun, and silent the rest.
        try testing.expect(on > 3 * (rate * 15 / 100) - 3 * 300 and on <= 3 * (rate * 15 / 100));

        // Off: silence, and on again it starts at the beginning of its second.
        shared.alarm.store(false, .monotonic);
        var out: [2 * 300]f32 = undefined;
        a.render(&out, 300);
        for (out) |v| try testing.expectEqual(0, v);
        shared.alarm.store(true, .monotonic);
        a.render(&out, 300);
        for (0..300) |i| try testing.expectApproxEqAbs(alarmAt(i, rate), out[2 * i], 1e-6);

        // Added to what is playing.
        var sound: [2 * 200]f32 = undefined;
        for (&sound, 0..) |*v, i| v.* = if (i % 2 == 0) 0.1 else -0.2;
        _ = a.fifo.push(&sound);
        a.render(&out, 300);
        for (0..300) |i| {
            const tone = alarmAt(300 + i, rate);
            const l: f32 = if (i < 200) 0.1 else 0;
            const r: f32 = if (i < 200) -0.2 else 0;
            try testing.expectApproxEqAbs(l + tone, out[2 * i], 1e-6);
            try testing.expectApproxEqAbs(r + tone, out[2 * i + 1], 1e-6);
        }
    }
}
