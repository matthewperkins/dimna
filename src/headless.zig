//! oez-headless: open the board, acquire for a while, and check the stream.
//!
//!   oez-headless [--seconds S] [--16ch A1,B1] [--aux] [--adc] [--leds] [--rate HZ] [--block N]
//!                [--record ROOT]
//!
//! Prints one status line per second. Besides the driver's own counters it checks, as a
//! consumer, that blocks arrive contiguous (`gapblk`) and that the board clock advances by
//! about one sample period every sample (`tstep`, in board-clock ticks: 1666.7 at 30 kHz and
//! 50 MHz; it jitters by about ±10 ticks, and a lost sample would show as ~2×). Exit status 1
//! if anything was lost.

const std = @import("std");
const oez = @import("oez");
const Board = oez.board.Board;
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
    settings: oez.types.Settings = .{},
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
        } else if (std.mem.eql(u8, arg, "--block")) {
            a.settings.block_samples = try std.fmt.parseInt(usize, try next(args, &i, arg), 10);
        } else if (std.mem.eql(u8, arg, "--record")) {
            a.record_root = try next(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--aux")) {
            a.settings.acquire_aux = true;
        } else if (std.mem.eql(u8, arg, "--adc")) {
            a.settings.acquire_adc = true;
        } else if (std.mem.eql(u8, arg, "--leds")) {
            a.settings.leds = true;
        } else if (std.mem.eql(u8, arg, "--16ch")) {
            var it = std.mem.tokenizeScalar(u8, try next(args, &i, arg), ',');
            while (it.next()) |name| {
                const slot = for (oez.types.headstage_names, 0..) |n, k| {
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

    var dirbuf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (oez.oni.configureDriverSearch(io, init.environ_map, &dirbuf)) |d| {
        log.info("using libonidriver_ft600.so from {s}", .{d});
    } else log.info("libonidriver_ft600.so not found in known locations; trying the default library path", .{});

    if (!oez.acquisition.lockMemory()) log.warn("mlockall failed; pages may be swapped out", .{});

    var board = Board.open(io) catch |e| {
        log.err("could not open the board: {t} (liboni: {s})", .{ e, oez.oni.errorStr(oez.oni.lastError()) });
        return 1;
    };
    defer board.close();
    try board.applySettings(args.settings);

    const layout = board.layout();
    for (layout.headstageSlice()) |h| {
        log.info("headstage {s}: {s}, {d} ch from channel {d}", .{ oez.types.headstage_names[h.slot], h.chip, h.num_channels, h.first_channel });
    }
    const nch = layout.numChannels();
    log.info("{d} channels ({d} electrode, {d} aux, {d} adc) at {d} Hz, board clock {d} Hz", .{ nch, layout.num_electrodes, layout.num_aux, layout.num_adc, layout.sample_rate, layout.hw_clock_hz });

    const bs = args.settings.block_samples;
    // The ring absorbs consumer stalls: 30 s when recording (disk), else 2 s.
    const ring_s: f64 = if (args.record_root != null) 30.0 else 2.0;
    const slots: usize = @intFromFloat(@ceil(ring_s * layout.sample_rate / @as(f64, @floatFromInt(bs))));
    var ring = try oez.ring.BlockRing.init(gpa, slots, nch, bs);
    defer ring.deinit(gpa);
    const me = ring.addConsumer();
    var rec: ?*oez.record.Recorder = null;
    if (args.record_root) |root| {
        rec = oez.record.Recorder.create(gpa, io, &ring, root, .{
            .layout = layout,
            .settings = board.settings,
            .gateware = board.fw,
            .board_id = board.device_id,
            .cable_delay = board.cable_delay,
        }) catch |e| {
            log.err("could not create the recording under '{s}': {t}", .{ root, e });
            return 1;
        };
    }
    var health: oez.types.Health = .{};
    var acq: oez.acquisition.Acquisition = .{ .io = io, .board = &board, .ring = &ring, .health = &health, .scratch = try .init(gpa, nch, bs) };
    defer acq.scratch.deinit(gpa);

    std.posix.sigaction(.INT, &.{ .handler = .{ .handler = onSigint }, .mask = std.posix.sigemptyset(), .flags = 0 }, null);

    if (rec) |r| try r.start();
    try acq.start();
    const t_start = Io.Clock.awake.now(io);
    var next_tick: i64 = 1;
    var expect_next: ?i64 = null;
    var gap_blocks: u64 = 0;
    var blocks: u64 = 0;
    var consumed_samples: u64 = 0;
    var lat_sum_ns: i128 = 0;
    var lat_n: u64 = 0;
    var lat_max_ns: i96 = 0;
    var tstep_min: u64 = std.math.maxInt(u64);
    var tstep_max: u64 = 0;
    var last_hw: ?u64 = null;
    var last_samples: u64 = 0;
    var ring_peak: usize = 0;
    var run_ms: i64 = 0;

    while (!interrupted.load(.acquire) and !acq.done.load(.acquire)) {
        ring_peak = @max(ring_peak, ring.backlog(me));
        while (ring.readSlot(me)) |b| {
            const now = Io.Clock.awake.now(io).nanoseconds;
            const lat = now - b.acquired_ns;
            lat_sum_ns += lat;
            lat_n += 1;
            lat_max_ns = @max(lat_max_ns, lat);
            if (expect_next) |e| {
                if (b.first_sample != e) gap_blocks += 1;
            }
            expect_next = b.first_sample + @as(i64, @intCast(b.len));
            for (b.hw_time[0..b.len]) |t| {
                if (last_hw) |l| {
                    const d = t -% l;
                    tstep_min = @min(tstep_min, d);
                    tstep_max = @max(tstep_max, d);
                }
                last_hw = t;
            }
            consumed_samples += b.len;
            blocks += 1;
            ring.release(me);
        }
        const elapsed_ms = t_start.untilNow(io, .awake).toMilliseconds();
        if (elapsed_ms >= next_tick * 1000) {
            const s = health.samples.load(.monotonic);
            const lat_avg_ms: f64 = if (lat_n > 0) @as(f64, @floatFromInt(lat_sum_ns)) / @as(f64, @floatFromInt(lat_n)) / 1e6 else 0;
            if (rec) |r| std.debug.print("  rec: {d} samples, backlog {d} blocks, max write {d} us, max sync {d} us{s}\n", .{ r.stats.samples.load(.monotonic), r.backlog(), r.stats.max_write_us.load(.monotonic), r.stats.max_sync_us.load(.monotonic), if (r.done.load(.acquire)) " FAILED" else "" });
            std.debug.print("t={d:>4}s samples={d} (+{d}) dropped={d} gaps={d} bad={d} rderr={d} hwbuf={d:.1}% (peak {d:.1}) ring={d}/{d} overflow={d} gapblk={d} tstep={d}..{d} lat avg {d:.2} max {d:.2} ms\n", .{
                @as(u64, @intCast(next_tick)),                                                             s,                                       s - last_samples,
                health.dropped_samples.load(.monotonic),                               health.discontinuities.load(.monotonic), health.bad_frames.load(.monotonic),
                health.read_errors.load(.monotonic),                                   pct(health.hw_buffer_milli_pct.load(.monotonic)), pct(health.hw_buffer_peak_milli_pct.load(.monotonic)),
                ring_peak,                                                             ring.capacity(),                         acq.ring_overflow.load(.monotonic),
                gap_blocks,                                                            if (tstep_max == 0) 0 else tstep_min,    tstep_max,
                lat_avg_ms,                                                            @as(f64, @floatFromInt(lat_max_ns)) / 1e6,
            });
            last_samples = s;
            ring_peak = 0;
            lat_sum_ns = 0;
            lat_n = 0;
            lat_max_ns = 0;
            next_tick += 1;
        }
        if (@as(f64, @floatFromInt(elapsed_ms)) >= args.seconds * 1000.0) {
            run_ms = elapsed_ms;
            break;
        }
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    if (run_ms == 0) run_ms = t_start.untilNow(io, .awake).toMilliseconds();
    const failed = acq.done.load(.acquire);
    acq.join();
    // Drain what the thread committed before it stopped.
    while (ring.readSlot(me)) |b| {
        if (expect_next) |e| {
            if (b.first_sample != e) gap_blocks += 1;
        }
        expect_next = b.first_sample + @as(i64, @intCast(b.len));
        consumed_samples += b.len;
        blocks += 1;
        ring.release(me);
    }

    var rec_ok = true;
    if (rec) |r| {
        const path = try gpa.dupe(u8, r.path);
        defer gpa.free(path);
        const sum = r.finish();
        if (sum.failure) |e| {
            log.err("recording failed: {t}", .{e});
            rec_ok = false;
        }
        if (sum.samples != consumed_samples) {
            log.err("recorder wrote {d} samples but {d} were acquired", .{ sum.samples, consumed_samples });
            rec_ok = false;
        }
        std.debug.print("recording: {s}\n  {d} samples, {d} chunks, {d} gaps, {d} TTL edges, max write {d} us, max sync {d} us\n", .{ path, sum.samples, sum.chunks, sum.gaps, sum.ttl_edges, sum.max_write_us, sum.max_sync_us });
    }
    const dropped = health.dropped_samples.load(.monotonic);
    const gaps = health.discontinuities.load(.monotonic);
    const bad = health.bad_frames.load(.monotonic);
    const overflow = acq.ring_overflow.load(.monotonic);
    // Rate over the acquisition window (the drain after stopping adds at most a few blocks).
    const secs = @as(f64, @floatFromInt(run_ms)) / 1000.0;
    std.debug.print("\nsummary: {d:.1} s, {d} samples in {d} blocks ({d:.1} samples/s), dropped={d} gaps={d} bad={d} overflow={d} gapblk={d} tstep={d}..{d}, realtime={}, hwbuf peak {d:.1}%\n", .{
        secs,     consumed_samples, blocks,     @as(f64, @floatFromInt(consumed_samples)) / secs, dropped,                                              gaps, bad, overflow,
        gap_blocks, if (tstep_max == 0) 0 else tstep_min, tstep_max, acq.realtime.load(.acquire), pct(health.hw_buffer_peak_milli_pct.load(.monotonic)),
    });
    if (failed) {
        log.err("acquisition thread ended early: {t}", .{acq.failure orelse error.Unknown});
        return 1;
    }
    const nominal = layout.hw_clock_hz / layout.sample_rate;
    const tstep_ok = tstep_max == 0 or (@as(f64, @floatFromInt(tstep_min)) > 0.5 * nominal and @as(f64, @floatFromInt(tstep_max)) < 1.5 * nominal);
    const clean = rec_ok and dropped == 0 and gaps == 0 and bad == 0 and overflow == 0 and gap_blocks == 0 and tstep_ok;
    std.debug.print("{s}\n", .{if (clean) "CLEAN" else "PROBLEMS (see counters above)"});
    return if (clean) 0 else 1;
}

fn pct(milli: u64) f64 {
    return @as(f64, @floatFromInt(milli)) / 1000.0;
}
