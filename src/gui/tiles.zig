//! The spike tiles: a window (meant for the other monitor) with one tile per electrode,
//! each showing that channel's last spike waveforms on top of each other, its threshold,
//! its noise and its firing rate.
//!
//! What the user does here:
//!
//!   left click on a tile     focus on that channel (`Request.focus`)
//!   right click on a tile    listen to it alone; with Ctrl, add it to (or take it out
//!                            of) what is listened to (`Request.listen`)
//!   middle click anywhere    clear the focus (`Request.unfocus`)
//!   wheel                    scale the tiles shown, 5 % per click (tile_scale.zig)
//!   Ctrl+wheel               scale the tile under the pointer alone
//!   u, Shift+u               undo, redo a change of scale
//!   r                        the tiles shown to their common range
//!   a                        the tiles shown to their own auto range, as fixed numbers
//!   the chips at the bottom  show one port's electrodes, or all
//!
//! The tile window never changes focus or listening itself: it asks the display, and
//! draws what the display publishes in `Config`. The tile whose channel is in focus has an
//! amber frame (`theme.focus`, and nothing else here is amber); a channel listened to has
//! "♪ " before its name. Each tile's range (µV from zero to its edge) comes from the scale
//! model; a tile with no fixed range scales itself to its waveforms ("auto"). The strip at
//! the bottom shows the ports' chips and the range of the tiles shown ("±150 µV", "auto"
//! or "mixed").
//!
//! Like the control window it is a thread of its own with its own Wayland connection and
//! its own renderer (on the display's Vulkan instance). Here it also does its own work:
//! it reads the acquisition ring with a lossy reader and runs the detector (spikes.zig)
//! on every electrode, whichever are shown, so neither the display nor acquisition waits
//! on it, and a hidden tile window costs only the detection. With the display it shares
//! no lock (tile_link.zig): the display publishes `Config`, requests go back through a
//! small queue, and this window publishes a `Report` (the focused channel's threshold, and
//! its view: the port shown and the ranges, which the display thread saves).

const std = @import("std");
const Env = @import("env.zig").Env;
const oez = @import("oez");
const spikes = oez.spikes;
const tile_scale = oez.tile_scale;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const Input = window_mod.Input;
const Ui = @import("ui.zig").Ui;
const gpu_mod = @import("gpu.zig");
const font = @import("font.zig");
const theme = @import("theme.zig");
const format = @import("format.zig");
const Atomic = std.atomic.Value;
const log = std.log.scoped(.tiles);

const link = @import("tile_link.zig");
pub const Config = link.Config;
pub const Shared = link.Shared;
const Requests = @FieldType(Shared, "requests");
const max_tiles = tile_scale.max_tiles;

/// Waveforms are many short lines: room for 16 of 47 segments on 64 tiles.
const max_vertices = 300 * 1024;
/// The focused channel's threshold moves with the noise: it is reported at most this often.
const threshold_report_ns = 100 * std.time.ns_per_ms;

pub const Tiles = struct {
    gpa: std.mem.Allocator,
    shared: *Shared,
    ring: *oez.ring.BlockRing,
    layout: oez.types.Layout,
    block_samples: usize,
    display_gpu: *const gpu_mod.Gpu,
    font_buf: [128:0]u8 = @splat(0),
    font_px: u32 = 14,
    env: *const Env,
    thread: ?std.Thread = null,
    /// The thread's state of what is shown (here, not on its stack: it holds the history).
    view: View = .{},

    /// Starts the tile window's thread. Null if it could not be started.
    pub fn start(
        gpa: std.mem.Allocator,
        shared: *Shared,
        ring: *oez.ring.BlockRing,
        layout: *const oez.types.Layout,
        block_samples: usize,
        display_gpu: *const gpu_mod.Gpu,
        font_name: []const u8,
        font_px: u32,
        env: *const Env,
    ) ?*Tiles {
        const self = gpa.create(Tiles) catch return null;
        self.* = .{
            .gpa = gpa,
            .shared = shared,
            .ring = ring,
            .layout = layout.*,
            .block_samples = block_samples,
            .display_gpu = display_gpu,
            .font_px = font_px,
            .env = env,
        };
        const n = @min(font_name.len, self.font_buf.len);
        @memcpy(self.font_buf[0..n], font_name[0..n]);
        shared.stop.store(false, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            gpa.destroy(self);
            return null;
        };
        return self;
    }

    /// Ends the thread (it must not outlive the ring it reads).
    pub fn stop(self: *Tiles) void {
        self.shared.stop.store(true, .release);
        if (self.thread) |t| t.join();
        self.gpa.destroy(self);
    }

    fn run(self: *Tiles) void {
        self.loop() catch |e| log.warn("the spike tiles stopped: {t}", .{e});
    }

    fn loop(self: *Tiles) !void {
        const gpa = self.gpa;
        const shared = self.shared;
        const nch = self.layout.numChannels();

        var reader = oez.ring.LossyReader.init(self.ring);
        var blk = try oez.types.Block.init(gpa, nch, self.block_samples);
        defer blk.deinit(gpa);
        var det = try spikes.Detector.init(gpa, self.layout.sample_rate, self.layout.num_electrodes);
        defer det.deinit();

        var win: Window = undefined;
        var class_buf: [64]u8 = undefined;
        const class = std.fmt.bufPrintSentinel(&class_buf, "{s}-tiles", .{self.env.app_id}, 0) catch "oez-tiles";
        try win.init("oEZ spikes", class, self.env.key_debug);
        defer win.deinit();
        var gpu = try gpu_mod.Gpu.init(gpa, .{ .display = win.display, .surface = win.surface }, .fifo, self.display_gpu);
        defer gpu.deinit();
        var face = try font.Font.init(gpa, std.mem.sliceTo(&self.font_buf, 0), self.font_px);
        defer face.deinit(gpa);
        const vertices = try gpa.alloc(font.Vertex, max_vertices);
        defer gpa.free(vertices);
        try gpu.createText(face.atlas, font.atlas_size, max_vertices);
        var batch: font.Batch = .{ .font = &face, .vertices = vertices };

        const view = &self.view;
        view.init(&self.layout, &shared.initial_view);
        var cfg: Config = .{};
        var seen: u32 = 0;
        var dirty = true;
        var last_draw: i128 = 0;
        var tag: u64 = 0;
        var pointer: [2]f64 = .{ -1, -1 };
        var script: Script = .{ .rest = self.env.tile_clicks };
        const t_start = nowNs();
        while (!shared.stop.load(.acquire) and !win.closed) {
            try win.pump(4);
            // Detection goes on whether or not the window is being shown, for every channel.
            const before = seen;
            shared.read(&cfg, &seen);
            if (seen != before) dirty = true;
            while (reader.next(&blk)) {
                if (blk.len == 0) continue;
                try det.feed(blk.first_sample, blk.samples(), nch, if (cfg.use_car) &cfg.car else null);
            }
            if (det.changed) dirty = true;
            var in = win.takeInput();
            _ = win.takePresented();
            const now = nowNs();
            script.next(@as(f64, @floatFromInt(now - t_start)) / 1e9, &in);
            if (in.pointer_x != pointer[0] or in.pointer_y != pointer[1] or win.resized) dirty = true;
            pointer = .{ in.pointer_x, in.pointer_y };
            const scene: Scene = .{
                .det = &det,
                .layout = &self.layout,
                .cfg = &cfg,
                .view = view,
                .face = &face,
                .width = @floatFromInt(win.width),
                .height = @floatFromInt(win.height),
                .max_waves = wavesShown(max_vertices, view.num_shown, det.len),
            };
            if (view.apply(&in, scene, &shared.requests, msOf(now))) dirty = true;
            _ = view.scale.tick(msOf(now));
            view.publish(&shared.report, &det, &cfg, now);
            // At most 20 pictures a second: the tiles are for looking at, not for timing.
            if (!dirty or !win.frame_ready or now - last_draw < 50 * std.time.ns_per_ms) continue;
            if (win.resized or gpu.swapchain == .null) {
                try gpu.resize(win.width, win.height);
                win.resized = false;
            }
            var drawn = scene;
            drawn.width = @floatFromInt(gpu.extent.width);
            drawn.height = @floatFromInt(gpu.extent.height);
            drawn.mouse_x = @floatCast(in.pointer_x);
            drawn.mouse_y = @floatCast(in.pointer_y);
            batch.clear();
            draw(&batch, drawn);
            det.changed = false;
            tag += 1;
            if (try present(&gpu, &win, &batch, tag)) {
                dirty = false;
                last_draw = now;
            }
        }
        if (win.closed) log.info("spike tile window closed", .{});
    }
};

/// Puts the batch on the screen. True if it was presented.
fn present(gpu: *gpu_mod.Gpu, win: *Window, batch: *const font.Batch, tag: u64) !bool {
    const Ctx = struct { win: *Window, tag: u64 };
    const result = try gpu.draw(&.{}, &.{}, batch.vertices[0..batch.len], Ctx{ .win = win, .tag = tag }, struct {
        fn f(c: Ctx) void {
            c.win.beforePresent(c.tag);
        }
    }.f);
    switch (result) {
        .presented => return true,
        .out_of_date => win.resized = true,
        .busy => {},
    }
    return false;
}

fn msOf(ns: i128) i64 {
    return @intCast(@divFloor(ns, std.time.ns_per_ms));
}

/// What the tile window shows and how: the port, the channels shown, the scales, and what
/// was last reported. The tile window's thread's alone.
const View = struct {
    scale: tile_scale.Scale = .{},
    /// The port shown (0 = A), or null for all.
    port: ?u8 = null,
    /// Ports with a headstage (a headstage's port is its slot / 2).
    has_port: [4]bool = @splat(false),
    /// The channels shown, in order.
    shown: [max_tiles]u32 = undefined,
    num_shown: usize = 0,
    /// The last report published, and when its threshold was.
    reported: link.Report = .{},
    reported_ns: i128 = 0,
    ever_reported: bool = false,

    /// From the view the window starts with (a range of 0 is auto; a port without a
    /// headstage is all).
    fn init(self: *View, layout: *const oez.types.Layout, start: *const link.TileView) void {
        self.* = .{};
        for (layout.headstageSlice()) |h| {
            if (h.slot / 2 < 4) self.has_port[h.slot / 2] = true;
        }
        self.scale.init(@min(layout.num_electrodes, max_tiles), &start.range_uv);
        self.setPort(layout, start.port);
    }

    fn setPort(self: *View, layout: *const oez.types.Layout, port: ?u8) void {
        self.port = if (port) |p| (if (p < 4 and self.has_port[p]) p else null) else null;
        self.num_shown = 0;
        const n = @min(layout.num_electrodes, max_tiles);
        for (layout.headstageSlice()) |h| {
            if (self.port) |p| if (h.slot / 2 != p) continue;
            for (h.first_channel..h.first_channel + h.num_channels) |ch| {
                if (ch >= n or self.num_shown >= max_tiles) break;
                self.shown[self.num_shown] = @intCast(ch);
                self.num_shown += 1;
            }
        }
        // All, but no headstages listed (a layout made by hand): every electrode.
        if (self.port == null and self.num_shown == 0) {
            for (0..n) |ch| self.shown[ch] = @intCast(ch);
            self.num_shown = n;
        }
    }

    fn sel(self: *const View) []const u32 {
        return self.shown[0..self.num_shown];
    }

    /// The selection's group in the scale model: its own initial common range.
    fn group(self: *const View) usize {
        return self.port orelse 4;
    }

    /// The channel of the tile under a point, if any.
    fn channelAt(self: *const View, grid: Grid, x: f64, y: f64) ?u32 {
        const i = grid.at(@floatCast(x), @floatCast(y)) orelse return null;
        return self.shown[i];
    }

    /// Applies what the user did: clicks become requests to the display, the wheel and the
    /// keys change the scales, a chip the port. True if what is drawn changed.
    fn apply(self: *View, in: *const Input, scene: Scene, requests: *Requests, now_ms: i64) bool {
        var changed = false;
        const grid = tileGrid(self.num_shown, scene.face, scene.width, scene.height);
        if (in.clicks > 0) {
            // A chip's click is the chip's.
            var scratch: [64 * 6]font.Vertex = undefined;
            var b: font.Batch = .{ .font = scene.face, .vertices = &scratch };
            var ui = stripUi(&b, scene, @floatCast(in.pointer_x), @floatCast(in.pointer_y), true);
            if (strip(&ui, self)) |chosen| {
                self.setPort(scene.layout, chosen.port);
                changed = true;
            } else if (self.channelAt(grid, in.pointer_x, in.pointer_y)) |ch| _ = requests.push(.{ .focus = ch });
        }
        if (in.right_clicks > 0) {
            if (self.channelAt(grid, in.pointer_x, in.pointer_y)) |ch| _ = requests.push(.{
                .listen = .{ .channel = ch, .add = in.ctrl },
            });
        }
        if (in.middle_clicks > 0) _ = requests.push(.unfocus);
        var auto: [max_tiles]f32 = undefined;
        const n = self.scale.n;
        if (in.scroll_y != 0 or in.num_keys > 0) autoRanges(scene.det, scene.max_waves, auto[0..n]);
        if (in.scroll_y != 0) {
            if (in.ctrl) {
                if (self.channelAt(grid, in.pointer_x, in.pointer_y)) |ch| {
                    if (ch < n) self.scale.wheelOne(ch, auto[ch], in.scroll_y, now_ms);
                }
            } else self.scale.wheel(self.sel(), self.group(), auto[0..n], in.scroll_y, now_ms);
            changed = true;
        }
        for (in.keys[0..in.num_keys]) |k| switch (k) {
            .named => {},
            .char => |c| switch (c) {
                'u' => changed = (if (in.shift) self.scale.redo() else self.scale.undo()) or changed,
                'U' => changed = self.scale.redo() or changed,
                'r' => {
                    self.scale.toCommon(self.sel(), self.group(), auto[0..n]);
                    changed = true;
                },
                'a' => {
                    self.scale.fixAuto(self.sel(), auto[0..n]);
                    changed = true;
                },
                else => {},
            },
        };
        return changed;
    }

    /// What the display is told: the focused channel's threshold, and the view.
    fn report(self: *const View, det: *const spikes.Detector, cfg: *const Config) link.Report {
        var r: link.Report = .{ .view = .{ .port = self.port, .range_uv = self.scale.ranges } };
        if (cfg.focus) |f| {
            r.threshold_channel = f;
            if (f < det.units.len) {
                r.threshold_uv = @floatCast(det.threshold(&det.units[f]) * oez.types.electrode_uv_per_bit);
                r.threshold_valid = true;
            }
        }
        return r;
    }

    /// Publishes the report when something in it changed; a change of the threshold alone
    /// at most every `threshold_report_ns`.
    fn publish(self: *View, out: anytype, det: *const spikes.Detector, cfg: *const Config, now_ns: i128) void {
        const r = self.report(det, cfg);
        const old = &self.reported;
        const now_needed = !self.ever_reported or !r.view.eql(&old.view) or r.threshold_valid != old.threshold_valid or
            r.threshold_channel != old.threshold_channel;
        const threshold_moved = r.threshold_valid and r.threshold_uv != old.threshold_uv and
            now_ns - self.reported_ns >= threshold_report_ns;
        if (!now_needed and !threshold_moved) return;
        out.publish(&r);
        self.reported = r;
        self.reported_ns = now_ns;
        self.ever_reported = true;
    }
};

/// Everything a frame is drawn from (and input is placed by).
const Scene = struct {
    det: *const spikes.Detector,
    layout: *const oez.types.Layout,
    cfg: *const Config,
    view: *const View,
    face: *const font.Font,
    width: f32,
    height: f32,
    mouse_x: f32 = -1,
    mouse_y: f32 = -1,
    /// Waveforms drawn per tile (fewer when there are very many tiles: the vertex budget).
    max_waves: usize,
};

/// Waveforms per tile that fit `vertices` with `n` tiles shown.
fn wavesShown(vertices: usize, n: usize, len: usize) usize {
    const per_tile = vertices / @max(n, 1) -| 400;
    return std.math.clamp(per_tile / ((len - 1) * 6), 2, spikes.max_waves);
}

/// A tile's auto range, in sample units: 8 sigma, or 1.15 times the largest sample of the
/// waveforms shown, whichever is more; at least one.
fn autoRange(det: *const spikes.Detector, u: *const spikes.Unit, max_waves: usize) f64 {
    var range: f64 = 8.0 * u.sigma();
    for (0..wavesOf(u, max_waves)) |k| {
        for (u.wave(k).?[0..det.len]) |v| range = @max(range, 1.15 * @abs(v));
    }
    return @max(range, 1);
}

fn wavesOf(u: *const spikes.Unit, max_waves: usize) usize {
    return @min(@as(usize, @intCast(@min(u.wave_count, spikes.max_waves))), max_waves);
}

/// Every tile's auto range, in µV.
fn autoRanges(det: *const spikes.Detector, max_waves: usize, out: []f32) void {
    for (out, 0..) |*a, i| a.* = @floatCast(autoRange(det, &det.units[i], max_waves) * oez.types.electrode_uv_per_bit);
}

/// The strip along the bottom: one row of `Ui` widgets.
fn stripHeight(face: *const font.Font) f32 {
    return @round(face.line_height) + 12;
}

fn stripUi(batch: *font.Batch, scene: Scene, mouse_x: f32, mouse_y: f32, clicked: bool) Ui {
    return .{
        .batch = batch,
        .mouse_x = mouse_x,
        .mouse_y = mouse_y,
        .clicked = clicked,
        .x = 12,
        .y = @round(scene.height - stripHeight(scene.face)) + 2,
        .width = scene.width,
    };
}

const Chosen = struct { port: ?u8 };

/// The strip: a chip per port with a headstage, "All", and the range of the tiles shown.
/// Returns the chip clicked, if any.
fn strip(ui: *Ui, view: *const View) ?Chosen {
    var chosen: ?Chosen = null;
    for (view.has_port, 0..) |has, i| {
        if (!has) continue;
        const p: u8 = @intCast(i);
        const label = [1]u8{'A' + p};
        if (ui.chip(&label, view.port == p)) chosen = .{ .port = p };
    }
    if (ui.chip("All", view.port == null)) chosen = .{ .port = null };
    ui.space(10);
    var buf: [32]u8 = undefined;
    ui.text(switch (view.scale.summary(view.sel())) {
        .auto => "auto",
        .mixed => "mixed",
        .common => |r| rangeText(&buf, r),
    }, theme.text_dim);
    return chosen;
}

/// "±150 µV", "±1.50 mV".
fn rangeText(buf: []u8, uv: f32) []const u8 {
    var scale_buf: [24]u8 = undefined;
    return format.fmt(buf, "\u{00B1}{s}", .{format.fmtScale(&scale_buf, .electrode, uv)});
}

/// The tiles fill the window above the strip.
fn tileGrid(n: usize, face: *const font.Font, width: f32, height: f32) Grid {
    return .of(n, width, @max(height - stripHeight(face), 1));
}

/// Where the tiles are: a grid that fills the window, tiles a little wider than tall.
const Grid = struct {
    n: usize,
    cols: usize,
    rows: usize,
    tile_w: f32,
    tile_h: f32,

    fn of(n: usize, width: f32, height: f32) Grid {
        if (n == 0) return .{ .n = 0, .cols = 1, .rows = 1, .tile_w = width, .tile_h = height };
        // Columns so that a tile is about 1.25 times as wide as it is tall.
        const ideal = @sqrt(@as(f32, @floatFromInt(n)) * width / @max(height, 1) / 1.25);
        const cols: usize = std.math.clamp(@as(usize, @intFromFloat(@round(ideal))), 1, n);
        const rows = (n + cols - 1) / cols;
        return .{
            .n = n,
            .cols = cols,
            .rows = rows,
            .tile_w = width / @as(f32, @floatFromInt(cols)),
            .tile_h = height / @as(f32, @floatFromInt(rows)),
        };
    }

    fn rect(self: Grid, i: usize) [4]f32 {
        const gap = 3;
        return .{
            @round(@as(f32, @floatFromInt(i % self.cols)) * self.tile_w) + gap,
            @round(@as(f32, @floatFromInt(i / self.cols)) * self.tile_h) + gap,
            @round(self.tile_w) - 2 * gap,
            @round(self.tile_h) - 2 * gap,
        };
    }

    /// The tile under a point, if any.
    fn at(self: Grid, x: f32, y: f32) ?usize {
        if (x < 0 or y < 0 or self.n == 0) return null;
        const col: usize = @intFromFloat(x / self.tile_w);
        const row: usize = @intFromFloat(y / self.tile_h);
        const i = row * self.cols + col;
        return if (col < self.cols and i < self.n) i else null;
    }
};

fn draw(batch: *font.Batch, scene: Scene) void {
    const view = scene.view;
    const grid = tileGrid(view.num_shown, batch.font, scene.width, scene.height);
    const hover = grid.at(scene.mouse_x, scene.mouse_y);
    for (view.sel(), 0..) |ch, i| drawTile(batch, scene, grid.rect(i), ch, hover == i);
    var ui = stripUi(batch, scene, scene.mouse_x, scene.mouse_y, false);
    _ = strip(&ui, view);
}

fn drawTile(batch: *font.Batch, scene: Scene, r: [4]f32, ch: u32, hovered: bool) void {
    const det = scene.det;
    const cfg = scene.cfg;
    const u = &det.units[ch];
    const line_h = @round(batch.font.line_height);
    const uv = oez.types.electrode_uv_per_bit;
    const x = r[0];
    const y = r[1];
    const w = r[2];
    const h = r[3];
    const listened = std.mem.indexOfScalar(u32, cfg.listening[0..cfg.num_listening], ch) != null;
    batch.rect(x, y, w, h, if (hovered) theme.tile_bg_hover else theme.tile_bg);
    if (cfg.focus == ch) {
        batch.rect(x, y, w, 1, theme.focus);
        batch.rect(x, y + h - 1, w, 1, theme.focus);
        batch.rect(x, y, 1, h, theme.focus);
        batch.rect(x + w - 1, y, 1, h, theme.focus);
    }
    // Name (a note before it when listened to) and firing rate along the top.
    var buf: [32]u8 = undefined;
    var name_buf: [16]u8 = undefined;
    var label_buf: [24]u8 = undefined;
    const name = scene.layout.channelName(&name_buf, ch);
    const label = if (listened) format.fmt(&label_buf, "\u{266A} {s}", .{name}) else name;
    _ = batch.text(x + 5, y + 3, label, theme.text_dim);
    if (w > 110) {
        const rate = format.fmt(&buf, "{d:.1} Hz", .{u.rate});
        _ = batch.text(x + w - batch.font.width(rate) - 5, y + 3, rate, theme.text_dim);
    }

    // The waveforms: zero at two fifths of the height, so troughs have the room.
    const top = y + line_h + 6;
    const bottom = y + h - 4;
    if (bottom - top < 12) return;
    const fixed = if (ch < scene.view.scale.n) scene.view.scale.ranges[ch] else 0;
    const range: f64 = if (fixed > 0) fixed / uv else autoRange(det, u, scene.max_waves);
    const shown = wavesOf(u, scene.max_waves);
    const zero = top + 0.4 * (bottom - top);
    const per_unit: f32 = @floatCast(0.6 * (bottom - top) / range);
    const x_step = (w - 10) / @as(f32, @floatFromInt(det.len - 1));
    const yOf = struct {
        fn f(z: f32, scale: f32, lo: f32, hi: f32, v: f64) f32 {
            return std.math.clamp(z - @as(f32, @floatCast(v)) * scale, lo, hi);
        }
    }.f;
    // The threshold, and the trough's place in time.
    const thr_y = yOf(zero, per_unit, top, bottom, det.threshold(u));
    batch.rect(x + 3, @round(thr_y), w - 6, 1, theme.tile_threshold);
    // Oldest first, so the newest is on top and brightest.
    var k = shown;
    while (k > 0) {
        k -= 1;
        const wave = u.wave(k).?;
        var colour = theme.tile_wave;
        colour[3] = @intFromFloat(70.0 + 170.0 * (1.0 - @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(@max(shown, 1)))));
        for (1..det.len) |s| {
            batch.line(
                x + 5 + @as(f32, @floatFromInt(s - 1)) * x_step,
                yOf(zero, per_unit, top, bottom, wave[s - 1]),
                x + 5 + @as(f32, @floatFromInt(s)) * x_step,
                yOf(zero, per_unit, top, bottom, wave[s]),
                1.2,
                colour,
            );
        }
    }
    // The noise, bottom right; a fixed range, bottom left, where there is room for it.
    if (h > 3 * line_h and w > 80) {
        const sigma = format.fmt(&buf, "\u{03C3} {d:.1}", .{u.sigma() * uv});
        const sigma_x = x + w - batch.font.width(sigma) - 5;
        _ = batch.text(sigma_x, y + h - line_h - 2, sigma, theme.text_dim);
        if (fixed > 0) {
            var range_buf: [32]u8 = undefined;
            const text = rangeText(&range_buf, fixed);
            if (x + 5 + batch.font.width(text) + 10 <= sigma_x) _ = batch.text(x + 5, y + h - line_h - 2, text, theme.tile_range_text);
        }
    }
}

/// Scripted input for tests (OEZ_TILE_CLICKS): steps "SECONDS:X,Y[,ACTION]" separated by
/// ';'. SECONDS after the window opened, the pointer goes to (X, Y) in pixels and ACTION
/// happens; a negative X means at -X with Ctrl held. ACTION is:
///
///   (none)  a left click          r   a right click         m   a middle click
///   wN      the wheel, N axis units (15 = one click; negative the other way)
///   WN      Ctrl+wheel, N axis units
///   kC      the key C             KC  Shift+C (KC with C = u: redo)
///
/// C is one character, and cannot be ';'. One step is taken per pass of the loop.
const Script = struct {
    rest: []const u8,

    /// Puts the next step into `in` if its time has come.
    fn next(self: *Script, seconds: f64, in: *Input) void {
        if (self.rest.len == 0) return;
        const end = std.mem.indexOfScalar(u8, self.rest, ';') orelse self.rest.len;
        const step = self.rest[0..end];
        const colon = std.mem.indexOfScalar(u8, step, ':') orelse step.len;
        const at = std.fmt.parseFloat(f64, step[0..colon]) catch 0;
        if (seconds < at) return;
        applyStep(step[@min(colon + 1, step.len)..], in);
        self.rest = self.rest[@min(end + 1, self.rest.len)..];
    }
};

/// "X,Y[,ACTION]" into `in`.
fn applyStep(step: []const u8, in: *Input) void {
    var it = std.mem.splitScalar(u8, step, ',');
    const px = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
    in.pointer_x = @abs(px);
    in.pointer_y = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
    in.ctrl = px < 0;
    const action = it.rest();
    if (action.len == 0) {
        in.clicks += 1;
        return;
    }
    const arg = action[1..];
    switch (action[0]) {
        'r' => in.right_clicks += 1,
        'm' => in.middle_clicks += 1,
        'w', 'W' => {
            in.scroll_y += std.fmt.parseFloat(f64, arg) catch 0;
            if (action[0] == 'W') in.ctrl = true;
        },
        'k', 'K' => if (arg.len == 1 and in.num_keys < in.keys.len) {
            in.keys[in.num_keys] = .{ .char = arg[0] };
            in.num_keys += 1;
            if (action[0] == 'K') in.shift = true;
        },
        else => log.warn("OEZ_TILE_CLICKS: unknown action \"{s}\"", .{action}),
    }
}

const nowNs = oez.clock.nowNs;

const testing = std.testing;

test "the grid has as many columns as make tiles about 1.25 times as wide as tall" {
    // 32 tiles on 1600 x 900: sqrt(32 * 1600 / 900 / 1.25) = 6.75, so 7 columns, 5 rows.
    var g: Grid = .of(32, 1600, 900);
    try testing.expectEqual(7, g.cols);
    try testing.expectEqual(5, g.rows);
    try testing.expectApproxEqAbs(1600.0 / 7.0, g.tile_w, 1e-3);
    try testing.expectEqual(180, g.tile_h);
    // 64 on 1920 x 1080: sqrt(91.0) = 9.54, so 10 columns, 7 rows.
    g = .of(64, 1920, 1080);
    try testing.expectEqual(10, g.cols);
    try testing.expectEqual(7, g.rows);
    // A tall, narrow window: one column.
    g = .of(16, 200, 2000);
    try testing.expectEqual(1, g.cols);
    try testing.expectEqual(16, g.rows);
    // A wide, low one: never more columns than tiles.
    g = .of(4, 4000, 100);
    try testing.expectEqual(4, g.cols);
    try testing.expectEqual(1, g.rows);
    // One tile fills the window.
    g = .of(1, 640, 480);
    try testing.expectEqual(1, g.cols);
    try testing.expectEqual(1, g.rows);
    try testing.expectEqual(640, g.tile_w);
    try testing.expectEqual(480, g.tile_h);
    // Every tile has a place, and no row is empty.
    for ([_]usize{ 1, 2, 3, 5, 7, 16, 31, 32, 33, 62, 64, 128 }) |n| {
        for ([_][2]f32{ .{ 1600, 900 }, .{ 900, 1600 }, .{ 300, 300 }, .{ 2560, 400 } }) |size| {
            g = .of(n, size[0], size[1]);
            try testing.expect(g.cols >= 1 and g.cols <= n);
            try testing.expect(g.cols * g.rows >= n);
            try testing.expect(g.cols * (g.rows - 1) < n);
        }
    }
}

test "the tile under a point" {
    // 32 tiles, 7 x 5, each 228.57 x 180.
    const g: Grid = .of(32, 1600, 900);
    try testing.expectEqual(0, g.at(0, 0).?);
    try testing.expectEqual(0, g.at(228, 179.9).?);
    try testing.expectEqual(1, g.at(229, 0).?);
    try testing.expectEqual(7, g.at(0, 180).?);
    try testing.expectEqual(6, g.at(1599, 0).?);
    // Row 4 holds tiles 28 to 31; its last three places are empty.
    try testing.expectEqual(31, g.at(3 * 228.6 + 1, 899).?);
    try testing.expectEqual(null, g.at(4 * 228.6 + 1, 899));
    // Outside the window.
    try testing.expectEqual(null, g.at(-1, 10));
    try testing.expectEqual(null, g.at(10, -0.5));
    try testing.expectEqual(null, g.at(1600, 10));
    try testing.expectEqual(null, g.at(10, 900));
    // No tiles: nothing is under any point.
    const none: Grid = .of(0, 1600, 900);
    try testing.expectEqual(1, none.cols);
    try testing.expectEqual(null, none.at(10, 10));
}

test "a tile's rectangle is its cell less a 3-pixel gap, and holds the points that find it" {
    const g: Grid = .of(32, 1600, 900);
    try testing.expectEqual([4]f32{ 3, 3, 223, 174 }, g.rect(0));
    // Tile 8: column 1, row 1.
    try testing.expectEqual([4]f32{ 232, 183, 223, 174 }, g.rect(8));
    for (0..32) |i| {
        const r = g.rect(i);
        try testing.expectEqual(i, g.at(r[0], r[1]).?);
        try testing.expectEqual(i, g.at(r[0] + r[2] - 1, r[1] + r[3] - 1).?);
    }
}

// ---- Tests of the window's behaviour, without a window ----
//
// The control window's hand-made font: every character 8 pixels wide and drawn as a 1x1
// quad whose atlas position names it, lines 16 pixels high.

var test_atlas: [1]u8 = .{0};

fn testFont() font.Font {
    var f: font.Font = .{ .atlas = &test_atlas, .px = 14, .ascent = 12, .line_height = 16 };
    for (&f.glyphs, 0..) |*g, k| g.* = .{ .x = @intCast(8 + k), .y = 8, .w = 1, .h = 1, .top = 12, .advance = 8 };
    return f;
}

/// The code point of glyph `k` of `testFont` (as `font.Font.glyph` numbers them).
fn testCodepoint(k: usize) u21 {
    const extra = [_]u21{ 0x03C3, 0x2013, 0x2192, 0x266A };
    return if (k < 224) @intCast(32 + k) else extra[k - 224];
}

const test_fs = 30000.0;

/// Electrodes on headstages `{slot, channels}`, in order, then 6 AUX and 8 ADC channels.
fn testLayout(heads: []const [2]usize) oez.types.Layout {
    var l: oez.types.Layout = .{ .sample_rate = test_fs, .hw_clock_hz = 50e6, .num_aux = 6, .num_adc = 8 };
    for (heads, 0..) |hs, k| {
        l.headstages[k] = .{ .slot = hs[0], .chip = "RHD", .num_channels = hs[1], .first_channel = l.num_electrodes, .has_bno = false };
        l.num_electrodes += hs[1];
    }
    l.num_headstages = heads.len;
    return l;
}

/// Port A: 32 + port B: 16.
const two_ports = [_][2]usize{ .{ 0, 32 }, .{ 2, 16 } };

/// Sample `n` of channel `ch`: hashed noise of ±128 LSB, with negative spikes 6 samples
/// long every 10 000 samples on a few channels, of different sizes (and none elsewhere).
fn testSample(n: i64, ch: usize) i16 {
    var h: u64 = @as(u64, @bitCast(n)) *% 0x9E3779B97F4A7C15 ^ (@as(u64, ch) +% 1) *% 0xBF58476D1CE4E5B9;
    h ^= h >> 31;
    h *%= 0x94D049BB133111EB;
    h ^= h >> 29;
    var v: i32 = @as(i32, @intCast(h & 0xff)) - 128;
    const size: i32 = switch (ch) {
        4 => 1500,
        9 => 700,
        40 => 2500,
        70 => 1000,
        else => 0,
    };
    if (size > 0 and @mod(n + @as(i64, @intCast(ch)) * 97, 10000) < 6) v -= size;
    return @intCast(v);
}

/// A detector for `layout`'s electrodes, fed `seconds` of `testSample` in blocks of 256.
fn testDetector(layout: *const oez.types.Layout, seconds: f64) !spikes.Detector {
    var det = try spikes.Detector.init(testing.allocator, test_fs, layout.num_electrodes);
    errdefer det.deinit();
    const nch = layout.numChannels();
    const block = try testing.allocator.alloc(i16, 256 * nch);
    defer testing.allocator.free(block);
    const total: i64 = @intFromFloat(seconds * test_fs);
    var first: i64 = 0;
    while (first < total) : (first += 256) {
        for (0..256) |i| {
            for (0..nch) |ch| block[i * nch + ch] = testSample(first + @as(i64, @intCast(i)), ch);
        }
        try det.feed(first, block, nch, null);
    }
    return det;
}

test "scripted input: the old form clicks, the fourth field does the rest" {
    var s: Script = .{ .rest = "0.5:100,200;1:-30,40;2:10,20,r;2:-10,20,r;2:5,6,m;3:7,8,w-15;3:7,8,W30;4:1,2,ku;4:1,2,Ku;4:1,2,k," };
    var in: Input = .{};
    s.next(0.4, &in);
    try testing.expectEqual(0, in.clicks);
    s.next(0.5, &in);
    try testing.expectEqual(1, in.clicks);
    try testing.expectEqual(100, in.pointer_x);
    try testing.expectEqual(200, in.pointer_y);
    try testing.expect(!in.ctrl);
    in = .{};
    s.next(1.0, &in); // a negative X: Ctrl, at -X
    try testing.expectEqual(1, in.clicks);
    try testing.expectEqual(30, in.pointer_x);
    try testing.expect(in.ctrl);
    // One step per call, even when several are due.
    in = .{};
    s.next(9, &in);
    try testing.expectEqual(0, in.clicks);
    try testing.expectEqual(1, in.right_clicks);
    try testing.expect(!in.ctrl);
    in = .{};
    s.next(9, &in);
    try testing.expectEqual(1, in.right_clicks);
    try testing.expect(in.ctrl);
    in = .{};
    s.next(9, &in);
    try testing.expectEqual(1, in.middle_clicks);
    try testing.expectEqual(0, in.clicks);
    in = .{};
    s.next(9, &in);
    try testing.expectEqual(-15, in.scroll_y);
    try testing.expect(!in.ctrl);
    in = .{};
    s.next(9, &in);
    try testing.expectEqual(30, in.scroll_y);
    try testing.expect(in.ctrl);
    in = .{};
    s.next(9, &in);
    try testing.expectEqual(1, in.num_keys);
    try testing.expect(in.keys[0].is('u') and !in.shift);
    in = .{};
    s.next(9, &in);
    try testing.expect(in.keys[0].is('u') and in.shift);
    in = .{};
    s.next(9, &in);
    try testing.expect(in.keys[0].is(','));
    try testing.expectEqual(0, s.rest.len);
    in = .{};
    s.next(9, &in);
    try testing.expect(in.clicks == 0 and in.right_clicks == 0 and in.middle_clicks == 0 and in.num_keys == 0 and in.scroll_y == 0);
}

/// A view and what it acts in, for the tests of input.
const InputTest = struct {
    layout: oez.types.Layout,
    det: spikes.Detector,
    face: font.Font = testFont(),
    cfg: Config = .{},
    view: View = .{},
    requests: Requests = .{},

    fn init(self: *InputTest, heads: []const [2]usize, start: link.TileView) !void {
        self.* = .{ .layout = testLayout(heads), .det = undefined };
        self.det = try testDetector(&self.layout, 0.5);
        self.view.init(&self.layout, &start);
    }

    fn deinit(self: *InputTest) void {
        self.det.deinit();
    }

    /// Applies `in` at `now_ms` in a 1000 x 700 window.
    fn apply(self: *InputTest, in: Input, now_ms: i64) bool {
        const scene: Scene = .{
            .det = &self.det,
            .layout = &self.layout,
            .cfg = &self.cfg,
            .view = &self.view,
            .face = &self.face,
            .width = 1000,
            .height = 700,
            .max_waves = spikes.max_waves,
        };
        return self.view.apply(&in, scene, &self.requests, now_ms);
    }
};

test "clicks ask the display: left focuses, right listens, middle unfocuses; a chip is the chip's" {
    const t = try testing.allocator.create(InputTest);
    defer testing.allocator.destroy(t);
    try t.init(&two_ports, .{});
    defer t.deinit();
    // 48 tiles above a 28-pixel strip: 8 columns of 125, 6 rows of 112.
    try testing.expect(!t.apply(.{ .clicks = 1, .pointer_x = 130, .pointer_y = 10 }, 0));
    try testing.expectEqual(link.Request{ .focus = 1 }, t.requests.pop().?);
    _ = t.apply(.{ .right_clicks = 1, .pointer_x = 10, .pointer_y = 120 }, 0);
    try testing.expectEqual(link.Request{ .listen = .{ .channel = 8, .add = false } }, t.requests.pop().?);
    _ = t.apply(.{ .right_clicks = 1, .ctrl = true, .pointer_x = 10, .pointer_y = 120 }, 0);
    try testing.expectEqual(link.Request{ .listen = .{ .channel = 8, .add = true } }, t.requests.pop().?);
    _ = t.apply(.{ .middle_clicks = 1, .pointer_x = 990, .pointer_y = 690 }, 0);
    try testing.expectEqual(link.Request.unfocus, t.requests.pop().?);
    // Clicks off the tiles (the strip) ask nothing.
    _ = t.apply(.{ .clicks = 1, .right_clicks = 1, .pointer_x = 500, .pointer_y = 690 }, 0);
    try testing.expectEqual(null, t.requests.pop());
    // The strip's chips: A at x 12, B at 45, All at 78, each 30 wide, from y 674.
    try testing.expect(t.apply(.{ .clicks = 1, .pointer_x = 50, .pointer_y = 680 }, 0));
    try testing.expectEqual(null, t.requests.pop());
    try testing.expectEqual(1, t.view.port.?);
    try testing.expectEqual(16, t.view.num_shown);
    // Now the first tile is B1-1, channel 32 (16 tiles: 4 x 4 of 250 x 168).
    _ = t.apply(.{ .clicks = 1, .pointer_x = 10, .pointer_y = 10 }, 0);
    try testing.expectEqual(link.Request{ .focus = 32 }, t.requests.pop().?);
    _ = t.apply(.{ .clicks = 1, .pointer_x = 80, .pointer_y = 680 }, 0);
    try testing.expectEqual(null, t.view.port);
    try testing.expectEqual(48, t.view.num_shown);
}

test "the wheel scales the tiles shown, Ctrl+wheel the one under the pointer, keys undo" {
    const t = try testing.allocator.create(InputTest);
    defer testing.allocator.destroy(t);
    var start: link.TileView = .{ .port = 0 };
    start.range_uv[40] = 300; // a B tile, not shown
    try t.init(&two_ports, start);
    defer t.deinit();
    try testing.expectEqual(32, t.view.num_shown);
    try testing.expect(t.apply(.{ .scroll_y = 15, .pointer_x = 500, .pointer_y = 300 }, 1000));
    const common = t.view.scale.common[0];
    try testing.expect(common > 1);
    for (0..32) |ch| try testing.expectApproxEqRel(common * 1.05, t.view.scale.ranges[ch], 1e-6);
    try testing.expectEqual(0, t.view.scale.ranges[32]);
    try testing.expectEqual(300, t.view.scale.ranges[40]);
    // Ctrl+wheel over tile 1 (32 tiles: 6 x 6 of 166.7 x 112).
    _ = t.apply(.{ .scroll_y = 15, .ctrl = true, .pointer_x = 200, .pointer_y = 10 }, 1100);
    try testing.expectApproxEqRel(common * 1.05 * 1.05, t.view.scale.ranges[1], 1e-6);
    try testing.expectApproxEqRel(common * 1.05, t.view.scale.ranges[0], 1e-6);
    // u takes back the whole gesture (still waiting), then the common range.
    try testing.expect(t.apply(keyInput('u', false), 1200));
    try testing.expectEqual(common, t.view.scale.ranges[1]);
    _ = t.apply(keyInput('u', false), 1300);
    try testing.expectEqual(0, t.view.scale.ranges[1]);
    try testing.expectEqual(300, t.view.scale.ranges[40]);
    // Shift+u forward again.
    _ = t.apply(keyInput('u', true), 1400);
    try testing.expectEqual(common, t.view.scale.ranges[1]);
    // a: the tiles shown to their own auto ranges, fixed.
    _ = t.apply(keyInput('a', false), 1500);
    try testing.expectEqual(Scale.clamp(@floatCast(autoRange(&t.det, &t.det.units[4], spikes.max_waves) * 0.195)), t.view.scale.ranges[4]);
    try testing.expectEqual(0, t.view.scale.ranges[32]);
    // r: back to the common range.
    _ = t.apply(keyInput('r', false), 1600);
    try testing.expectEqual(common, t.view.scale.ranges[4]);
}

const Scale = tile_scale.Scale;

fn keyInput(c: u8, shift: bool) Input {
    var in: Input = .{ .num_keys = 1, .shift = shift };
    in.keys[0] = .{ .char = c };
    return in;
}

test "the start: ranges and port from the initial view; a port without a headstage is all" {
    const t = try testing.allocator.create(InputTest);
    defer testing.allocator.destroy(t);
    var start: link.TileView = .{ .port = 3 };
    start.range_uv[2] = 150;
    try t.init(&two_ports, start);
    defer t.deinit();
    try testing.expectEqual(null, t.view.port);
    try testing.expectEqual(48, t.view.num_shown);
    try testing.expectEqual(150, t.view.scale.ranges[2]);
    try testing.expectEqual(1, t.view.scale.len);
    // Three headstages on two ports: A shows both of A's.
    const u = try testing.allocator.create(InputTest);
    defer testing.allocator.destroy(u);
    try u.init(&.{ .{ 0, 32 }, .{ 1, 16 }, .{ 2, 16 } }, .{ .port = 0 });
    defer u.deinit();
    try testing.expectEqual(48, u.view.num_shown);
    try testing.expectEqual(47, u.view.shown[47]);
    try testing.expectEqualSlices(bool, &.{ true, true, false, false }, &u.view.has_port);
}

test "the report: the focused electrode's threshold in µV, published when it changes" {
    const t = try testing.allocator.create(InputTest);
    defer testing.allocator.destroy(t);
    try t.init(&two_ports, .{});
    defer t.deinit();
    const Sink = struct {
        count: usize = 0,
        last: link.Report = .{},
        fn publish(self: *@This(), r: *const link.Report) void {
            self.count += 1;
            self.last = r.*;
        }
    };
    var sink: Sink = .{};
    const ms = std.time.ns_per_ms;
    // Nothing in focus: no threshold; the first report goes out at once.
    t.view.publish(&sink, &t.det, &t.cfg, 0);
    try testing.expectEqual(1, sink.count);
    try testing.expect(!sink.last.threshold_valid);
    t.view.publish(&sink, &t.det, &t.cfg, 1);
    try testing.expectEqual(1, sink.count);
    // Focus on electrode 4: its threshold, negative, in µV, at once.
    t.cfg.focus = 4;
    t.view.publish(&sink, &t.det, &t.cfg, 2 * ms);
    try testing.expectEqual(2, sink.count);
    try testing.expect(sink.last.threshold_valid);
    try testing.expectEqual(4, sink.last.threshold_channel);
    const want: f32 = @floatCast(t.det.threshold(&t.det.units[4]) * 0.195);
    try testing.expect(want < 0);
    try testing.expectEqual(want, sink.last.threshold_uv);
    // The threshold moving: at most every 100 ms.
    t.det.units[4].mad *= 1.01;
    t.view.publish(&sink, &t.det, &t.cfg, 50 * ms);
    try testing.expectEqual(2, sink.count);
    t.view.publish(&sink, &t.det, &t.cfg, 102 * ms);
    try testing.expectEqual(3, sink.count);
    // A change of the view goes out at once.
    t.view.scale.ranges[0] = 99;
    t.view.publish(&sink, &t.det, &t.cfg, 103 * ms);
    try testing.expectEqual(4, sink.count);
    try testing.expectEqual(99, sink.last.view.range_uv[0]);
    try testing.expectEqual(null, sink.last.view.port);
    // Focus on a channel that is not an electrode (an AUX): no threshold.
    t.cfg.focus = 50;
    t.view.publish(&sink, &t.det, &t.cfg, 104 * ms);
    try testing.expectEqual(5, sink.count);
    try testing.expect(!sink.last.threshold_valid);
}
