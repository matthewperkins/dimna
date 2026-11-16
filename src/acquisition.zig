//! The acquisition thread: owns the source (the board or the simulator) while running, reads blocks straight into a ring
//! slot and commits them. It never waits on a consumer. If the ring is full the block is read
//! into a scratch block and counted as `ring_overflow` (data lost to the pipeline, loudly);
//! the board keeps being drained so its DRAM buffer never fills.
//!
//! Settings changes while acquiring arrive as `Command`s on a lock-free queue, and the thread
//! applies them between blocks. Each applied change is stamped with the sample number and sent
//! to the recorder (`events`) for events.tsv. See `classify` for which changes can be made
//! live, which reprogram the amplifiers gap-free, and which need a restart (refused while
//! recording).

const std = @import("std");
const types = @import("types.zig");
const board_mod = @import("board.zig");
const events = @import("events.zig");
const Board = board_mod.Board;
const BlockRing = @import("ring.zig").BlockRing;
const Source = @import("source.zig").Source;
const LiveCommand = types.LiveCommand;
const Settings = types.Settings;
const Atomic = std.atomic.Value;
const os = @import("os.zig");
const log = std.log.scoped(.acquisition);

pub const Command = union(enum) {
    /// Outputs and indicators: register writes that leave the data stream untouched.
    live: LiveCommand,
    /// Amplifier bandwidth, DSP high-pass, fast settle: reprogrammed without a gap.
    amp: Board.AmpSettings,
};

pub const Change = enum {
    none,
    /// Only outputs or indicators differ (`Command.live`).
    live,
    /// Amplifier settings differ, perhaps with outputs too (`Command.amp` plus `.live`).
    amplifier,
    /// Rate, channel set, cable delays or USB block size differ: stop, apply, restart.
    restart,
};

/// How `new` can be applied to a board running with `old`.
pub fn classify(old: Settings, new: Settings) Change {
    if (old.sample_rate != new.sample_rate or old.acquire_aux != new.acquire_aux or old.acquire_adc != new.acquire_adc or
        !std.mem.eql(bool, &old.rhd2132_16ch, &new.rhd2132_16ch) or old.usb_block_bytes != new.usb_block_bytes or
        old.block_samples != new.block_samples or !std.mem.eql(i32, &old.cable_delay_adjust, &new.cable_delay_adjust) or
        !std.mem.eql(f32, &old.cable_length_m, &new.cable_length_m)) return .restart;
    if (old.lower_bandwidth != new.lower_bandwidth or old.upper_bandwidth != new.upper_bandwidth or
        old.dsp_enabled != new.dsp_enabled or old.dsp_cutoff != new.dsp_cutoff or old.fast_settle != new.fast_settle) return .amplifier;
    if (old.leds != new.leds or old.ttl_output_mode != new.ttl_output_mode or old.dac_hpf_enabled != new.dac_hpf_enabled or
        old.dac_hpf_hz != new.dac_hpf_hz or old.noise_slicer != new.noise_slicer or old.fast_ttl_settle != new.fast_ttl_settle or
        old.clock_divider != new.clock_divider) return .live;
    return .none;
}

pub const ApplyError = error{
    /// The change needs a restart, which is refused while recording.
    RecordingActive,
    /// The change needs a restart: stop, `Board.applySettings`, start again.
    NeedsRestart,
    /// The command queue is full; try again shortly.
    QueueFull,
};

pub const Acquisition = struct {
    io: std.Io,
    source: Source,
    ring: *BlockRing,
    health: *types.Health,
    scratch: types.Block,
    stop_flag: Atomic(bool) = .init(false),
    /// True once the thread has exited (normally or on an error).
    done: Atomic(bool) = .init(false),
    /// Blocks the ring could not take.
    ring_overflow: Atomic(u64) = .init(0),
    /// Set when the thread got SCHED_FIFO.
    realtime: Atomic(bool) = .init(false),
    failure: ?anyerror = null,
    thread: ?std.Thread = null,

    commands: events.Spsc(Command, 32) = .{},
    /// Applied settings changes, for the recorder (events.tsv). Single consumer.
    events: events.EventQueue = .{},
    submitted: u64 = 0,
    applied: Atomic(u64) = .init(0),
    failed: Atomic(u64) = .init(0),
    /// Longest time spent applying one command, in µs (blocks wait meanwhile).
    max_apply_us: Atomic(u64) = .init(0),
    /// The settings as last requested through `applySettings` (owned by the caller's thread).
    requested: Settings = .{},

    /// Starts the board and the thread. `self` must stay at a fixed address until `join`.
    pub fn start(self: *Acquisition) !void {
        self.requested = self.source.settings();
        try self.source.start(self.health);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |e| {
            self.source.stop() catch {};
            return e;
        };
        self.thread.?.setName(self.io, "acquisition") catch {};
    }

    /// Asks the thread to stop, waits for it, then stops the board.
    pub fn join(self: *Acquisition) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        self.source.stop() catch |e| log.warn("stopping the source failed: {t}", .{e});
    }

    /// Queues one command for the acquisition thread.
    pub fn submit(self: *Acquisition, cmd: Command) ApplyError!void {
        if (!self.commands.push(cmd)) return error.QueueFull;
        self.submitted += 1;
    }

    /// Applies `new` while acquiring, as far as possible without a gap. Refuses changes that
    /// need a restart while `recording`; otherwise reports `NeedsRestart` for them.
    pub fn applySettings(self: *Acquisition, new: Settings, recording: bool) ApplyError!Change {
        const old = self.requested;
        const change = classify(old, new);
        switch (change) {
            .none => return .none,
            .restart => return if (recording) error.RecordingActive else error.NeedsRestart,
            .live, .amplifier => {},
        }
        if (change == .amplifier) try self.submit(.{ .amp = .{
            .lower_bandwidth = new.lower_bandwidth,
            .upper_bandwidth = new.upper_bandwidth,
            .dsp_enabled = new.dsp_enabled,
            .dsp_cutoff = new.dsp_cutoff,
            .fast_settle = new.fast_settle,
        } });
        if (old.leds != new.leds) try self.submit(.{ .live = .{ .set_leds = new.leds } });
        if (old.ttl_output_mode != new.ttl_output_mode) try self.submit(.{ .live = .{ .set_ttl_mode = new.ttl_output_mode } });
        if (old.dac_hpf_enabled != new.dac_hpf_enabled or old.dac_hpf_hz != new.dac_hpf_hz) try self.submit(.{ .live = .{ .set_dac_hpf = .{
            .enabled = new.dac_hpf_enabled,
            .hz = new.dac_hpf_hz,
        } } });
        if (old.noise_slicer != new.noise_slicer) try self.submit(.{ .live = .{ .set_noise_slicer = new.noise_slicer } });
        if (old.fast_ttl_settle != new.fast_ttl_settle) try self.submit(.{ .live = .{ .set_fast_ttl_settle = new.fast_ttl_settle } });
        if (old.clock_divider != new.clock_divider) try self.submit(.{ .live = .{ .set_clock_divider = new.clock_divider } });
        self.requested = new;
        return change;
    }

    /// True once every submitted command has been applied (or has failed).
    pub fn idle(self: *const Acquisition) bool {
        return self.applied.load(.acquire) + self.failed.load(.acquire) == self.submitted;
    }

    fn run(self: *Acquisition) void {
        if (self.source.wantsRealtime()) self.realtime.store(setRealtime(70), .release);
        defer self.done.store(true, .release);
        var next_sample: i64 = 0;
        while (!self.stop_flag.load(.acquire)) {
            const slot = self.ring.writeSlot();
            const blk = slot orelse &self.scratch;
            self.source.readBlock(blk) catch |e| {
                self.failure = e;
                log.err("acquisition stopped by a read error: {t}", .{e});
                return;
            };
            blk.acquired_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
            next_sample = blk.first_sample + @as(i64, @intCast(blk.len));
            if (slot != null) self.ring.commit() else _ = self.ring_overflow.fetchAdd(1, .monotonic);
            while (self.commands.pop()) |cmd| self.apply(cmd, next_sample);
        }
    }

    /// Applies one command and stamps the event with the estimated sample at which the
    /// change reached the board: the next sample not yet read when the command started, plus
    /// the time until the effective register write at the sample rate. (Samples in flight
    /// over USB were all taken before that write, so the estimate is not early.)
    fn apply(self: *Acquisition, cmd: Command, next_sample: i64) void {
        const t0 = std.Io.Clock.awake.now(self.io);
        const rate = self.source.sampleRate();
        const at = struct {
            fn f(first: i64, from: i96, to: i96, fs: f64) i64 {
                return first + @as(i64, @intFromFloat(@round(@as(f64, @floatFromInt(to - from)) * 1e-9 * fs)));
            }
        }.f;
        var ev: events.Event = undefined;
        const ok = switch (cmd) {
            .amp => |a| blk: {
                const actual = self.source.setAmpLive(a, t0.nanoseconds) catch |e| {
                    ev = .init(
                        at(next_sample, t0.nanoseconds, std.Io.Clock.awake.now(self.io).nanoseconds, rate),
                        "amplifier_failed",
                        "{t}",
                        .{e},
                    );
                    break :blk false;
                };
                ev = .init(
                    at(next_sample, t0.nanoseconds, actual.switched_ns, rate),
                    "amplifier",
                    "lower_hz={d:.3} upper_hz={d:.1} dsp={s} dsp_cutoff_hz={d:.3} fast_settle={s} (requested {d}..{d} Hz)",
                    .{
                        actual.lower,
                        actual.upper,
                        if (a.dsp_enabled) "on" else "off",
                        actual.dsp_cutoff,
                        if (a.fast_settle) "on" else "off",
                        a.lower_bandwidth,
                        a.upper_bandwidth,
                    },
                );
                break :blk true;
            },
            .live => |l| blk: {
                const ok = if (self.source.live(l)) true else |e| fail: {
                    ev = .init(
                        at(next_sample, t0.nanoseconds, std.Io.Clock.awake.now(self.io).nanoseconds, rate),
                        "output_failed",
                        "{t} {t}",
                        .{ std.meta.activeTag(l), e },
                    );
                    break :fail false;
                };
                if (!ok) break :blk false;
                const sample = at(next_sample, t0.nanoseconds, std.Io.Clock.awake.now(self.io).nanoseconds, rate);
                ev = switch (l) {
                    .set_ttl_out => |w| .init(sample, "ttl_out", "0x{x:0>4}", .{w}),
                    .dac_route => |r| .init(
                        sample,
                        "dac_route",
                        "dac={d} electrode={?d} threshold_uv={d}",
                        .{ r.dac + 1, r.electrode, r.threshold_uv },
                    ),
                    .set_leds => |on| .init(sample, "leds", "{s}", .{if (on) "on" else "off"}),
                    .set_dac_hpf => |h| .init(sample, "dac_hpf", "{s} {d} Hz", .{ if (h.enabled) "on" else "off", h.hz }),
                    .set_noise_slicer => |n| .init(sample, "noise_slicer", "{d}", .{n}),
                    .set_ttl_mode => |on| .init(sample, "ttl_mode", "{s}", .{if (on) "dac_threshold" else "software"}),
                    .set_fast_ttl_settle => |c| .init(sample, "fast_ttl_settle", "{?d}", .{c}),
                    .set_clock_divider => |d| .init(sample, "clock_divider", "{d}", .{d}),
                };
                break :blk true;
            },
        };
        _ = self.max_apply_us.fetchMax(@intCast(t0.untilNow(self.io, .awake).toMicroseconds()), .monotonic);
        _ = self.events.push(ev);
        if (ok) _ = self.applied.fetchAdd(1, .release) else _ = self.failed.fetchAdd(1, .release);
    }
};

/// SCHED_FIFO at `priority` for the calling thread. Needs rtprio (e.g. the `realtime` group).
pub fn setRealtime(priority: i32) bool {
    const err = os.setThreadRealtime(priority);
    if (err != .SUCCESS) {
        log.warn("could not get SCHED_FIFO (errno {t}); running at normal priority", .{err});
        return false;
    }
    return true;
}

/// Locks current and future pages in RAM, so acquisition never waits on a page-in.
pub fn lockMemory() bool {
    return os.lockMemory();
}

const testing = std.testing;

test "classify sorts settings changes" {
    const a: Settings = .{};
    var b = a;
    try testing.expectEqual(Change.none, classify(a, b));
    b.leds = true;
    try testing.expectEqual(Change.live, classify(a, b));
    b.lower_bandwidth = 300;
    try testing.expectEqual(Change.amplifier, classify(a, b));
    b.acquire_adc = true;
    try testing.expectEqual(Change.restart, classify(a, b));
    b = a;
    b.rhd2132_16ch[0] = true;
    try testing.expectEqual(Change.restart, classify(a, b));
}
