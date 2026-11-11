//! oez: the GUI. One window of live traces for now.
//!
//!   oez [--sim 32,16] [--16ch A1,B1] [--aux] [--adc] [--driver usb|d3xx] [--seconds S]
//!       [--present auto|mailbox|immediate|fifo] [--margin-ms MS] [--script STEPS]
//!       [--monitor DP-2] [--tearing] [--free MS]
//!
//! --direct DP-2 drives that monitor itself, with no compositor: frames are flipped by oez at
//!   each refresh. It works only where nothing else drives the monitor: from a text console
//!   (Ctrl+Alt+F3), with a DRM lease, or on a graphics card of its own. There is no window and
//!   no input in this mode yet: it runs for --seconds (default 20) or until Ctrl+C, and
//!   --script changes the view. Margin 1.5 ms unless --margin-ms.
//! --monitor makes the window fullscreen on that monitor (the neural display).
//! --tearing asks the compositor to show frames at once instead of at the refresh (it needs
//!   a fullscreen window and Hyprland's general.allow_tearing); implies --present immediate.
//! --free MS draws whenever new samples have arrived, at most every MS milliseconds, instead
//!   of once per refresh just before it. The way to draw when tearing.
//!
//! --script feeds synthetic input for tests, as "SECONDS:STEP;SECONDS:STEP;...", where STEP is
//! wheel=N, hwheel=N (axis units, 15 = one click), pinch=F (scale factor), or keys such as
//! "]]==" (any of [ ] - = r q). It goes through the same path as real input.
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
//!
//! Frame timing (measured on Hyprland 0.57, NVIDIA, 60 Hz). Each frame is drawn `margin`
//! before the next refresh, predicted from the presentation timestamps:
//!
//!   composited window        the compositor shows, one refresh later, what was committed
//!                            before a refresh: 20.2 ms (32.7 ms if drawn right after the
//!                            frame callback instead)
//!   fullscreen, direct scanout   the buffer goes to the screen at that refresh: 3.5 ms
//!
//! Direct scanout has two stable states. While the output is idle when a commit arrives,
//! Hyprland flips it at once and it is on screen at the refresh aimed at. After a disturbance
//! (a flip still pending when the commit arrives), every commit waits for the previous flip
//! and is shown a refresh later, indefinitely. Leaving one refresh out lets the output go idle
//! again, so (fullscreen only) after 8 frames in a row a refresh late, one frame is skipped;
//! the wait before the next skip doubles each time (250 ms to 8 s) and resets after 2 s of
//! frames on time. The losses that remain come from the compositor's side (unverified guess:
//! it is busy drawing the other monitor when the commit arrives; only owning the display
//! would remove them).
//!
//! The margin is 3 ms. It widens only while frames keep landing late (judged against the
//! best latency of the last seconds, so it works in either regime) and then returns;
//! --margin-ms fixes it. Direct scanout needs Hyprland's render.direct_scanout = 1, or = 2
//! (only surfaces declared as game content, which oez does) and a fullscreen window
//! (--monitor, or `monitor` in the config file). Tearing was tried: Hyprland would not tear
//! here, and free-running (--free) queues frames under direct scanout (33.6 ms).
//!
//! Config file: $XDG_CONFIG_HOME/oez/config.toml (default ~/.config/oez), flat `key = value`
//! lines; command-line options win. Keys: monitor = "DP-2".

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
    /// Fixed margin before the refresh at which to draw; negative = adapt.
    margin_ms: f64 = -1,
    script: []const u8 = "",
    monitor: []const u8 = "",
    /// Connector of a monitor to drive directly, with no compositor.
    direct: []const u8 = "",
    tearing: bool = false,
    /// Free-running: least interval between frames in ms; negative = paced to the refresh.
    free_ms: f64 = -1,
};

const Input = @import("window.zig").Input;

/// Adds the script steps that are due at `elapsed_s` to `in`. `pos` is the script cursor.
fn runScript(script: []const u8, pos: *usize, elapsed_s: f64, in: *Input) void {
    while (pos.* < script.len) {
        const rest = script[pos.*..];
        const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const step = rest[0..end];
        const colon = std.mem.indexOfScalar(u8, step, ':') orelse {
            pos.* += @min(end + 1, rest.len);
            continue;
        };
        const at = std.fmt.parseFloat(f64, step[0..colon]) catch 0;
        if (at > elapsed_s) return;
        const what = step[colon + 1 ..];
        if (std.mem.startsWith(u8, what, "wheel=")) {
            in.scroll_y += std.fmt.parseFloat(f64, what[6..]) catch 0;
        } else if (std.mem.startsWith(u8, what, "hwheel=")) {
            in.scroll_x += std.fmt.parseFloat(f64, what[7..]) catch 0;
        } else if (std.mem.startsWith(u8, what, "pinch=")) {
            in.pinch *= std.fmt.parseFloat(f64, what[6..]) catch 1;
        } else for (what) |ch| {
            if (in.num_keys == in.keys.len) break;
            in.keys[in.num_keys] = switch (ch) {
                '[' => .left_bracket,
                ']' => .right_bracket,
                '-' => .minus,
                '=' => .equal,
                'r' => .r,
                'q' => .q,
                else => continue,
            };
            in.num_keys += 1;
        }
        pos.* += @min(end + 1, rest.len);
    }
}

/// Reads `key = value` lines of the config file into `a` (strings may be quoted; `#` starts a
/// comment; unknown keys are reported). `text` must outlive `a`.
fn applyConfig(a: *Args, text: []const u8) void {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, raw, '#')) |h| raw[0..h] else raw, " \t\r");
        if (line.len == 0 or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
        if (std.mem.eql(u8, key, "monitor")) {
            a.monitor = value;
        } else if (std.mem.eql(u8, key, "margin_ms")) {
            a.margin_ms = std.fmt.parseFloat(f64, value) catch a.margin_ms;
        } else log.warn("config: unknown key '{s}'", .{key});
    }
}

fn parseArgs(args: []const [:0]const u8, config: []const u8) !Args {
    var a: Args = .{};
    applyConfig(&a, config);
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
        } else if (std.mem.eql(u8, arg, "--direct")) {
            a.direct = try next(args, &i, arg);
            if (a.seconds == 0) a.seconds = 20;
        } else if (std.mem.eql(u8, arg, "--monitor")) {
            a.monitor = try next(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--tearing")) {
            a.tearing = true;
            a.present = .immediate;
        } else if (std.mem.eql(u8, arg, "--free")) {
            a.free_ms = try std.fmt.parseFloat(f64, try next(args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--script")) {
            a.script = try next(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--margin-ms")) {
            a.margin_ms = try std.fmt.parseFloat(f64, try next(args, &i, arg));
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

    fn apply(self: *View, in: Input) bool {
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

/// The display loop when oez drives the monitor itself (--direct). One frame is in flight at
/// a time: draw `margin` before a refresh, wait until that frame is on screen, repeat. The
/// time a frame reached the screen comes from vkWaitForPresentKHR.
fn runDirect(io: Io, gpa: std.mem.Allocator, args: Args, layout: oez.types.Layout, acq: *oez.acquisition.Acquisition, reader: *oez.ring.LossyReader, blk: *oez.types.Block) !u8 {
    const nch = layout.numChannels();
    const fs = layout.sample_rate;
    var gpu = Gpu.init(gpa, .{ .direct = args.direct }, .fifo) catch |e| {
        log.err("direct display on {s} failed: {t}", .{ args.direct, e });
        return 1;
    };
    defer gpu.deinit();
    try gpu.createHistory(nch, @intFromFloat((View.span_max + 2.0) * fs));
    try gpu.resize(0, 0);
    const period: i128 = gpu.refresh_period_ns;
    const margin_ms: f64 = if (args.margin_ms >= 0) args.margin_ms else 1.5;
    const margin: i128 = @intFromFloat(margin_ms * 1e6);
    log.info("{d}x{d}, refresh {d:.3} ms, drawing {d:.2} ms before each refresh", .{ gpu.extent.width, gpu.extent.height, @as(f64, @floatFromInt(period)) / 1e6, margin_ms });

    try acq.start();
    defer acq.join();

    var view: View = .{};
    var newest: i64 = 0;
    var newest_acquired_ns: i128 = 0;
    var in_flight: u64 = 0; // present id awaited, 0 = none
    var in_flight_acquired: i128 = 0;
    var in_flight_since: i128 = 0;
    var draw_at: i128 = 0;
    var last_flip: i128 = 0;
    var script_pos: usize = 0;

    const t_start = nowNs(io);
    var next_report: i128 = t_start + std.time.ns_per_s;
    var frames: u64 = 0;
    var lat_sum: f64 = 0;
    var lat_min: f64 = std.math.inf(f64);
    var lat_max: f64 = 0;
    var missed: u64 = 0; // refreshes that passed without a new frame
    var total_frames: u64 = 0;
    var total_missed: u64 = 0;
    var total_lat: f64 = 0;
    var worst: f64 = 0;

    while (!acq.done.load(.acquire)) {
        while (reader.next(blk)) {
            if (blk.len == 0) continue;
            gpu.writeSamples(blk.first_sample, blk.samples());
            newest = blk.first_sample + @as(i64, @intCast(blk.len));
            newest_acquired_ns = blk.acquired_ns;
        }
        var input: Input = .{};
        if (args.script.len > 0) runScript(args.script, &script_pos, @as(f64, @floatFromInt(nowNs(io) - t_start)) / 1e9, &input);
        if (view.apply(input)) break;

        var now = nowNs(io);
        if (in_flight != 0) {
            // Blocks for up to 1 ms, which also paces this loop.
            if (try gpu.waitPresented(in_flight, std.time.ns_per_ms)) {
                now = nowNs(io);
                const ms = @as(f64, @floatFromInt(now - in_flight_acquired)) / 1e6;
                lat_sum += ms;
                lat_min = @min(lat_min, ms);
                lat_max = @max(lat_max, ms);
                frames += 1;
                if (last_flip != 0 and now - last_flip > period + @divTrunc(period, 2)) missed += @intCast(@divTrunc(now - last_flip + @divTrunc(period, 2), period) - 1);
                last_flip = now;
                draw_at = now + period - margin;
                in_flight = 0;
            } else if (now - in_flight_since > 2 * std.time.ns_per_s) {
                log.err("a frame was not shown within 2 s; giving up", .{});
                return 1;
            }
        } else if (newest > 0 and now >= draw_at) {
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
            const result = try gpu.draw(params, {}, struct {
                fn f(_: void) void {}
            }.f);
            switch (result) {
                .presented => {
                    in_flight = gpu.present_id;
                    in_flight_acquired = newest_acquired_ns;
                    in_flight_since = now;
                },
                .out_of_date => try gpu.resize(0, 0),
                .busy => {},
            }
        } else {
            const wait = std.math.clamp(draw_at - now, 0, std.time.ns_per_ms);
            if (wait > 0) io.sleep(.fromNanoseconds(@intCast(wait)), .awake) catch {};
        }

        if (now >= next_report) {
            const secs = @as(f64, @floatFromInt(now - t_start)) / 1e9;
            log.info("t={d:.0}s {d} fps, latency ms avg {d:.2} min {d:.2} max {d:.2}, refreshes without a new frame {d}, display lost {d} blocks, ring overflow {d}", .{
                secs, frames, if (frames > 0) lat_sum / @as(f64, @floatFromInt(frames)) else 0, if (frames > 0) lat_min else 0, lat_max, missed, reader.lost, acq.ring_overflow.load(.monotonic),
            });
            if (secs > 1.5) {
                total_frames += frames;
                total_missed += missed;
                total_lat += lat_sum;
                worst = @max(worst, lat_max);
            }
            frames = 0;
            lat_sum = 0;
            lat_min = std.math.inf(f64);
            lat_max = 0;
            missed = 0;
            next_report += std.time.ns_per_s;
        }
        if (args.seconds > 0 and @as(f64, @floatFromInt(now - t_start)) >= args.seconds * 1e9) break;
    }
    if (total_frames > 0) log.info("direct on {s}, margin {d:.2} ms: {d} frames, latency avg {d:.2} ms, worst {d:.2} ms, refreshes without a new frame {d}", .{ args.direct, margin_ms, total_frames, total_lat / @as(f64, @floatFromInt(total_frames)), worst, total_missed });
    if (acq.done.load(.acquire)) {
        log.err("acquisition ended early: {t}", .{acq.failure orelse error.Unknown});
        return 1;
    }
    return 0;
}

fn nowNs(io: Io) i128 {
    return Io.Clock.awake.now(io).nanoseconds;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len == 2 and std.mem.eql(u8, argv[1], "--lease-probe")) return @import("lease_probe.zig").run();
    // The config file, if there is one.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = if (init.environ_map.get("XDG_CONFIG_HOME")) |x|
        std.fmt.bufPrint(&path_buf, "{s}/oez/config.toml", .{x}) catch ""
    else
        std.fmt.bufPrint(&path_buf, "{s}/.config/oez/config.toml", .{init.environ_map.get("HOME") orelse ""}) catch "";
    const config_text: []const u8 = Io.Dir.cwd().readFileAlloc(io, config_path, init.arena.allocator(), .limited(1 << 16)) catch "";
    if (config_text.len > 0) log.info("config: {s}", .{config_path});
    const args = parseArgs(argv, config_text) catch return 2;

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

    if (args.direct.len > 0) return runDirect(io, gpa, args, layout, &acq, &reader, &blk);

    // ---- window and renderer ----
    var win: Window = undefined;
    try win.init("oEZ");
    defer win.deinit();
    const fullscreen = args.monitor.len > 0;
    if (fullscreen) {
        if (win.fullscreenOn(args.monitor)) {
            log.info("fullscreen on {s}", .{args.monitor});
        } else {
            log.err("no monitor named '{s}'; there are:", .{args.monitor});
            for (win.outputs[0..win.num_outputs]) |*o| log.err("  {s}", .{o.name()});
            return 2;
        }
    }
    _ = win.declareLowLatency();
    if (args.tearing and !win.preferTearing()) log.warn("the compositor has no tearing control; frames will wait for the refresh", .{});
    var gpu = try Gpu.init(gpa, .{ .wayland = .{ .display = win.display, .surface = win.surface } }, args.present);
    defer gpu.deinit();
    // The longest time base plus a margin, so new samples never overwrite what is drawn.
    try gpu.createHistory(nch, @intFromFloat((View.span_max + 2.0) * fs));

    try acq.start();
    defer acq.join();

    var view: View = .{};
    var newest: i64 = 0;
    var newest_acquired_ns: i128 = 0;
    // Acquisition time of the newest sample drawn in each frame, by frame tag.
    var frame_acquired: [64]i128 = @splat(0);
    // Per-frame timing, to explain frames that land late (logged with OEZ_FRAME_DEBUG=1).
    const FrameTiming = struct { wake_late_ms: f64 = 0, draw_ms: f64 = 0, before_refresh_ms: f64 = 0, callback_to_draw_ms: f64 = 0, target_ns: i128 = 0 };
    var frame_timing: [64]FrameTiming = @splat(.{});
    const frame_debug = std.c.getenv("OEZ_FRAME_DEBUG") != null;
    // OEZ_FRAME_DEBUG=2: one line per presented frame.
    const frame_trace = if (std.c.getenv("OEZ_FRAME_DEBUG")) |v| v[0] == '2' else false;
    var ready_seen_ns: i128 = 0;
    var target_refresh_ns: i128 = 0;
    var frame_tag: u64 = 0;
    // Frame pacing: the last presentation time and refresh period, the margin before the
    // next refresh at which to draw, and when the pending frame is due.
    var last_present_ns: i128 = 0;
    var margin_ms: f64 = if (args.margin_ms >= 0) args.margin_ms else 3.0;
    var draw_at: i128 = 0;
    var misses: u64 = 0;
    var misses_this_second: u32 = 0;
    // The best latency of the last seconds: what a frame that lands on time achieves.
    var best_ms: f64 = std.math.inf(f64);
    var best_age: u32 = 0;
    var clock_checked = false;
    // Recovery of immediate presentation (see the header): skip one frame when frames keep
    // landing a refresh after the one aimed at, and back off if that does not help.
    var skip_frame = false;
    var skips: u64 = 0;
    const skip_backoff_min: i128 = 250 * std.time.ns_per_ms;
    var skip_backoff_ns: i128 = skip_backoff_min;
    var last_skip_ns: i128 = 0;
    var late_run: u32 = 0; // consecutive frames presented a refresh after the one aimed at
    var good_run: u32 = 0;
    var on_time_frames: u64 = 0; // this second
    var late_frames_now: u64 = 0;
    var clean_seconds: u32 = 0;

    var n_out_of_date: u64 = 0;
    var n_busy: u64 = 0;
    var n_resize: u64 = 0;
    var drawn_newest: i64 = 0;
    var last_draw_ns: i128 = 0;
    var script_pos: usize = 0;
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
        // Wake for events, for new samples (every 2 ms), or when the frame is due.
        const wait_ms: i32 = if (draw_at != 0) @intCast(std.math.clamp(@divFloor(draw_at - nowNs(io), std.time.ns_per_ms), 0, 2)) else 2;
        try win.pump(wait_ms);

        // New samples into the GPU's history.
        while (reader.next(&blk)) {
            if (blk.len == 0) continue;
            gpu.writeSamples(blk.first_sample, blk.samples());
            newest = blk.first_sample + @as(i64, @intCast(blk.len));
            newest_acquired_ns = blk.acquired_ns;
        }

        var input = win.takeInput();
        if (args.script.len > 0) runScript(args.script, &script_pos, @as(f64, @floatFromInt(nowNs(io) - t_start)) / 1e9, &input);
        if (view.apply(input)) break;

        for (win.takePresented()) |p| {
            const acquired = frame_acquired[p.tag % frame_acquired.len];
            if (acquired != 0) {
                const ms = @as(f64, @floatFromInt(p.time_ns - acquired)) / 1e6;
                lat_sum += ms;
                lat_min = @min(lat_min, ms);
                lat_max = @max(lat_max, ms);
                lat_n += 1;
                {
                    // Did it reach the screen at the refresh aimed at, or a refresh later?
                    const ft = frame_timing[p.tag % frame_timing.len];
                    if (ft.target_ns != 0 and p.refresh_ns > 0) {
                        if (p.time_ns - ft.target_ns > p.refresh_ns / 2) {
                            late_run += 1;
                            good_run = 0;
                            late_frames_now += 1;
                        } else {
                            late_run = 0;
                            good_run += 1;
                            on_time_frames += 1;
                            // Two seconds of frames on time: the next loss is a new event.
                            if (good_run >= 120) skip_backoff_ns = skip_backoff_min;
                        }
                        // Recovery (see the header). Only a fullscreen window can be scanned
                        // out directly, so only then is there something to recover.
                        const t_now = nowNs(io);
                        if (fullscreen and late_run >= 8 and t_now - last_skip_ns >= skip_backoff_ns) {
                            skip_frame = true;
                            last_skip_ns = t_now;
                            skip_backoff_ns = @min(skip_backoff_ns * 2, 8 * std.time.ns_per_s);
                            late_run = 0;
                        }
                    }
                }
                if (frame_trace) {
                    const ft = frame_timing[p.tag % frame_timing.len];
                    std.debug.print("frame {d} lat {d:.2} before {d:.2} cb {d:.2} shown {d:.2}\n", .{ p.tag, ms, ft.before_refresh_ms, ft.callback_to_draw_ms, if (ft.target_ns != 0) @as(f64, @floatFromInt(p.time_ns - ft.target_ns)) / 1e6 else 0 });
                }
                // Landed a refresh later than frames have been landing: it was drawn too
                // close to the deadline (or the desktop was busy).
                const refresh_ms = @as(f64, @floatFromInt(p.refresh_ns)) / 1e6;
                best_ms = @min(best_ms, ms);
                if (refresh_ms > 0 and ms > best_ms + 0.6 * refresh_ms) {
                    const ft = frame_timing[p.tag % frame_timing.len];
                    if (frame_debug) log.info("late frame {d}: latency {d:.1} ms; woke {d:.2} ms after its time, draw took {d:.2} ms, committed {d:.2} ms before the refresh aimed at, {d:.2} ms after the frame callback; presented {d:.2} ms after that refresh", .{ p.tag, ms, ft.wake_late_ms, ft.draw_ms, ft.before_refresh_ms, ft.callback_to_draw_ms, if (ft.target_ns != 0) @as(f64, @floatFromInt(p.time_ns - ft.target_ns)) / 1e6 else 0 });
                    misses += 1;
                    misses_this_second += 1;
                }
            }
            refresh_ns = p.refresh_ns;
            last_present_ns = p.time_ns;
            if (!clock_checked) {
                clock_checked = true;
                if (win.presentation_clock != 1) log.warn("presentation clock is {d}, not CLOCK_MONOTONIC: latency figures will be off", .{win.presentation_clock});
            }
        }

        const now = nowNs(io);
        if (win.frame_ready and draw_at == 0) {
            ready_seen_ns = now;
            target_refresh_ns = 0;
            // The next refresh after now, less the margin. Without presentation feedback
            // (or before the first), draw at once.
            draw_at = now;
            // (`last_present_ns` can be slightly ahead of now: the compositor reports a flip it
            // has just queued. The arithmetic below handles that; drawing at once instead
            // would put two commits in one refresh and knock direct scanout into queueing.)
            if (refresh_ns > 0 and last_present_ns > 0) {
                const period: i128 = refresh_ns;
                const next_refresh = last_present_ns + (@divFloor(now - last_present_ns, period) + 1) * period;
                const at = next_refresh - @as(i128, @intFromFloat(margin_ms * 1e6));
                // Already inside the margin: this refresh is lost anyway, so aim at the next.
                draw_at = if (at >= now) at else at + period;
                target_refresh_ns = if (at >= now) next_refresh else next_refresh + period;
            }
        }
        const free = args.free_ms >= 0;
        var due = if (free)
            newest != drawn_newest and @as(f64, @floatFromInt(now - last_draw_ns)) >= args.free_ms * 1e6
        else
            win.frame_ready and draw_at != 0 and now >= draw_at;
        if (due and skip_frame and !free and refresh_ns > 0) {
            // Leave this refresh out: with nothing committed the output goes idle, and the
            // next commit is taken at once again.
            skip_frame = false;
            skips += 1;
            draw_at += refresh_ns;
            if (target_refresh_ns != 0) target_refresh_ns += refresh_ns;
            due = false;
        }
        if (due and newest > 0) {
            if (win.resized or gpu.swapchain == .null) {
                try gpu.resize(win.width, win.height);
                win.resized = false;
                n_resize += 1;
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
            const done = nowNs(io);
            frame_timing[frame_tag % frame_timing.len] = .{
                .wake_late_ms = @as(f64, @floatFromInt(now - draw_at)) / 1e6,
                .draw_ms = @as(f64, @floatFromInt(done - now)) / 1e6,
                .before_refresh_ms = if (target_refresh_ns != 0) @as(f64, @floatFromInt(target_refresh_ns - done)) / 1e6 else 0,
                .callback_to_draw_ms = @as(f64, @floatFromInt(now - ready_seen_ns)) / 1e6,
                .target_ns = target_refresh_ns,
            };
            switch (result) {
                .presented => {
                    frames += 1;
                    drawn_newest = newest;
                    last_draw_ns = now;
                },
                .out_of_date => {
                    win.resized = true;
                    win.frame_ready = true;
                    n_out_of_date += 1;
                },
                .busy => {
                    win.frame_ready = true;
                    n_busy += 1;
                },
            }
            draw_at = 0;
        }

        if (now >= next_report) {
            const secs = @as(f64, @floatFromInt(now - t_start)) / 1e9;
            const avg = if (lat_n > 0) lat_sum / lat_n else 0;
            log.info("t={d:.0}s {d} fps, latency ms avg {d:.1} min {d:.1} max {d:.1}, at the refresh aimed at {d}, a refresh later {d}, recovery skips {d}, margin {d:.1} ms, refresh {d:.2} ms, display lost {d} blocks, ring overflow {d}, span {d:.2} s, {d:.0} uV/row, {d}x{d}", .{
                secs,            frames, avg,       if (lat_n > 0) lat_min else 0,             lat_max,
                on_time_frames,  late_frames_now, skips, margin_ms,                            @as(f64, @floatFromInt(refresh_ns)) / 1e6,
                reader.lost,     acq.ring_overflow.load(.monotonic), view.span_s, view.uv_per_row, gpu.extent.width,
                gpu.extent.height,
            });
            on_time_frames = 0;
            late_frames_now = 0;
            if (frame_debug) log.info("  draw results so far: out of date {d}, busy {d}, swapchain rebuilds {d}", .{ n_out_of_date, n_busy, n_resize });
            const refresh_ms_now = @as(f64, @floatFromInt(refresh_ns)) / 1e6;
            // A change of regime moves every frame by a refresh: that is not lateness.
            if (lat_n > 0 and refresh_ms_now > 0 and @abs(lat_min - best_ms) > 0.6 * refresh_ms_now) {
                best_ms = lat_min;
                misses_this_second = 0;
            }
            // Adapt the margin to sustained lateness only. A few late frames now and then come
            // from the desktop (a window moved, a resize), and a wider margin would not have
            // saved them: widen when at least 5 frames in a second were late, and return
            // towards 3 ms after 3 clean seconds.
            // (Not fullscreen: there, frames a refresh late are a lost direct-scanout state,
            // which a wider margin does not prevent and the skip above recovers.)
            if (args.margin_ms < 0 and !fullscreen) {
                const refresh_ms = @as(f64, @floatFromInt(refresh_ns)) / 1e6;
                if (misses_this_second >= 5) {
                    margin_ms = @min(margin_ms + 0.5, @max(3.0, 0.5 * refresh_ms));
                    clean_seconds = 0;
                } else if (misses_this_second == 0) {
                    clean_seconds += 1;
                    if (clean_seconds >= 3 and margin_ms > 3.0) {
                        margin_ms = @max(3.0, margin_ms - 0.5);
                        clean_seconds = 0;
                    }
                } else clean_seconds = 0;
            }
            misses_this_second = 0;
            // Forget the best now and then, so a change of regime (direct scanout lost to
            // an overlapping window, say) is not counted as lateness for ever.
            best_age += 1;
            if (best_age >= 5) {
                best_age = 0;
                best_ms = if (lat_n > 0) lat_min else std.math.inf(f64);
            }
            if (std.c.getenv("OEZ_NO_TITLE") == null) {
                if (std.fmt.bufPrintSentinel(&title_buf, "oEZ   {d:.2} s   {d:.0} uV/row   latency {d:.1} ms   {d} fps", .{ view.span_s, view.uv_per_row, avg, frames }, 0)) |t| win.setTitle(t) else |_| {}
            }
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
