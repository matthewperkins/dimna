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
    /// Held from `start` to `join`: the machine does not sleep when idle (macOS; nothing
    /// on Linux, where it takes no bytes).
    awake: os.Awake = .{},

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
        self.awake = os.keepAwake();
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |e| {
            os.allowSleep(&self.awake);
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
        os.allowSleep(&self.awake);
    }

    /// After the thread ended on a read error (`done`, `failure` set): joins it, stops the
    /// source (as `join`), has it opened again with `settings` (`Source.reopen`: as at
    /// launch), and checks that the data has the shape it had (`layout`). Then the thread
    /// is ready for `start` again, which the caller makes once whatever must see the first
    /// block (a recorder) is attached to the ring. On an error nothing is started and this
    /// may be called again. `error.LayoutChanged`: the board came back with other
    /// headstages or channels (the ring and everything after it are for the old ones).
    /// The ring, its readers and the counters are kept; the source's `Health` is reset by
    /// `start`, as at launch. Not on the acquisition thread.
    pub fn reopenSource(self: *Acquisition, settings: Settings, layout: types.Layout) !void {
        std.debug.assert(self.done.load(.acquire));
        self.join();
        try self.source.reopen(settings);
        if (!sameShape(self.source.layout(), layout)) {
            log.err("the board came back with another layout (headstages, channels or rate); not restarting", .{});
            return error.LayoutChanged;
        }
        self.stop_flag.store(false, .release);
        self.done.store(false, .release);
        self.failure = null;
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
        if (self.source.wantsRealtime()) self.realtime.store(setRealtime(realtime_priority) != null, .release);
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

/// Whether blocks of `a` and `b` have the same shape and meaning: rate, board clock,
/// headstages (slot, chip, channels) and the AUX and ADC channels.
pub fn sameShape(a: types.Layout, b: types.Layout) bool {
    if (a.sample_rate != b.sample_rate or a.hw_clock_hz != b.hw_clock_hz or a.num_headstages != b.num_headstages or
        a.num_electrodes != b.num_electrodes or a.num_aux != b.num_aux or a.num_adc != b.num_adc or
        a.ttl_lines != b.ttl_lines) return false;
    for (a.headstageSlice(), b.headstageSlice()) |x, y| {
        if (x.slot != y.slot or x.num_channels != y.num_channels or x.first_channel != y.first_channel or
            x.has_bno != y.has_bno or !std.mem.eql(u8, x.chip, y.chip)) return false;
    }
    return true;
}

/// The `SCHED_FIFO` priority the acquisition thread asks for: above PipeWire's own thread
/// inside dimna (`data-loop.0`), which asks for 88 and gets what the limit allows.
pub const realtime_priority = 90;

/// SCHED_FIFO at `priority` for the calling thread; if that is refused, at the highest the
/// limit allows (`RLIMIT_RTPRIO`, `ulimit -r`; Linux only), with one warning. The priority
/// it got, or null: refused, the thread stays at normal priority. Needs rtprio (e.g. the
/// `realtime` group, which packaging/99-dimna-realtime.conf gives 95).
pub fn setRealtime(priority: i32) ?i32 {
    var err = os.setThreadRealtime(priority);
    if (err == .SUCCESS) return priority;
    if (os.realtimeLimit()) |limit| if (limit >= 1 and limit < priority) {
        const lower = os.setThreadRealtime(limit);
        if (lower == .SUCCESS) {
            log.warn("SCHED_FIFO {d} refused (errno {t}); running at SCHED_FIFO {d}, the most the real-time limit allows (ulimit -r): it should be 95 (packaging/99-dimna-realtime.conf), for acquisition to run above PipeWire's thread", .{ priority, err, limit });
            return limit;
        }
        err = lower;
    };
    log.warn("could not get SCHED_FIFO (errno {t}); running at normal priority", .{err});
    return null;
}

/// Locks current and future pages in RAM, so acquisition never waits on a page-in.
pub fn lockMemory() bool {
    return os.lockMemory();
}

const testing = std.testing;

test "setRealtime: 90 when the limit allows it, else the limit's value (run under prlimit --rtprio=10:10 for the second)" {
    // macOS has no such limit and ignores the number (its os test covers the call).
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const limit = os.realtimeLimit() orelse return error.NoLimit;
    // As an unprivileged user: the limit is what decides (root gets 90 whatever it is).
    const want: ?i32 = if (limit >= realtime_priority) realtime_priority else if (limit >= 1) limit else null;
    const Seen = struct { got: ?i32 = null, policy: i64 = -1, priority: i64 = -1, failed: ?anyerror = null };
    var seen: Seen = .{};
    // On a thread of its own, which exits with what it got.
    const t = try std.Thread.spawn(.{}, struct {
        fn run(out: *Seen) void {
            out.got = setRealtime(realtime_priority);
            // What the kernel says of this thread: rt_priority and policy (1 = SCHED_FIFO),
            // fields 40 and 41 of /proc/self/task/<tid>/stat.
            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/self/task/{d}/stat", .{std.Thread.getCurrentId()}, 0) catch unreachable;
            const fd = os.openRead(path) orelse {
                out.failed = error.NoStatFile;
                return;
            };
            defer os.close(fd);
            var buf: [4096]u8 = undefined;
            const text = buf[0 .. os.pread(fd, &buf, buf.len, 0) orelse {
                out.failed = error.StatUnreadable;
                return;
            }];
            // After the name, which is in parentheses and may hold spaces: field 3 onwards.
            const rest = text[(std.mem.lastIndexOfScalar(u8, text, ')') orelse return) + 2 ..];
            var it = std.mem.tokenizeScalar(u8, rest, ' ');
            var field: usize = 3;
            while (it.next()) |f| : (field += 1) {
                if (field == 40) out.priority = std.fmt.parseInt(i64, f, 10) catch -1;
                if (field == 41) out.policy = std.fmt.parseInt(i64, std.mem.trimEnd(u8, f, "\n"), 10) catch -1;
            }
        }
    }.run, .{&seen});
    t.join();
    if (seen.failed) |e| return e;
    std.debug.print("RLIMIT_RTPRIO {d}: asked for {d}, got {?d}; the kernel says policy {d}, rt_priority {d}\n", .{ limit, realtime_priority, seen.got, seen.policy, seen.priority });
    try testing.expectEqual(want, seen.got);
    if (want) |p| {
        try testing.expectEqual(1, seen.policy);
        try testing.expectEqual(p, seen.priority);
    } else try testing.expectEqual(0, seen.priority);
}

test "sameShape: the same layout, and each way one can differ" {
    var a: types.Layout = .{ .sample_rate = 30000, .hw_clock_hz = 50e6, .num_headstages = 2, .num_electrodes = 48, .num_adc = 8 };
    a.headstages[0] = .{ .slot = 0, .chip = "RHD2132", .num_channels = 32, .first_channel = 0, .has_bno = false };
    a.headstages[1] = .{ .slot = 2, .chip = "RHD2216", .num_channels = 16, .first_channel = 32, .has_bno = false };
    try testing.expect(sameShape(a, a));
    var b = a;
    b.sample_rate = 20000;
    try testing.expect(!sameShape(a, b));
    b = a;
    b.num_adc = 0;
    try testing.expect(!sameShape(a, b));
    b = a;
    b.headstages[1].slot = 3;
    try testing.expect(!sameShape(a, b));
    b = a;
    b.headstages[0].chip = "RHD2164";
    try testing.expect(!sameShape(a, b));
    b = a;
    b.num_headstages = 1;
    b.num_electrodes = 32;
    try testing.expect(!sameShape(a, b));
}

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
