//! oez-headless: open the board, acquire for a while, and check the stream.
//!
//!   oez-headless [--seconds S] [--16ch A1,B1] [--aux] [--adc] [--leds] [--rate HZ] [--block N]
//!                [--record ROOT] [--live-test] [--driver d3xx|usb] [--usb-block BYTES]
//!                [--sim 32,16] [--band LOW,HIGH] [--no-dsp]
//!
//! --sim runs from simulated headstages (channels each) instead of the board: no hardware is
//! touched, and the acquisition thread does not ask for real-time priority.
//!
//! --band sets the amplifier band in Hz and --no-dsp turns the chips' DSP high-pass off, for
//! every port (see docs/OPEN.md: this board does not take different settings per port).
//!
//! --usb-block sets how many bytes liboni fetches at a time (default 8192, about 1.4 ms at 46
//! channels). Nothing reaches the pipeline until a block is complete, so smaller means lower
//! latency and more USB transfers.
//!
//! --driver usb (the default) talks to the FT600 directly through the kernel, with no FTDI
//! library; d3xx uses liboni's ft600 driver on FTDI's D3XX, as a fallback.
//!
//! --live-test changes settings on a schedule while acquiring (needs >= 26 s; use with
//! --record so the changes are stamped in events.tsv): at 2 s it asks to turn ADC acquisition
//! off (must be refused while recording), LEDs on/off at 4/6 s, lower bandwidth 300 Hz at
//! 8 s and back to 1 Hz at 14 s, upper bandwidth 1 kHz at 18 s and back to 7.5 kHz at 22 s.
//!
//! Prints one status line per second. `delivery` is how much later than the quickest block of
//! that second a block's newest sample reached the ring (USB block granularity shows here).
//! Besides the driver's own counters it checks, as a
//! consumer, that blocks arrive contiguous (`gapblk`) and that the board clock advances by
//! about one sample period every sample (`tstep`, in board-clock ticks: 1666.7 at 30 kHz and
//! 50 MHz; it jitters by about ±10 ticks, and a lost sample would show as ~2×). Exit status 1
//! if anything was lost.

const std = @import("std");
const dimna = @import("dimna");
const Board = dimna.board.Board;
const Io = std.Io;
const log = std.log.scoped(.headless);

pub const std_options: std.Options = .{ .log_level = .info };

var interrupted: std.atomic.Value(bool) = .init(false);

fn onSigint(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

const Args = struct {
    seconds: f64 = 10.0,
    record_root: ?[]const u8 = null,
    live_test: bool = false,
    driver: dimna.board.Driver = .usb,
    settings: dimna.types.Settings = .{},
    /// Simulated headstages (channels each) instead of the board.
    sim: [8]usize = @splat(0),
    num_sim: usize = 0,
};

fn parseArgs(args: []const [:0]const u8) !Args {
    var a: Args = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const next = struct {
            fn f(list: []const [:0]const u8, idx: *usize, name: []const u8) ![]const u8 {
                idx.* += 1;
                if (idx.* >= list.len) {
                    log.err("{s} needs a value", .{name});
                    return error.BadArgs;
                }
                return list[idx.*];
            }
        }.f;
        if (std.mem.eql(u8, arg, "--seconds")) {
            a.seconds = try std.fmt.parseFloat(f64, try next(args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--rate")) {
            a.settings.sample_rate = try std.fmt.parseInt(u32, try next(args, &i, arg), 10);
        } else if (std.mem.eql(u8, arg, "--usb-block")) {
            a.settings.usb_block_bytes = try std.fmt.parseInt(u32, try next(args, &i, arg), 10);
        } else if (std.mem.eql(u8, arg, "--block")) {
            a.settings.block_samples = try std.fmt.parseInt(usize, try next(args, &i, arg), 10);
        } else if (std.mem.eql(u8, arg, "--record")) {
            a.record_root = try next(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--driver")) {
            const name = try next(args, &i, arg);
            a.driver = std.meta.stringToEnum(dimna.board.Driver, name) orelse {
                log.err("--driver: '{s}' is not d3xx or usb", .{name});
                return error.BadArgs;
            };
        } else if (std.mem.eql(u8, arg, "--sim")) {
            var it = std.mem.tokenizeScalar(u8, try next(args, &i, arg), ',');
            while (it.next()) |n| {
                const ch = std.fmt.parseInt(usize, n, 10) catch 0;
                if ((ch != 16 and ch != 32 and ch != 64) or a.num_sim == a.sim.len) {
                    log.err("--sim: give up to 8 headstages of 16, 32 or 64 channels, e.g. 32,16", .{});
                    return error.BadArgs;
                }
                a.sim[a.num_sim] = ch;
                a.num_sim += 1;
            }
        } else if (std.mem.eql(u8, arg, "--live-test")) {
            a.live_test = true;
        } else if (std.mem.eql(u8, arg, "--band")) {
            // LOW,HIGH: the amplifier band in Hz.
            var it = std.mem.tokenizeScalar(u8, try next(args, &i, arg), ',');
            a.settings.lower_bandwidth = try std.fmt.parseFloat(f64, it.next() orelse "");
            a.settings.upper_bandwidth = try std.fmt.parseFloat(f64, it.next() orelse "");
        } else if (std.mem.eql(u8, arg, "--no-dsp")) {
            a.settings.dsp_enabled = false;
        } else if (std.mem.eql(u8, arg, "--aux")) {
            a.settings.acquire_aux = true;
        } else if (std.mem.eql(u8, arg, "--adc")) {
            a.settings.acquire_adc = true;
        } else if (std.mem.eql(u8, arg, "--leds")) {
            a.settings.leds = true;
        } else if (std.mem.eql(u8, arg, "--16ch")) {
            var it = std.mem.tokenizeScalar(u8, try next(args, &i, arg), ',');
            while (it.next()) |name| {
                const slot = for (dimna.types.headstage_names, 0..) |n, k| {
                    if (std.ascii.eqlIgnoreCase(n, name)) break k;
                } else {
                    log.err("--16ch: unknown headstage slot '{s}' (use A1..D2)", .{name});
                    return error.BadArgs;
                };
                a.settings.rhd2132_16ch[slot] = true;
            }
        } else {
            log.err("unknown argument '{s}'", .{arg});
            return error.BadArgs;
        }
    }
    return a;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const args = parseArgs(try init.minimal.args.toSlice(init.arena.allocator())) catch return 2;

    var board: ?Board = null;
    defer if (board) |*b| b.close();
    var sim: ?dimna.sim.Sim = null;
    defer if (sim) |*sm| sm.deinit();
    const source = openSource(init, args, &board, &sim) catch |e| switch (e) {
        error.BoardOpenFailed => return 1,
        else => return e,
    };

    const layout = source.layout();
    logLayout(layout);
    const nch = layout.numChannels();

    const bs = args.settings.block_samples;
    // The ring absorbs consumer stalls: 30 s when recording (disk), else 2 s.
    const ring_s: f64 = if (args.record_root != null) 30.0 else 2.0;
    const slots: usize = @intFromFloat(@ceil(ring_s * layout.sample_rate / @as(f64, @floatFromInt(bs))));
    var ring = try dimna.ring.BlockRing.init(gpa, slots, nch, bs);
    defer ring.deinit(gpa);
    const me = ring.addConsumer().?;
    var rec: ?*dimna.record.Recorder = null;
    if (args.record_root) |root| {
        rec = createRecorder(gpa, io, &ring, root, layout, source, if (board) |*b| b else null) catch return 1;
    }
    var health: dimna.types.Health = .{};
    var acq: dimna.acquisition.Acquisition = .{
        .io = io,
        .source = source,
        .ring = &ring,
        .health = &health,
        .scratch = try .init(gpa, nch, bs),
    };
    defer acq.scratch.deinit(gpa);

    std.posix.sigaction(.INT, &.{ .handler = .{ .handler = onSigint }, .mask = std.posix.sigemptyset(), .flags = 0 }, null);

    if (rec) |r| {
        r.events_in = &acq.events;
        try r.start();
    }
    var live: LiveTest = .{};
    var soak: Soak = .{
        .io = io,
        .ring = &ring,
        .me = me,
        .health = &health,
        .acq = &acq,
        .rec = rec,
        .timing = .{ .period_ns = 1e9 / layout.sample_rate },
    };
    try acq.start();
    const run_ms = soak.run(args, &live);
    if (args.live_test) live.finish(&acq, io);
    const failed = acq.done.load(.acquire);
    acq.join();
    soak.drain();

    const rec_ok = if (rec) |r| try finishRecording(gpa, r, soak.cont.consumed_samples) else true;
    return summarize(&soak, layout, run_ms, failed, live.ok, rec_ok);
}

/// Opens the simulator (`--sim`) or the board, applies the settings, and returns the source,
/// which points into `board` or `sim`. error.BoardOpenFailed has been logged already.
fn openSource(init: std.process.Init, args: Args, board: *?Board, sim: *?dimna.sim.Sim) !dimna.source.Source {
    const io = init.io;
    if (args.num_sim > 0) {
        sim.* = try dimna.sim.Sim.init(init.gpa, io, args.sim[0..args.num_sim]);
        try sim.*.?.applySettings(args.settings);
        log.info("simulated board: {d} headstages, {d} units", .{ args.num_sim, sim.*.?.units.len });
        return .{ .sim = &sim.*.? };
    }
    var dirbuf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (args.driver == .d3xx) {
        if (dimna.oni.configureDriverSearch(io, init.environ_map, &dirbuf)) |d| {
            log.info("using libonidriver_ft600.so from {s}", .{d});
        } else log.info("libonidriver_ft600.so not found in known locations; trying the default library path", .{});
    }
    if (!dimna.acquisition.lockMemory()) log.warn("mlockall failed; pages may be swapped out", .{});
    board.* = Board.open(io, args.driver) catch |e| {
        log.err("could not open the board: {t} (liboni: {s})", .{ e, dimna.oni.errorStr(dimna.oni.lastError()) });
        return error.BoardOpenFailed;
    };
    try board.*.?.applySettings(args.settings);
    return .{ .board = &board.*.? };
}

fn logLayout(layout: dimna.types.Layout) void {
    for (layout.headstageSlice()) |h| {
        log.info("headstage {s}: {s}, {d} ch from channel {d}", .{
            dimna.types.headstage_names[h.slot],
            h.chip,
            h.num_channels,
            h.first_channel,
        });
    }
    log.info(
        "{d} channels ({d} electrode, {d} aux, {d} adc) at {d} Hz, board clock {d} Hz",
        .{ layout.numChannels(), layout.num_electrodes, layout.num_aux, layout.num_adc, layout.sample_rate, layout.hw_clock_hz },
    );
}

/// Creates the recording under `root` (not started). Logs the reason if it cannot.
fn createRecorder(
    gpa: std.mem.Allocator,
    io: Io,
    ring: *dimna.ring.BlockRing,
    root: []const u8,
    layout: dimna.types.Layout,
    source: dimna.source.Source,
    board: ?*const Board,
) !*dimna.record.Recorder {
    return dimna.record.Recorder.create(gpa, io, ring, root, .{
        .layout = layout,
        .settings = source.settings(),
        .gateware = if (board) |b| b.fw else @splat(0),
        .board_id = if (board) |b| b.device_id else 0,
        .cable_delay = if (board) |b| b.cable_delay else @splat(0),
        .board_kind = if (board != null) "Open Ephys acquisition board (ECP5, FT600, ONI)" else "simulated",
    }) catch |e| {
        log.err("could not create the recording under '{s}': {t}", .{ root, e });
        return e;
    };
}

/// --live-test: settings changes on a schedule while acquiring.
const LiveTest = struct {
    next_step: usize = 0,
    ok: bool = true,

    const Step = struct { at_ms: i64, name: []const u8, edit: *const fn (*dimna.types.Settings) void };
    const steps = [_]Step{
        .{ .at_ms = 2000, .name = "ADC off (a restart change)", .edit = struct {
            fn f(st: *dimna.types.Settings) void {
                st.acquire_adc = !st.acquire_adc;
            }
        }.f },
        .{ .at_ms = 4000, .name = "LEDs on", .edit = struct {
            fn f(st: *dimna.types.Settings) void {
                st.leds = true;
            }
        }.f },
        .{ .at_ms = 6000, .name = "LEDs off", .edit = struct {
            fn f(st: *dimna.types.Settings) void {
                st.leds = false;
            }
        }.f },
        .{ .at_ms = 8000, .name = "lower bandwidth 300 Hz", .edit = struct {
            fn f(st: *dimna.types.Settings) void {
                st.lower_bandwidth = 300.0;
            }
        }.f },
        .{ .at_ms = 14000, .name = "lower bandwidth 1 Hz", .edit = struct {
            fn f(st: *dimna.types.Settings) void {
                st.lower_bandwidth = 1.0;
            }
        }.f },
        .{ .at_ms = 18000, .name = "upper bandwidth 1 kHz", .edit = struct {
            fn f(st: *dimna.types.Settings) void {
                st.upper_bandwidth = 1000.0;
            }
        }.f },
        .{ .at_ms = 22000, .name = "upper bandwidth 7.5 kHz", .edit = struct {
            fn f(st: *dimna.types.Settings) void {
                st.upper_bandwidth = 7500.0;
            }
        }.f },
    };

    /// Runs the next step if its time has come.
    fn poll(self: *LiveTest, acq: *dimna.acquisition.Acquisition, elapsed_ms: i64, recording: bool) void {
        if (self.next_step >= steps.len or elapsed_ms < steps[self.next_step].at_ms) return;
        const step = steps[self.next_step];
        self.next_step += 1;
        var want = acq.requested;
        step.edit(&want);
        if (acq.applySettings(want, recording)) |change| {
            log.info("live test: {s}: queued ({t})", .{ step.name, change });
            if (std.mem.indexOf(u8, step.name, "restart") != null and recording) {
                log.err("live test: a restart change was accepted while recording", .{});
                self.ok = false;
            }
        } else |e| {
            const expected = e == error.RecordingActive and std.mem.indexOf(u8, step.name, "restart") != null;
            if (expected) log.info("live test: {s}: refused while recording, as it should be", .{step.name}) else {
                log.err("live test: {s}: {t}", .{ step.name, e });
                self.ok = false;
            }
        }
    }

    /// Waits for the queued changes to be applied and prints the result.
    fn finish(self: *LiveTest, acq: *dimna.acquisition.Acquisition, io: Io) void {
        while (!acq.idle() and !acq.done.load(.acquire)) io.sleep(.fromMilliseconds(5), .awake) catch {};
        std.debug.print(
            "live test: {d} steps run, {d} commands applied, {d} failed, longest apply {d} us\n",
            .{ self.next_step, acq.applied.load(.acquire), acq.failed.load(.acquire), acq.max_apply_us.load(.monotonic) },
        );
        if (self.next_step < steps.len or acq.failed.load(.acquire) != 0) self.ok = false;
    }
};

/// The consumer's check of the stream: blocks contiguous, board clock advancing.
const Continuity = struct {
    expect_next: ?i64 = null,
    gap_blocks: u64 = 0,
    blocks: u64 = 0,
    consumed_samples: u64 = 0,
    tstep_min: u64 = std.math.maxInt(u64),
    tstep_max: u64 = 0,
    last_hw: ?u64 = null,

    fn countBlock(self: *Continuity, b: *const dimna.types.Block) void {
        if (self.expect_next) |e| {
            if (b.first_sample != e) self.gap_blocks += 1;
        }
        self.expect_next = b.first_sample + @as(i64, @intCast(b.len));
        self.consumed_samples += b.len;
        self.blocks += 1;
    }

    fn checkClock(self: *Continuity, b: *const dimna.types.Block) void {
        for (b.hw_time[0..b.len]) |t| {
            if (self.last_hw) |l| {
                const d = t -% l;
                self.tstep_min = @min(self.tstep_min, d);
                self.tstep_max = @max(self.tstep_max, d);
            }
            self.last_hw = t;
        }
    }

    fn tstepLow(self: *const Continuity) u64 {
        return if (self.tstep_max == 0) 0 else self.tstep_min;
    }
};

/// Latency to this consumer (per second) and delivery delay (per second and over the run).
const Timing = struct {
    lat_sum_ns: i128 = 0,
    lat_n: u64 = 0,
    lat_max_ns: i96 = 0,
    // Delivery delay of each block's newest sample, relative to the quickest delivery in the
    // same second (host time minus sample time has an unknown, slowly drifting offset).
    period_ns: f64,
    age_min: f64 = std.math.inf(f64),
    age_max: f64 = -std.math.inf(f64),
    age_sum: f64 = 0,
    age_n: f64 = 0,
    delay_avg_sum: f64 = 0,
    delay_max: f64 = 0,
    delay_ticks: f64 = 0,

    fn add(self: *Timing, b: *const dimna.types.Block, now: i96) void {
        const lat = now - b.acquired_ns;
        self.lat_sum_ns += lat;
        self.lat_n += 1;
        self.lat_max_ns = @max(self.lat_max_ns, lat);
        if (b.len > 0) {
            const age = @as(f64, @floatFromInt(b.acquired_ns)) -
                @as(f64, @floatFromInt(b.first_sample + @as(i64, @intCast(b.len)) - 1)) * self.period_ns;
            self.age_min = @min(self.age_min, age);
            self.age_max = @max(self.age_max, age);
            self.age_sum += age;
            self.age_n += 1;
        }
    }
};

/// The acquisition loop: reads the ring as a consumer, prints one line per second.
const Soak = struct {
    io: Io,
    ring: *dimna.ring.BlockRing,
    me: usize,
    health: *dimna.types.Health,
    acq: *dimna.acquisition.Acquisition,
    rec: ?*dimna.record.Recorder,
    cont: Continuity = .{},
    timing: Timing,
    next_tick: i64 = 1,
    last_samples: u64 = 0,
    ring_peak: usize = 0,

    /// Runs until --seconds, Ctrl-C or the acquisition thread ending; returns the run time in ms.
    fn run(self: *Soak, args: Args, live: *LiveTest) i64 {
        const io = self.io;
        const t_start = Io.Clock.awake.now(io);
        var run_ms: i64 = 0;
        while (!interrupted.load(.acquire) and !self.acq.done.load(.acquire)) {
            self.readAll();
            const elapsed_ms = t_start.untilNow(io, .awake).toMilliseconds();
            if (args.live_test) live.poll(self.acq, elapsed_ms, self.rec != null);
            if (elapsed_ms >= self.next_tick * 1000) self.second();
            if (@as(f64, @floatFromInt(elapsed_ms)) >= args.seconds * 1000.0) {
                run_ms = elapsed_ms;
                break;
            }
            io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        if (run_ms == 0) run_ms = t_start.untilNow(io, .awake).toMilliseconds();
        return run_ms;
    }

    fn readAll(self: *Soak) void {
        self.ring_peak = @max(self.ring_peak, self.ring.backlog(self.me));
        while (self.ring.readSlot(self.me)) |b| {
            const now = Io.Clock.awake.now(self.io).nanoseconds;
            self.timing.add(b, now);
            self.cont.countBlock(b);
            self.cont.checkClock(b);
            self.ring.release(self.me);
        }
    }

    /// The once-a-second status lines.
    fn second(self: *Soak) void {
        const health = self.health;
        const t = &self.timing;
        const s = health.samples.load(.monotonic);
        const lat_avg_ms: f64 = if (t.lat_n > 0) @as(f64, @floatFromInt(t.lat_sum_ns)) / @as(f64, @floatFromInt(t.lat_n)) / 1e6 else 0;
        if (self.rec) |r| std.debug.print(
            "  rec: {d} samples, backlog {d} blocks, max write {d} us, max sync {d} us{s}\n",
            .{
                r.stats.samples.load(.monotonic),
                r.backlog(),
                r.stats.max_write_us.load(.monotonic),
                r.stats.max_sync_us.load(.monotonic),
                if (r.done.load(.acquire)) " FAILED" else "",
            },
        );
        const d_avg = if (t.age_n > 0) (t.age_sum / t.age_n - t.age_min) / 1e6 else 0;
        const d_max = if (t.age_n > 0) (t.age_max - t.age_min) / 1e6 else 0;
        if (t.age_n > 0 and self.next_tick > 1) {
            t.delay_avg_sum += d_avg;
            t.delay_max = @max(t.delay_max, d_max);
            t.delay_ticks += 1;
        }
        t.age_min = std.math.inf(f64);
        t.age_max = -std.math.inf(f64);
        t.age_sum = 0;
        t.age_n = 0;
        std.debug.print("t={d:>4}s samples={d} (+{d}) dropped={d} gaps={d} bad={d} rderr={d} hwbuf={d:.1}% (peak {d:.1}) ring={d}/{d} overflow={d} gapblk={d} tstep={d}..{d} lat avg {d:.2} max {d:.2} ms, delivery +{d:.2} avg +{d:.2} max ms\n", .{
            @as(u64, @intCast(self.next_tick)),                    s,
            s - self.last_samples,                                 health.dropped_samples.load(.monotonic),
            health.discontinuities.load(.monotonic),               health.bad_frames.load(.monotonic),
            health.read_errors.load(.monotonic),                   pct(health.hw_buffer_milli_pct.load(.monotonic)),
            pct(health.hw_buffer_peak_milli_pct.load(.monotonic)), self.ring_peak,
            self.ring.capacity(),                                  self.acq.ring_overflow.load(.monotonic),
            self.cont.gap_blocks,                                  self.cont.tstepLow(),
            self.cont.tstep_max,                                   lat_avg_ms,
            @as(f64, @floatFromInt(t.lat_max_ns)) / 1e6,           d_avg,
            d_max,
        });
        self.last_samples = s;
        self.ring_peak = 0;
        t.lat_sum_ns = 0;
        t.lat_n = 0;
        t.lat_max_ns = 0;
        self.next_tick += 1;
    }

    /// Drains what the thread committed before it stopped.
    fn drain(self: *Soak) void {
        while (self.ring.readSlot(self.me)) |b| {
            self.cont.countBlock(b);
            self.ring.release(self.me);
        }
    }
};

/// Closes the recording and checks it holds every sample the consumer saw.
fn finishRecording(gpa: std.mem.Allocator, r: *dimna.record.Recorder, consumed_samples: u64) !bool {
    var ok = true;
    const path = try gpa.dupe(u8, r.path);
    defer gpa.free(path);
    const sum = r.finish();
    if (sum.failure) |e| {
        log.err("recording failed: {t}", .{e});
        ok = false;
    }
    if (sum.samples != consumed_samples) {
        log.err("recorder wrote {d} samples but {d} were acquired", .{ sum.samples, consumed_samples });
        ok = false;
    }
    std.debug.print(
        "recording: {s}\n  {d} samples, {d} chunks, {d} gaps, {d} TTL edges, max write {d} us, max sync {d} us\n",
        .{ path, sum.samples, sum.chunks, sum.gaps, sum.ttl_edges, sum.max_write_us, sum.max_sync_us },
    );
    return ok;
}

/// Prints the summary and returns the exit status: 1 if anything was lost or failed.
fn summarize(soak: *const Soak, layout: dimna.types.Layout, run_ms: i64, failed: bool, live_ok: bool, rec_ok: bool) u8 {
    const health = soak.health;
    const acq = soak.acq;
    const cont = &soak.cont;
    const dropped = health.dropped_samples.load(.monotonic);
    const gaps = health.discontinuities.load(.monotonic);
    const bad = health.bad_frames.load(.monotonic);
    const overflow = acq.ring_overflow.load(.monotonic);
    // Rate over the acquisition window (the drain after stopping adds at most a few blocks).
    const secs = @as(f64, @floatFromInt(run_ms)) / 1000.0;
    std.debug.print("\nsummary: {d:.1} s, {d} samples in {d} blocks ({d:.1} samples/s), dropped={d} gaps={d} bad={d} overflow={d} gapblk={d} tstep={d}..{d}, realtime={}, hwbuf peak {d:.1}%\n", .{
        secs,                                                  cont.consumed_samples,
        cont.blocks,                                           @as(f64, @floatFromInt(cont.consumed_samples)) / secs,
        dropped,                                               gaps,
        bad,                                                   overflow,
        cont.gap_blocks,                                       cont.tstepLow(),
        cont.tstep_max,                                        acq.realtime.load(.acquire),
        pct(health.hw_buffer_peak_milli_pct.load(.monotonic)),
    });
    const t = &soak.timing;
    if (t.delay_ticks > 0) std.debug.print(
        "delivery delay of a block's newest sample, beyond the quickest in each second: avg {d:.2} ms, worst {d:.2} ms\n",
        .{ t.delay_avg_sum / t.delay_ticks, t.delay_max },
    );
    if (failed) {
        log.err("acquisition thread ended early: {t}", .{acq.failure orelse error.Unknown});
        return 1;
    }
    const nominal = layout.hw_clock_hz / layout.sample_rate;
    const tstep_ok = cont.tstep_max == 0 or (@as(f64, @floatFromInt(cont.tstep_min)) > 0.5 * nominal and
        @as(f64, @floatFromInt(cont.tstep_max)) < 1.5 * nominal);
    const clean = live_ok and rec_ok and dropped == 0 and gaps == 0 and bad == 0 and overflow == 0 and cont.gap_blocks == 0 and tstep_ok;
    std.debug.print("{s}\n", .{if (clean) "CLEAN" else "PROBLEMS (see counters above)"});
    return if (clean) 0 else 1;
}

fn pct(milli: u64) f64 {
    return @as(f64, @floatFromInt(milli)) / 1000.0;
}
