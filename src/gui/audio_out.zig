//! The spike audio monitor's output: two threads beside the display.
//!
//!   feeder: reads the acquisition ring with a lossy reader of its own (so sound never
//!     depends on the display's frame rate, and never holds acquisition back), runs the
//!     chain in `audio.zig`, resamples to the device's rate and puts the result in a small
//!     queue;
//!   output: hands the device one period at a time (ALSA; on this machine PipeWire's ALSA
//!     device), with silence when the queue is empty.
//!
//! The board's clock and the sound card's differ slightly, so the feeder trims the
//! resampling ratio to keep the queue just above empty: it steers on the least that was
//! left after any period in the last 100 ms (what protects against late input), towards
//! a margin. The margin itself adapts: each gap in the sound raises it by 1 ms (input came
//! later than it allowed for), and 30 s without one lowers it by 0.5 ms, between 1.5 and
//! 25 ms. So latency settles at what this machine's timing needs, instead of gaps going on. If the queue ever holds much more than that (a stall upstream, start-up),
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
const oez = @import("oez");
const audio = oez.audio;
const alsa = @import("gui_c");
const linux = std.os.linux;
const Atomic = std.atomic.Value;
const log = std.log.scoped(.audio);

pub const Shared = struct {
    seq: Atomic(u32) = .init(0),
    settings: audio.Settings = .{},
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
        _ = self.seq.fetchAdd(1, .acq_rel);
        self.settings = s.*;
        _ = self.seq.fetchAdd(1, .release);
    }

    fn read(self: *Shared, out: *audio.Settings, seen: *u32) void {
        var tries: usize = 0;
        while (tries < 100) : (tries += 1) {
            const before = self.seq.load(.acquire);
            if (before == seen.*) return;
            if (before & 1 != 0) {
                std.atomic.spinLoopHint();
                continue;
            }
            const copy = self.settings;
            if (self.seq.load(.acquire) != before) continue;
            out.* = copy;
            seen.* = before;
            return;
        }
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

/// The least kept in the queue when all is quiet, and the most the feeder will go to.
const margin_min_ms = 1.5;
const margin_max_ms = 25.0;

pub const AudioOut = struct {
    gpa: std.mem.Allocator,
    shared: *Shared,
    ring: *oez.ring.BlockRing,
    fs_in: f64,
    nch: usize,
    block_samples: usize,
    pcm: ?*alsa.snd_pcm_t = null,
    fs_out: f64 = 48000,
    period: usize = 128,
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
    feeder: ?std.Thread = null,
    output: ?std.Thread = null,

    /// Opens the default output device and starts both threads. Null (with a warning) if
    /// there is no usable device: everything else works without sound.
    pub fn start(gpa: std.mem.Allocator, shared: *Shared, ring: *oez.ring.BlockRing, fs_in: f64, nch: usize, block_samples: usize) ?*AudioOut {
        const self = gpa.create(AudioOut) catch return null;
        self.* = .{ .gpa = gpa, .shared = shared, .ring = ring, .fs_in = fs_in, .nch = nch, .block_samples = block_samples, .fifo = .{ .buf = &.{} } };
        self.open() catch |e| {
            log.warn("no audio output ({t}); the monitor is silent", .{e});
            gpa.destroy(self);
            return null;
        };
        // A fifth of a second of stereo frames, rounded up to a power of two.
        const cap = std.math.ceilPowerOfTwo(usize, @as(usize, @intFromFloat(self.fs_out / 5)) * 2) catch 32768;
        self.fifo.buf = gpa.alloc(f32, cap) catch {
            _ = alsa.snd_pcm_close(self.pcm);
            gpa.destroy(self);
            return null;
        };
        self.output = std.Thread.spawn(.{}, outputLoop, .{self}) catch null;
        self.feeder = std.Thread.spawn(.{}, feederLoop, .{self}) catch null;
        shared.device_rate.store(@intFromFloat(self.fs_out), .monotonic);
        shared.running.store(self.output != null and self.feeder != null, .release);
        log.info("audio output: {d} Hz, {d} frames per period, device buffer {d}", .{ self.fs_out, self.period, self.device_buffer });
        return self;
    }

    pub fn stop(self: *AudioOut) void {
        self.stop_flag.store(true, .release);
        if (self.feeder) |t| t.join();
        if (self.output) |t| t.join();
        self.shared.running.store(false, .release);
        if (self.pcm) |p| _ = alsa.snd_pcm_close(p);
        self.gpa.free(self.fifo.buf);
        self.gpa.destroy(self);
    }

    fn open(self: *AudioOut) !void {
        var pcm: ?*alsa.snd_pcm_t = null;
        if (alsa.snd_pcm_open(&pcm, "default", alsa.SND_PCM_STREAM_PLAYBACK, 0) < 0) return error.NoDevice;
        errdefer _ = alsa.snd_pcm_close(pcm);
        var hw: ?*alsa.snd_pcm_hw_params_t = null;
        if (alsa.snd_pcm_hw_params_malloc(&hw) < 0) return error.OutOfMemory;
        defer alsa.snd_pcm_hw_params_free(hw);
        if (alsa.snd_pcm_hw_params_any(pcm, hw) < 0) return error.DeviceParams;
        if (alsa.snd_pcm_hw_params_set_access(pcm, hw, alsa.SND_PCM_ACCESS_RW_INTERLEAVED) < 0) return error.DeviceParams;
        if (alsa.snd_pcm_hw_params_set_format(pcm, hw, alsa.SND_PCM_FORMAT_FLOAT_LE) < 0) return error.DeviceFormat;
        if (alsa.snd_pcm_hw_params_set_channels(pcm, hw, 2) < 0) return error.DeviceChannels;
        var rate: c_uint = 48000;
        if (alsa.snd_pcm_hw_params_set_rate_near(pcm, hw, &rate, null) < 0) return error.DeviceRate;
        // Small periods: each is latency. Two of them as the device's own buffer.
        var period: alsa.snd_pcm_uframes_t = 128;
        _ = alsa.snd_pcm_hw_params_set_period_size_near(pcm, hw, &period, null);
        var buffer: alsa.snd_pcm_uframes_t = period * 2;
        _ = alsa.snd_pcm_hw_params_set_buffer_size_near(pcm, hw, &buffer);
        if (alsa.snd_pcm_hw_params(pcm, hw) < 0) return error.DeviceParams;
        _ = alsa.snd_pcm_hw_params_get_period_size(hw, &period, null);
        _ = alsa.snd_pcm_hw_params_get_buffer_size(hw, &buffer);
        self.device_buffer = @intCast(buffer);
        _ = alsa.snd_pcm_hw_params_get_rate(hw, &rate, null);
        if (alsa.snd_pcm_prepare(pcm) < 0) return error.DevicePrepare;
        self.pcm = pcm;
        self.fs_out = @floatFromInt(rate);
        self.period = @intCast(period);
    }

    fn outputLoop(self: *AudioOut) void {
        const buf = self.gpa.alloc(f32, self.period * 2) catch return;
        defer self.gpa.free(buf);
        var alarm_phase: usize = 0;
        while (!self.stop_flag.load(.acquire)) {
            const avail = self.fifo.used() / 2;
            // What is left after this period is the headroom against late input.
            const left: u32 = @intCast(avail -| self.period);
            _ = self.min_fill.fetchMin(left, .monotonic);
            self.fill.store(@intCast(avail), .monotonic);
            const got = self.fifo.pop(buf[0 .. @min(avail, self.period) * 2]);
            @memset(buf[got..], 0);
            // A gap only counts once sound has started arriving (not the silence before
            // the first block, or while the monitor is off).
            if (got < buf.len and self.active.load(.monotonic) and self.primed.load(.monotonic)) _ = self.shared.underruns.fetchAdd(1, .monotonic);
            if (self.shared.alarm.load(.monotonic)) {
                // 0.15 s of 880 Hz at the start of every second.
                const rate: usize = @intFromFloat(self.fs_out);
                for (0..self.period) |i| {
                    const n = (alarm_phase + i) % rate;
                    if (n < rate * 15 / 100) {
                        const v: f32 = 0.25 * @sin(2.0 * std.math.pi * 880.0 * @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(rate)));
                        buf[2 * i] += v;
                        buf[2 * i + 1] += v;
                    }
                }
                alarm_phase = (alarm_phase + self.period) % rate;
            } else alarm_phase = 0;
            const wrote = alsa.snd_pcm_writei(self.pcm, buf.ptr, self.period);
            if (wrote < 0) {
                // An xrun or a suspended device: start again.
                if (alsa.snd_pcm_recover(self.pcm, @intCast(wrote), 1) < 0) {
                    log.warn("the audio device stopped: {s}", .{alsa.snd_strerror(@intCast(wrote))});
                    self.shared.running.store(false, .release);
                    return;
                }
            }
            var delay: alsa.snd_pcm_sframes_t = 0;
            if (alsa.snd_pcm_delay(self.pcm, &delay) == 0 and delay >= 0) self.device_delay.store(@intCast(delay), .monotonic);
        }
    }

    fn feederLoop(self: *AudioOut) void {
        self.feed() catch |e| log.warn("the audio feeder stopped: {t}", .{e});
        self.active.store(false, .release);
    }

    fn feed(self: *AudioOut) !void {
        const gpa = self.gpa;
        var reader = oez.ring.LossyReader.init(self.ring);
        var blk = try oez.types.Block.init(gpa, self.nch, self.block_samples);
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
                _ = self.shared.max_block_gap_us.fetchMax(@intCast(@min(@divTrunc(t - last_block, 1000), std.math.maxInt(u32))), .monotonic);
                _ = self.shared.max_block_age_us.fetchMax(@intCast(std.math.clamp(@divTrunc(t - blk.acquired_ns, 1000), 0, std.math.maxInt(u32))), .monotonic);
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
                self.shared.queue_us.store(@intFromFloat(@as(f64, @floatFromInt(self.fill.load(.monotonic))) / self.fs_out * 1e6), .monotonic);
                self.shared.device_us.store(@intFromFloat(@as(f64, @floatFromInt(self.device_delay.load(.monotonic))) / self.fs_out * 1e6), .monotonic);
            }
            out.clearRetainingCapacity();
            try resampler.process(gpa, mixed.items, ratio, &out);
            // Far more queued than needed (start-up, a stall upstream): drop this block's
            // sound, one audible skip, rather than carry the latency for a minute. The
            // slack covers the board's bursty USB delivery.
            const limit: usize = @as(usize, @intFromFloat(margin_ms * 1e-3 * self.fs_out)) + 2 * self.period + @as(usize, @intFromFloat(self.fs_out * 0.012));
            if (self.fifo.used() / 2 > limit) {
                _ = self.shared.dropped.fetchAdd(1, .monotonic);
                continue;
            }
            const n = self.fifo.push(out.items);
            if (!self.primed.load(.monotonic) and self.fifo.used() / 2 > @as(usize, @intFromFloat(margin_ms * 1e-3 * self.fs_out)) + self.period) self.primed.store(true, .monotonic);
            if (n < out.items.len) _ = self.shared.dropped.fetchAdd(1, .monotonic);
        }
    }
};

fn nowNs() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn sleepUs(us: u32) void {
    const ts: linux.timespec = .{ .sec = 0, .nsec = @as(isize, us) * 1000 };
    _ = linux.nanosleep(&ts, null);
}
