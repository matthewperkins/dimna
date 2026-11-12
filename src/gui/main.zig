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
//!   --script changes the panels. Margin 1.5 ms unless --margin-ms.
//! --monitor makes the window fullscreen on that monitor (the neural display).
//! --tearing asks the compositor to show each frame at once, mid-scan, instead of at the
//!   refresh; implies --present immediate and --free 2. The lowest latency under a compositor:
//!   1.6 ms from a sample's arrival to the flip (measured, Hyprland 0.57.2), and since a new
//!   frame is flipped every 3 ms, every scan line shows data at most a few ms old (with
//!   refresh-locked frames the bottom of the screen is a whole refresh staler than the top).
//!   Hyprland tears only when all of these hold:
//!     general.allow_tearing = true                     (config)
//!     the window is fullscreen                          (--monitor)
//!     the window asks for it (done here) or has a window rule `immediate = true`
//!     cursor.no_hardware_cursors = 1                    (config: no tearing while a hardware
//!                                                        cursor is visible on that monitor)
//!   `hyprctl monitors` shows activelyTearing and tearingBlockedBy. ("next frame is not torn"
//!   is listed whenever a frame is not being torn at that instant; it is not a blocker.)
//! --free MS draws whenever new samples have arrived, at most every MS milliseconds, instead
//!   of once per refresh just before it.
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
//! (--monitor, or `monitor` in the config file). Free-running (--free) without tearing
//! queues frames under direct scanout (33.6 ms).
//!
//! Config file: $XDG_CONFIG_HOME/oez/config.toml (default ~/.config/oez); command-line options
//! win. Top-level keys: monitor = "DP-2", tearing = true, free_ms = 2, margin_ms = 3. Panels:
//! one [[panel]] table each (see src/panels.zig), for example
//!
//!   [[panel]]
//!   name = "Port B"
//!   source = "B1"                 # a headstage, "electrodes", "aux" or "adc"
//!   rect = [0.0, 0.0, 0.5, 1.0]   # x, y, width, height as fractions of the display
//!   span_s = 2.0
//!   scale = 400                   # µV per row (V per row for aux and adc)
//!
//! Without any, there is one panel per headstage, side by side. Wheel, pinch and keys act on
//! the panel under the pointer (marked by a bar along its top).

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
    /// The parsed config file (panels are read from it once the channel layout is known).
    doc: oez.toml.Document = .{ .entries = &.{} },
};

const Input = @import("window.zig").Input;
const panels_mod = oez.panels;
const Panel = panels_mod.Panel;

/// Adds the script steps that are due at `elapsed_s` to `in`. `pos` is the script cursor.
/// `panel=N` (1-based) and `pointer=FX,FY` (fractions of the display) choose the panel that
/// input goes to, as moving the pointer would.
fn runScript(script: []const u8, pos: *usize, elapsed_s: f64, in: *Input, display: *Display) void {
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
        } else if (std.mem.startsWith(u8, what, "panel=")) {
            const n = std.fmt.parseInt(usize, what[6..], 10) catch 1;
            display.scripted_target = std.math.clamp(n, 1, @max(display.set.len, 1)) - 1;
        } else if (std.mem.startsWith(u8, what, "pointer=")) {
            var it = std.mem.tokenizeScalar(u8, what[8..], ',');
            const fx = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            const fy = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            if (display.set.at(fx, fy)) |i| display.scripted_target = i;
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

/// Applies the config file's top-level keys to `a`. (`[[panel]]` tables are read later.)
fn applyConfig(a: *Args, doc: oez.toml.Document) void {
    a.doc = doc;
    for (doc.entries) |e| {
        if (e.table.len != 0) {
            if (!std.mem.eql(u8, e.table, "panel")) log.warn("config line {d}: unknown table [{s}]", .{ e.line, e.table });
            continue;
        }
        if (std.mem.eql(u8, e.key, "monitor") and e.value == .string) {
            a.monitor = e.value.string;
        } else if (std.mem.eql(u8, e.key, "margin_ms") and e.value == .number) {
            a.margin_ms = e.value.number;
        } else if (std.mem.eql(u8, e.key, "free_ms") and e.value == .number) {
            a.free_ms = e.value.number;
        } else if (std.mem.eql(u8, e.key, "tearing") and e.value == .boolean) {
            a.tearing = e.value.boolean;
            if (a.tearing) a.present = .immediate;
        } else log.warn("config line {d}: unknown key '{s}' or wrong type", .{ e.line, e.key });
    }
}

fn parseArgs(args: []const [:0]const u8, doc: oez.toml.Document) !Args {
    var a: Args = .{};
    applyConfig(&a, doc);
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
    // Tearing shows frames as they are presented, so draw as samples arrive.
    if (a.tearing and a.free_ms < 0) a.free_ms = 2;
    return a;
}

/// The panels of the display, and which one input goes to.
const Display = struct {
    set: panels_mod.Set,
    /// The panels as configured, for `r` (reset).
    initial: panels_mod.Set,
    /// The panel that wheel, pinch and keys act on.
    target: usize = 0,
    /// Set by a test script (`panel=`, `pointer=`); then it overrides the pointer.
    scripted_target: ?usize = null,

    fn init(set: panels_mod.Set) Display {
        return .{ .set = set, .initial = set };
    }

    /// Points input at the panel under the pointer (fractions of the display).
    fn pointAt(self: *Display, fx: f64, fy: f64) void {
        if (self.scripted_target) |t| {
            self.target = t;
        } else if (self.set.at(fx, fy)) |t| self.target = t;
    }

    /// Applies what the user did to the target panel. True means quit.
    fn applyInput(self: *Display, in: Input) bool {
        if (self.scripted_target) |t| self.target = t;
        var quit = false;
        for (in.keys[0..in.num_keys]) |k| {
            if (k == .escape or k == .q) quit = true;
        }
        if (self.set.len == 0) return quit;
        const p = &self.set.items[self.target];
        // One wheel click (about 15 units) changes a scale by 15 %.
        const per_unit = 0.0093;
        var sx = in.scroll_x;
        var sy = in.scroll_y;
        if (in.shift) {
            sx += sy;
            sy = 0;
        }
        if (sy != 0) p.scale *= @exp(sy * per_unit);
        if (sx != 0) p.span_s *= @exp(sx * per_unit);
        // Fingers apart = zoom in = less time across the panel.
        if (in.pinch != 1 and in.pinch > 0) p.span_s /= in.pinch;
        for (in.keys[0..in.num_keys]) |k| switch (k) {
            .minus => p.scale *= 1.25,
            .equal => p.scale /= 1.25,
            .left_bracket => p.span_s *= 1.25,
            .right_bracket => p.span_s /= 1.25,
            .r => {
                p.span_s = self.initial.items[self.target].span_s;
                p.scale = self.initial.items[self.target].scale;
            },
            else => {},
        };
        p.clamp();
        return quit;
    }

    /// What to draw: each panel's traces, then dividers and a bar marking the target panel.
    fn frame(self: *const Display, gpu: *const Gpu, nch: usize, fs: f64, newest: i64, draws: *[panels_mod.max_panels]gpu_mod.PanelDraw, fills: *[3 * panels_mod.max_panels]gpu_mod.Fill) struct { draws: []const gpu_mod.PanelDraw, fills: []const gpu_mod.Fill } {
        const width = gpu.extent.width;
        const height = gpu.extent.height;
        var nf: usize = 0;
        for (self.set.items[0..self.set.len], 0..) |*p, i| {
            const r = p.pixelRect(width, height);
            draws[i] = .{
                .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h },
                .params = .{
                    .nch = @intCast(nch),
                    .cap_mask = @intCast(gpu.hist_cap - 1),
                    .newest = @truncate(@as(u64, @bitCast(newest))),
                    .first_ch = p.first_ch,
                    .cols = r.w,
                    .rows = p.rows,
                    .span = @floatCast(p.span_s * fs),
                    .lsb_per_row = @floatCast(p.scale / p.unitsPerLsb()),
                    .half_px = 1.5 / @as(f32, @floatFromInt(r.h)),
                },
            };
            // A line along the left and top edges that are not the display's own.
            const grey: [4]f32 = .{ 0.22, 0.24, 0.28, 1.0 };
            if (r.x > 0) {
                fills[nf] = .{ .rect = .{ .x = r.x, .y = r.y, .w = 1, .h = r.h }, .colour = grey };
                nf += 1;
            }
            if (r.y > 0) {
                fills[nf] = .{ .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, .colour = grey };
                nf += 1;
            }
        }
        if (self.set.len > 1) {
            const r = self.set.items[self.target].pixelRect(width, height);
            fills[nf] = .{ .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = 3 }, .colour = .{ 0.30, 0.55, 0.95, 1.0 } };
            nf += 1;
        }
        return .{ .draws = draws[0..self.set.len], .fills = fills[0..nf] };
    }
};

/// The panels for this run: from the config, or one per headstage.
fn makeDisplay(args: Args, layout: *const oez.types.Layout) ?Display {
    const set = panels_mod.fromConfig(args.doc, layout) catch {
        log.err("config: {s}", .{panels_mod.error_message});
        return null;
    };
    for (set.items[0..set.len], 0..) |*p, i| log.info("panel {d} \"{s}\": {d} {t} channels from channel {d}, {d:.2} s, {d} {s}/row", .{ i + 1, p.name(), p.rows, p.kind, p.first_ch + 1, p.span_s, p.scale, p.unit() });
    return .init(set);
}

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
    gpu.wait_render = true;
    try gpu.createHistory(nch, @intFromFloat((Panel.span_max + 2.0) * fs));
    try gpu.resize(0, 0);
    const period: i128 = gpu.refresh_period_ns;
    const margin_ms: f64 = if (args.margin_ms >= 0) args.margin_ms else 1.5;
    const margin: i128 = @intFromFloat(margin_ms * 1e6);
    log.info("{d}x{d}, refresh {d:.3} ms, drawing {d:.2} ms before each refresh", .{ gpu.extent.width, gpu.extent.height, @as(f64, @floatFromInt(period)) / 1e6, margin_ms });

    try acq.start();
    defer acq.join();

    var display = makeDisplay(args, &layout) orelse return 2;
    var draws: [panels_mod.max_panels]gpu_mod.PanelDraw = undefined;
    var fills: [3 * panels_mod.max_panels]gpu_mod.Fill = undefined;
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
    var render_sum: f64 = 0; // GPU time per frame, ms
    var render_max: f64 = 0;
    var worst_render: f64 = 0;
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
        if (args.script.len > 0) runScript(args.script, &script_pos, @as(f64, @floatFromInt(nowNs(io) - t_start)) / 1e9, &input, &display);
        if (display.applyInput(input)) break;

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
                // Finished (not just started) `margin` before the next refresh.
                draw_at = now + period - margin - gpu.renderEstimateNs();
                in_flight = 0;
            } else if (now - in_flight_since > 2 * std.time.ns_per_s) {
                log.err("a frame was not shown within 2 s; giving up", .{});
                return 1;
            }
        } else if (newest > 0 and now >= draw_at) {
            const fr = display.frame(&gpu, nch, fs, newest, &draws, &fills);
            const result = try gpu.draw(fr.draws, fr.fills, {}, struct {
                fn f(_: void) void {}
            }.f);
            switch (result) {
                .presented => {
                    in_flight = gpu.present_id;
                    in_flight_acquired = newest_acquired_ns;
                    in_flight_since = now;
                    const r = @as(f64, @floatFromInt(gpu.last_render_ns)) / 1e6;
                    render_sum += r;
                    render_max = @max(render_max, r);
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
            log.info("t={d:.0}s {d} fps, latency ms avg {d:.2} min {d:.2} max {d:.2}, refreshes without a new frame {d}, GPU ms per frame avg {d:.2} max {d:.2}, display lost {d} blocks, ring overflow {d}", .{
                secs, frames, if (frames > 0) lat_sum / @as(f64, @floatFromInt(frames)) else 0, if (frames > 0) lat_min else 0, lat_max, missed, if (frames > 0) render_sum / @as(f64, @floatFromInt(frames)) else 0, render_max, reader.lost, acq.ring_overflow.load(.monotonic),
            });
            if (secs > 1.5) worst_render = @max(worst_render, render_max);
            render_sum = 0;
            render_max = 0;
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
    if (total_frames > 0) log.info("direct on {s}, margin {d:.2} ms: {d} frames, latency avg {d:.2} ms, worst {d:.2} ms, refreshes without a new frame {d}, slowest GPU frame {d:.2} ms", .{ args.direct, margin_ms, total_frames, total_lat / @as(f64, @floatFromInt(total_frames)), worst, total_missed, worst_render });
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
    const doc = oez.toml.parse(init.arena.allocator(), config_text) catch {
        log.err("{s}: syntax error on line {d}", .{ config_path, oez.toml.error_line });
        return 2;
    };
    const args = parseArgs(argv, doc) catch return 2;

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
    try gpu.createHistory(nch, @intFromFloat((Panel.span_max + 2.0) * fs));
    var display = makeDisplay(args, &layout) orelse return 2;
    var draws: [panels_mod.max_panels]gpu_mod.PanelDraw = undefined;
    var fills: [3 * panels_mod.max_panels]gpu_mod.Fill = undefined;

    try acq.start();
    defer acq.join();

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

    // Diagnostics only: time the GPU per frame (it delays presenting, see gpu.zig).
    gpu.wait_render = frame_debug;
    var render_sum: f64 = 0;
    var render_max: f64 = 0;
    var render_n: f64 = 0;
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
        if (args.script.len > 0) runScript(args.script, &script_pos, @as(f64, @floatFromInt(nowNs(io) - t_start)) / 1e9, &input, &display);
        // Input goes to the panel under the pointer.
        display.pointAt(input.pointer_x / @as(f64, @floatFromInt(@max(win.width, 1))), input.pointer_y / @as(f64, @floatFromInt(@max(win.height, 1))));
        if (display.applyInput(input)) break;

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
            const fr = display.frame(&gpu, nch, fs, newest, &draws, &fills);
            frame_tag += 1;
            frame_acquired[frame_tag % frame_acquired.len] = newest_acquired_ns;
            const Ctx = struct { win: *Window, tag: u64 };
            const result = try gpu.draw(fr.draws, fr.fills, Ctx{ .win = &win, .tag = frame_tag }, struct {
                fn f(c: Ctx) void {
                    c.win.beforePresent(c.tag);
                }
            }.f);
            const done = nowNs(io);
            if (gpu.wait_render) {
                const r = @as(f64, @floatFromInt(gpu.last_render_ns)) / 1e6;
                render_sum += r;
                render_max = @max(render_max, r);
                render_n += 1;
            }
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
            const tp = &display.set.items[display.target];
            log.info("t={d:.0}s {d} fps, latency ms avg {d:.1} min {d:.1} max {d:.1}, at the refresh aimed at {d}, a refresh later {d}, recovery skips {d}, margin {d:.1} ms, refresh {d:.2} ms, display lost {d} blocks, ring overflow {d}, panel {d} span {d:.2} s scale {d:.1}, {d}x{d}", .{
                secs,            frames, avg,       if (lat_n > 0) lat_min else 0,             lat_max,
                on_time_frames,  late_frames_now, skips, margin_ms,                            @as(f64, @floatFromInt(refresh_ns)) / 1e6,
                reader.lost,     acq.ring_overflow.load(.monotonic), display.target + 1, tp.span_s, tp.scale, gpu.extent.width,
                gpu.extent.height,
            });
            on_time_frames = 0;
            late_frames_now = 0;
            if (frame_debug) {
                log.info("  GPU time per frame: avg {d:.2} ms, max {d:.2} ms; draw results so far: out of date {d}, busy {d}, swapchain rebuilds {d}", .{ if (render_n > 0) render_sum / render_n else 0, render_max, n_out_of_date, n_busy, n_resize });
                render_sum = 0;
                render_max = 0;
                render_n = 0;
            }
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
                if (std.fmt.bufPrintSentinel(&title_buf, "oEZ   {s}: {d:.2} s  {d:.1} {s}/row   latency {d:.1} ms   {d} fps", .{ tp.name(), tp.span_s, tp.scale, tp.unit(), avg, frames }, 0)) |t| win.setTitle(t) else |_| {}
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
