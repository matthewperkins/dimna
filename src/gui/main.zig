//! oez: the GUI. One window of live traces for now.
//!
//!   oez [--sim 32,16] [--16ch A1,B1] [--aux] [--adc] [--driver usb|d3xx] [--seconds S]
//!       [--present auto|mailbox|immediate|fifo] [--late-ms MS]
//!
//! Without --sim it opens the board. Controls:
//!   wheel / two-finger scroll      Y scale (µV per row)
//!   Shift+wheel, sideways scroll   time base
//!   touchpad pinch                 time base
//!   - =   [ ]                      Y scale, time base by keys;  r resets;  q or Esc quits
//!
//! The display reads the acquisition ring with a lossy reader, so it can never hold
//! acquisition back. Once a second it logs the frame rate and the sample-to-screen latency:
//! the time from a sample's block reaching the ring to the frame showing it being presented
//! (from Wayland presentation feedback).

const std = @import("std");
const oez = @import("oez");
const Window = @import("window.zig").Window;
const gpu_mod = @import("gpu.zig");
const Gpu = gpu_mod.Gpu;
const Io = std.Io;
const log = std.log.scoped(.oez);

pub const std_options: std.Options = .{ .log_level = .info };

const Args = struct {
    seconds: f64 = 0,
    settings: oez.types.Settings = .{},
    driver: oez.board.Driver = .usb,
    sim: [8]usize = @splat(0),
    num_sim: usize = 0,
    present: gpu_mod.PresentMode = .auto,
    late_ms: f64 = 0,
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
        } else if (std.mem.eql(u8, arg, "--late-ms")) {
            a.late_ms = try std.fmt.parseFloat(f64, try next(args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--aux")) {
            a.settings.acquire_aux = true;
        } else if (std.mem.eql(u8, arg, "--adc")) {
            a.settings.acquire_adc = true;
        } else if (std.mem.eql(u8, arg, "--driver")) {
            const name = try next(args, &i, arg);
            a.driver = std.meta.stringToEnum(oez.board.Driver, name) orelse {
                log.err("--driver: '{s}' is not usb or d3xx", .{name});
                return error.BadArgs;
            };
        } else if (std.mem.eql(u8, arg, "--present")) {
            const name = try next(args, &i, arg);
            a.present = std.meta.stringToEnum(gpu_mod.PresentMode, name) orelse {
                log.err("--present: '{s}' is not auto, mailbox, immediate or fifo", .{name});
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

/// The trace view: what the controls change.
const View = struct {
    span_s: f64 = 2.0,
    uv_per_row: f64 = 400.0,

    const span_min = 0.05;
    const span_max = 20.0;
    const uv_min = 5.0;
    const uv_max = 20000.0;

    fn apply(self: *View, in: @import("window.zig").Input) bool {
        // One wheel click (about 15 units) changes a scale by 15 %.
        const per_unit = 0.0093;
        var sx = in.scroll_x;
        var sy = in.scroll_y;
        if (in.shift) {
            sx += sy;
            sy = 0;
        }
        if (sy != 0) self.uv_per_row *= @exp(sy * per_unit);
        if (sx != 0) self.span_s *= @exp(sx * per_unit);
        // Fingers apart = zoom in = less time across the window.
        if (in.pinch != 1 and in.pinch > 0) self.span_s /= in.pinch;
        var quit = false;
        for (in.keys[0..in.num_keys]) |k| switch (k) {
            .escape, .q => quit = true,
            .minus => self.uv_per_row *= 1.25,
            .equal => self.uv_per_row /= 1.25,
            .left_bracket => self.span_s *= 1.25,
            .right_bracket => self.span_s /= 1.25,
            .r => self.* = .{},
            else => {},
        };
        self.span_s = std.math.clamp(self.span_s, span_min, span_max);
        self.uv_per_row = std.math.clamp(self.uv_per_row, uv_min, uv_max);
        return quit;
    }
};

fn nowNs(io: Io) i128 {
    return Io.Clock.awake.now(io).nanoseconds;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const args = parseArgs(try init.minimal.args.toSlice(init.arena.allocator())) catch return 2;

    // ---- the source: simulator or board ----
    var board: ?oez.board.Board = null;
    defer if (board) |*b| b.close();
    var sim: ?oez.sim.Sim = null;
    defer if (sim) |*sm| sm.deinit();
    const source: oez.source.Source = if (args.num_sim > 0) blk: {
        sim = try oez.sim.Sim.init(gpa, io, args.sim[0..args.num_sim]);
        try sim.?.applySettings(args.settings);
        log.info("simulated board: {d} headstages, {d} units", .{ args.num_sim, sim.?.units.len });
        break :blk .{ .sim = &sim.? };
    } else blk: {
        var dirbuf: [std.fs.max_path_bytes:0]u8 = undefined;
        if (args.driver == .d3xx) _ = oez.oni.configureDriverSearch(io, init.environ_map, &dirbuf);
        if (!oez.acquisition.lockMemory()) log.warn("mlockall failed; pages may be swapped out", .{});
        board = oez.board.Board.open(io, args.driver) catch |e| {
            log.err("could not open the board: {t} (liboni: {s})", .{ e, oez.oni.errorStr(oez.oni.lastError()) });
            return 1;
        };
        try board.?.applySettings(args.settings);
        break :blk .{ .board = &board.? };
    };
    const layout = source.layout();
    const nch = layout.numChannels();
    const fs = layout.sample_rate;
    const bs = source.settings().block_samples;
    log.info("{d} channels ({d} electrode) at {d} Hz", .{ nch, layout.num_electrodes, fs });

    // ---- acquisition into the ring ----
    const slots: usize = @intFromFloat(@ceil(2.0 * fs / @as(f64, @floatFromInt(bs))));
    var ring = try oez.ring.BlockRing.init(gpa, slots, nch, bs);
    defer ring.deinit(gpa);
    var health: oez.types.Health = .{};
    var acq: oez.acquisition.Acquisition = .{ .io = io, .source = source, .ring = &ring, .health = &health, .scratch = try .init(gpa, nch, bs) };
    defer acq.scratch.deinit(gpa);
    var reader = oez.ring.LossyReader.init(&ring);
    var blk = try oez.types.Block.init(gpa, nch, bs);
    defer blk.deinit(gpa);

    // ---- window and renderer ----
    var win: Window = undefined;
    try win.init("oEZ");
    defer win.deinit();
    var gpu = try Gpu.init(gpa, win.display, win.surface, args.present);
    defer gpu.deinit();
    // The longest time base plus a margin, so new samples never overwrite what is drawn.
    try gpu.createHistory(nch, @intFromFloat((View.span_max + 2.0) * fs));
    if (win.presentation_clock != 1 and win.presentation != null) log.warn("presentation clock is {d}, not CLOCK_MONOTONIC: latency figures will be off", .{win.presentation_clock});

    try acq.start();
    defer acq.join();

    var view: View = .{};
    var newest: i64 = 0;
    var newest_acquired_ns: i128 = 0;
    // Acquisition time of the newest sample drawn in each frame, by frame tag.
    var frame_acquired: [64]i128 = @splat(0);
    var frame_tag: u64 = 0;
    var ready_since: i128 = 0;

    const t_start = nowNs(io);
    var next_report: i128 = t_start + std.time.ns_per_s;
    var frames: u64 = 0;
    var lat_sum: f64 = 0;
    var lat_min: f64 = std.math.inf(f64);
    var lat_max: f64 = 0;
    var lat_n: f64 = 0;
    var refresh_ns: u32 = 0;
    var title_buf: [160]u8 = undefined;

    while (!win.closed and !acq.done.load(.acquire)) {
        try win.pump(if (win.frame_ready) 0 else 2);

        // New samples into the GPU's history.
        while (reader.next(&blk)) {
            if (blk.len == 0) continue;
            gpu.writeSamples(blk.first_sample, blk.samples());
            newest = blk.first_sample + @as(i64, @intCast(blk.len));
            newest_acquired_ns = blk.acquired_ns;
        }

        if (view.apply(win.takeInput())) break;

        for (win.takePresented()) |p| {
            const acquired = frame_acquired[p.tag % frame_acquired.len];
            if (acquired != 0) {
                const ms = @as(f64, @floatFromInt(p.time_ns - acquired)) / 1e6;
                lat_sum += ms;
                lat_min = @min(lat_min, ms);
                lat_max = @max(lat_max, ms);
                lat_n += 1;
            }
            refresh_ns = p.refresh_ns;
        }

        const now = nowNs(io);
        if (win.frame_ready and ready_since == 0) ready_since = now;
        const due = win.frame_ready and @as(f64, @floatFromInt(now - ready_since)) >= args.late_ms * 1e6;
        if (due and newest > 0) {
            if (win.resized or gpu.swapchain == .null) {
                try gpu.resize(win.width, win.height);
                win.resized = false;
            }
            const params: gpu_mod.TraceParams = .{
                .nch = @intCast(nch),
                .cap_mask = @intCast(gpu.hist_cap - 1),
                .newest = @truncate(@as(u64, @bitCast(newest))),
                .first_ch = 0,
                .cols = gpu.extent.width,
                .rows = @intCast(layout.num_electrodes),
                .span = @floatCast(view.span_s * fs),
                .lsb_per_row = @floatCast(view.uv_per_row / oez.types.electrode_uv_per_bit),
                .half_px = 1.5 / @as(f32, @floatFromInt(gpu.extent.height)),
            };
            frame_tag += 1;
            frame_acquired[frame_tag % frame_acquired.len] = newest_acquired_ns;
            const Ctx = struct { win: *Window, tag: u64 };
            const result = try gpu.draw(params, Ctx{ .win = &win, .tag = frame_tag }, struct {
                fn f(c: Ctx) void {
                    c.win.beforePresent(c.tag);
                }
            }.f);
            switch (result) {
                .presented => frames += 1,
                .out_of_date => {
                    win.resized = true;
                    win.frame_ready = true;
                },
            }
            ready_since = 0;
        }

        if (now >= next_report) {
            const secs = @as(f64, @floatFromInt(now - t_start)) / 1e9;
            const avg = if (lat_n > 0) lat_sum / lat_n else 0;
            log.info("t={d:.0}s {d} fps, latency ms avg {d:.1} min {d:.1} max {d:.1} ({d:.0} frames), refresh {d:.2} ms, display lost {d} blocks, ring overflow {d}, span {d:.2} s, {d:.0} uV/row, {d}x{d}", .{
                secs,             frames,                                  avg,           if (lat_n > 0) lat_min else 0, lat_max, lat_n,
                @as(f64, @floatFromInt(refresh_ns)) / 1e6, reader.lost, acq.ring_overflow.load(.monotonic), view.span_s, view.uv_per_row, gpu.extent.width, gpu.extent.height,
            });
            if (std.fmt.bufPrintSentinel(&title_buf, "oEZ   {d:.2} s   {d:.0} uV/row   latency {d:.1} ms   {d} fps", .{ view.span_s, view.uv_per_row, avg, frames }, 0)) |t| win.setTitle(t) else |_| {}
            frames = 0;
            lat_sum = 0;
            lat_min = std.math.inf(f64);
            lat_max = 0;
            lat_n = 0;
            next_report += std.time.ns_per_s;
        }
        if (args.seconds > 0 and @as(f64, @floatFromInt(now - t_start)) >= args.seconds * 1e9) break;
    }
    if (acq.done.load(.acquire)) {
        log.err("acquisition ended early: {t}", .{acq.failure orelse error.Unknown});
        return 1;
    }
    return 0;
}
