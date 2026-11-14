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
//!   drag the red line        fix that channel's threshold at the µV under the pointer
//!                            (`Request.threshold`); over the line the pointer is a hand.
//!                            Below zero it is crossed falling, above zero rising
//!   Ctrl+Shift+wheel         the threshold of the tile under the pointer, 5 % per click:
//!                            larger the way the plain wheel makes waveforms larger
//!                            (negative axis values: usually the wheel turned away)
//!   n                        the threshold of the tile under the pointer: back to
//!                            following the noise if fixed, else fixed where it is now
//!
//! The tile window never changes focus, listening or a threshold itself: it asks the
//! display, and draws what the display publishes in `Config`; only while the red line is
//! being dragged is it drawn at the pointer, not where `Config` has it. The tile whose
//! channel is in focus has an amber frame (`theme.focus`, and nothing else here is amber);
//! a channel listened to has "♪ " before its name. Each tile's range (µV from zero to its
//! edge) comes from the scale model; a tile with no fixed range scales itself to its
//! waveforms ("auto"). A fixed threshold's value ("-52 µV", "+80 µV") is shown beside
//! sigma where there is room; one that follows the noise shows nothing more. The strip at
//! the bottom shows the ports' chips and the range of the tiles shown ("±150 µV", "auto"
//! or "mixed").
//!
//! Like the control window it is a thread of its own with its own Wayland connection and
//! its own renderer (on the display's Vulkan instance). Here it also does its own work:
//! it reads the acquisition ring with a lossy reader and runs the detector (spikes.zig)
//! on every electrode, whichever are shown, so neither the display nor acquisition waits
//! on it, and a hidden tile window costs only the detection. With the display it shares
//! no lock (tile_link.zig): the display publishes `Config`, requests go back through a
//! small queue, and this window publishes a `Report` (every electrode's threshold in use,
//! and its view: the port shown and the ranges, which the display thread saves). The
//! thresholds themselves are the display's, in `Config`.

const std = @import("std");
const Env = @import("env.zig").Env;
const dimna = @import("dimna");
const spikes = dimna.spikes;
const tile_scale = dimna.tile_scale;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const Input = window_mod.Input;
const Ui = @import("ui.zig").Ui;
const gpu_mod = @import("gpu.zig");
const font = @import("font.zig");
const theme = @import("theme.zig");
const format = @import("format.zig");
const i18n = @import("i18n.zig");
const Atomic = std.atomic.Value;
const log = std.log.scoped(.tiles);

const link = @import("tile_link.zig");
pub const Config = link.Config;
pub const Shared = link.Shared;
const Requests = @FieldType(Shared, "requests");
const max_tiles = tile_scale.max_tiles;

/// Waveforms are many short lines: room for 16 of 47 segments on 64 tiles.
const max_vertices = 300 * 1024;
/// A threshold that follows the noise moves with it: the thresholds are reported at most
/// this often.
const threshold_report_ns = 100 * std.time.ns_per_ms;
/// At most 20 pictures a second: the tiles are for looking at, not for timing. A drag
/// sends at most one threshold per picture.
const picture_ms = 50;
/// How near the red line (in pixels, above or below it) a press takes hold of it.
const line_grab_px = 4;
/// A threshold just asked for is taken as the channel's for this long (or until `Config`
/// says so), so wheel clicks and `n` presses quicker than the display's answer add up.
const asked_hold_ms = 250;
const uv_per_bit = dimna.types.electrode_uv_per_bit;

pub const Tiles = struct {
    gpa: std.mem.Allocator,
    shared: *Shared,
    ring: *dimna.ring.BlockRing,
    layout: dimna.types.Layout,
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
        ring: *dimna.ring.BlockRing,
        layout: *const dimna.types.Layout,
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

        var reader = dimna.ring.LossyReader.init(self.ring);
        var blk = try dimna.types.Block.init(gpa, nch, self.block_samples);
        defer blk.deinit(gpa);
        var det = try spikes.Detector.init(gpa, self.layout.sample_rate, self.layout.num_electrodes);
        defer det.deinit();

        var win: Window = undefined;
        var class_buf: [64]u8 = undefined;
        const class = std.fmt.bufPrintSentinel(&class_buf, "{s}-tiles", .{self.env.app_id}, 0) catch "dimna-tiles";
        try win.init("dimna spikes", class, self.env.key_debug);
        defer win.deinit();
        var gpu = try gpu_mod.Gpu.init(gpa, .{ .display = win.display, .surface = win.surface }, .fifo, self.display_gpu);
        defer gpu.deinit();
        var face = try font.Font.init(gpa, std.mem.sliceTo(&self.font_buf, 0), self.font_px);
        defer face.deinit(gpa);
        const vertices = try gpa.alloc(font.Vertex, max_vertices);
        defer gpa.free(vertices);
        try gpu.createText(face.atlas, font.atlas_size, max_vertices);
        gpu.textFont(&face);
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
            if (takeConfig(shared, &cfg, &seen, &det)) dirty = true;
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
            win.setCursor(view.cursor(scene, in.pointer_x, in.pointer_y));
            _ = view.scale.tick(msOf(now));
            view.publish(&shared.report, &det, now);
            if (!dirty or !win.frame_ready or now - last_draw < picture_ms * std.time.ns_per_ms) continue;
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

/// Takes the display's newest `Config` into `cfg`, if there is a new one, and gives the
/// detector its thresholds. True if it was new.
fn takeConfig(shared: *Shared, cfg: *Config, seen: *u32, det: *spikes.Detector) bool {
    const before = seen.*;
    shared.read(cfg, seen);
    if (seen.* == before) return false;
    det.thresholds = cfg.thresholds;
    return true;
}

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
    /// The red line being dragged, if it is.
    drag: ?Drag = null,
    /// The threshold last asked for, while it is held (`asked_hold_ms`).
    asked: ?Asked = null,

    const Drag = struct {
        ch: u32,
        /// The tile's auto range when the drag began, sample units: an auto tile keeps it
        /// until the drag ends, so the line stays under the pointer and means one value.
        auto_range: f64,
        /// The threshold under the pointer, µV (never 0, which would mean the noise).
        uv: f32,
        press_y: f64,
        /// The pointer has moved since the press: only then is anything sent.
        moved: bool = false,
        sent_uv: ?f32 = null,
        sent_ms: i64 = 0,
    };

    const Asked = struct { ch: u32, uv: f32, ms: i64 };

    /// From the view the window starts with (a range of 0 is auto; a port without a
    /// headstage is all).
    fn init(self: *View, layout: *const dimna.types.Layout, start: *const link.TileView) void {
        self.* = .{};
        for (layout.headstageSlice()) |h| {
            if (h.slot / 2 < 4) self.has_port[h.slot / 2] = true;
        }
        self.scale.init(@min(layout.num_electrodes, max_tiles), &start.range_uv);
        self.setPort(layout, start.port);
    }

    fn setPort(self: *View, layout: *const dimna.types.Layout, port: ?u8) void {
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
    /// keys change the scales, a chip the port; the red line is dragged and the threshold
    /// keys and wheel ask the display. True if what is drawn changed.
    fn apply(self: *View, in: *const Input, scene: Scene, requests: *Requests, now_ms: i64) bool {
        var changed = false;
        const grid = tileGrid(self.num_shown, scene.face, scene.width, scene.height);
        // A press while a drag goes on (its release was missed) is the drag's.
        if (in.clicks > 0 and self.drag == null) {
            // A chip's click is the chip's; a press on the red line starts a drag, and
            // does not focus.
            var scratch: [64 * 6]font.Vertex = undefined;
            var b: font.Batch = .{ .font = scene.face, .vertices = &scratch };
            var ui = stripUi(&b, scene, @floatCast(in.pointer_x), @floatCast(in.pointer_y), true);
            if (strip(&ui, self)) |chosen| {
                self.setPort(scene.layout, chosen.port);
                changed = true;
            } else if (lineAt(scene, grid, @floatCast(in.pointer_x), @floatCast(in.pointer_y))) |i| {
                self.startDrag(scene, self.shown[i], in.pointer_y);
                changed = true;
            } else if (self.channelAt(grid, in.pointer_x, in.pointer_y)) |ch| _ = requests.push(.{ .focus = ch });
        }
        if (self.drag != null) changed = self.dragStep(in, scene, grid, requests, now_ms) or changed;
        if (in.right_clicks > 0) {
            if (self.channelAt(grid, in.pointer_x, in.pointer_y)) |ch| _ = requests.push(.{
                .listen = .{ .channel = ch, .add = in.ctrl },
            });
        }
        if (in.middle_clicks > 0) _ = requests.push(.unfocus);
        var auto: [max_tiles]f32 = undefined;
        const n = self.scale.n;
        if (in.scroll_y != 0 or in.num_keys > 0) autoRanges(scene.det, scene.max_waves, auto[0..n]);
        if (in.scroll_y != 0 and in.ctrl and in.shift) {
            // The threshold, not the scale; not while the line is being dragged.
            if (self.drag == null) {
                if (self.channelAt(grid, in.pointer_x, in.pointer_y)) |ch| {
                    const now = self.present(scene, ch, now_ms);
                    _ = self.ask(requests, ch, now.uv * tile_scale.Scale.factor(-in.scroll_y), now_ms);
                }
            }
        } else if (in.scroll_y != 0) {
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
                'n' => if (self.drag == null) {
                    if (self.channelAt(grid, in.pointer_x, in.pointer_y)) |ch| {
                        const now = self.present(scene, ch, now_ms);
                        _ = self.ask(requests, ch, if (now.fixed) 0 else now.uv, now_ms);
                    }
                },
                else => {},
            },
        };
        return changed;
    }

    /// The threshold of channel `ch` now: what `Config` says, or what was just asked for
    /// it (the display may not have answered yet). µV.
    fn present(self: *const View, scene: Scene, ch: u32, now_ms: i64) struct { fixed: bool, uv: f64 } {
        var t = scene.cfg.thresholds;
        if (self.asked) |a| {
            if (a.ch == ch and now_ms - a.ms < asked_hold_ms) t.fixed_uv[ch] = a.uv;
        }
        return .{ .fixed = t.isFixed(ch), .uv = t.levelUv(ch, scene.det.units[ch].sigma() * uv_per_bit) };
    }

    /// Asks the display to fix channel `ch`'s threshold at `uv` (kept within the span the
    /// display keeps it in), or with 0 to let it follow the noise. False if the queue to
    /// the display was full.
    fn ask(self: *View, requests: *Requests, ch: u32, uv: f64, now_ms: i64) bool {
        var t: link.Thresholds = .{};
        t.set(ch, uv);
        if (!requests.push(.{ .threshold = .{ .channel = ch, .uv = t.fixed_uv[ch] } })) return false;
        self.asked = .{ .ch = ch, .uv = t.fixed_uv[ch], .ms = now_ms };
        return true;
    }

    /// A press on tile `ch`'s red line, at height `y`.
    fn startDrag(self: *View, scene: Scene, ch: u32, y: f64) void {
        self.drag = .{
            .ch = ch,
            .auto_range = autoRange(scene.det, &scene.det.units[ch], scene.max_waves),
            .uv = @floatCast(scene.det.threshold(ch) * uv_per_bit),
            .press_y = y,
        };
    }

    /// The drag, one pass on: the threshold follows the pointer, and is sent at most once
    /// per picture and at the release (if it moved). True if what is drawn changed.
    fn dragStep(self: *View, in: *const Input, scene: Scene, grid: Grid, requests: *Requests, now_ms: i64) bool {
        const d = &self.drag.?;
        const i = std.mem.indexOfScalar(u32, self.sel(), d.ch);
        const plot = if (i) |k| tilePlot(scene, grid, k) else null;
        if (plot == null) {
            // The tile is gone or too small to draw a line on: the drag ends, unsent.
            self.drag = null;
            return true;
        }
        if (in.pointer_y != d.press_y) d.moved = true;
        const before = d.uv;
        if (d.moved) d.uv = dragValue(plot.?.valueAt(@floatCast(in.pointer_y)) * uv_per_bit, d.uv);
        const release = !in.left_down;
        const due = release or d.sent_uv == null or now_ms - d.sent_ms >= picture_ms;
        if (d.moved and due and (d.sent_uv == null or d.sent_uv.? != d.uv)) {
            if (self.ask(requests, d.ch, d.uv, now_ms)) {
                d.sent_uv = d.uv;
                d.sent_ms = now_ms;
            }
        }
        if (release) {
            self.drag = null;
            return true;
        }
        return d.uv != before;
    }

    /// The pointer's shape: a hand over a red line, a closed one while dragging it.
    fn cursor(self: *const View, scene: Scene, x: f64, y: f64) window_mod.Cursor {
        if (self.drag != null) return .grabbing;
        const grid = tileGrid(self.num_shown, scene.face, scene.width, scene.height);
        return if (lineAt(scene, grid, @floatCast(x), @floatCast(y)) != null) .grab else .default;
    }

    /// What the display is told: every electrode's threshold in use, and the view.
    fn report(self: *const View, det: *const spikes.Detector) link.Report {
        var r: link.Report = .{ .view = .{ .port = self.port, .range_uv = self.scale.ranges } };
        const n = @min(det.units.len, r.thresholds.uv.len);
        for (r.thresholds.uv[0..n], 0..) |*uv, ch| uv.* = @floatCast(det.threshold(ch) * dimna.types.electrode_uv_per_bit);
        r.thresholds.len = n;
        return r;
    }

    /// Publishes the report when something in it changed; a change of the thresholds alone
    /// at most every `threshold_report_ns`.
    fn publish(self: *View, out: anytype, det: *const spikes.Detector, now_ns: i128) void {
        const r = self.report(det);
        const old = &self.reported;
        const now_needed = !self.ever_reported or !r.view.eql(&old.view) or r.thresholds.len != old.thresholds.len;
        const threshold_moved = !std.mem.eql(f32, &r.thresholds.uv, &old.thresholds.uv) and
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
    layout: *const dimna.types.Layout,
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
    for (out, 0..) |*a, i| a.* = @floatCast(autoRange(det, &det.units[i], max_waves) * dimna.types.electrode_uv_per_bit);
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
    if (ui.chip(i18n.text(.tiles_all), view.port == null)) chosen = .{ .port = null };
    ui.space(10);
    var buf: [32]u8 = undefined;
    ui.text(switch (view.scale.summary(view.sel())) {
        .auto => i18n.text(.tiles_range_auto),
        .mixed => i18n.text(.tiles_range_mixed),
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

/// Where a tile draws values: zero at two fifths of the height of the waveforms' area (so
/// troughs have the room), `range` (sample units) at three fifths below or above it. The
/// pair `yOf` and `valueAt` draw the red line and read the pointer on it, so a dragged line
/// stays under the pointer.
const Plot = struct {
    top: f32,
    bottom: f32,
    zero: f32,
    per_unit: f32,

    /// For the tile at `r` (x, y, width, height); null if it is too small to draw in.
    fn of(r: [4]f32, line_h: f32, range: f64) ?Plot {
        const top = r[1] + line_h + 6;
        const bottom = r[1] + r[3] - 4;
        if (bottom - top < 12) return null;
        return .{
            .top = top,
            .bottom = bottom,
            .zero = top + 0.4 * (bottom - top),
            .per_unit = @floatCast(0.6 * (bottom - top) / range),
        };
    }

    /// The height of value `v`, sample units (kept within the area).
    fn yOf(self: Plot, v: f64) f32 {
        return std.math.clamp(self.zero - @as(f32, @floatCast(v)) * self.per_unit, self.top, self.bottom);
    }

    /// The value at height `y`, sample units (a height beyond the area is taken at its edge).
    fn valueAt(self: Plot, y: f32) f64 {
        return (self.zero - std.math.clamp(y, self.top, self.bottom)) / self.per_unit;
    }
};

/// The range channel `ch`'s tile is drawn in, sample units: its fixed range, or its auto
/// range (held while its line is dragged).
fn tileRange(scene: Scene, ch: u32) f64 {
    const view = scene.view;
    const fixed = if (ch < view.scale.n) view.scale.ranges[ch] else 0;
    if (fixed > 0) return fixed / uv_per_bit;
    if (view.drag) |d| {
        if (d.ch == ch) return d.auto_range;
    }
    return autoRange(scene.det, &scene.det.units[ch], scene.max_waves);
}

/// Where the red line is drawn, sample units: under the pointer while it is dragged, else
/// the threshold `Config` gave the detector.
fn shownThreshold(scene: Scene, ch: u32) f64 {
    if (scene.view.drag) |d| {
        if (d.ch == ch) return d.uv / uv_per_bit;
    }
    return scene.det.threshold(ch);
}

/// Tile `i`'s plot, or null if it is too small for one.
fn tilePlot(scene: Scene, grid: Grid, i: usize) ?Plot {
    return Plot.of(grid.rect(i), @round(scene.face.line_height), tileRange(scene, scene.view.shown[i]));
}

/// The tile whose red line is within `line_grab_px` of a point inside the tile (and
/// within the line's length), if any.
fn lineAt(scene: Scene, grid: Grid, x: f32, y: f32) ?usize {
    const i = grid.at(x, y) orelse return null;
    const r = grid.rect(i);
    if (x < r[0] + 3 or x >= r[0] + r[2] - 3 or y < r[1] or y >= r[1] + r[3]) return null;
    const plot = tilePlot(scene, grid, i) orelse return null;
    // The line is one pixel high, from `line_y`.
    const line_y = @round(plot.yOf(shownThreshold(scene, scene.view.shown[i])));
    const off = if (y < line_y) line_y - y else @max(y - (line_y + 1), 0);
    return if (off <= line_grab_px) i else null;
}

/// The threshold a drag to `uv` µV sets: within the span the display keeps a fixed one in,
/// and never 0 (that would be "follow the noise"): at zero, the sign it had (`was`).
fn dragValue(uv: f64, was: f32) f32 {
    const sign: f64 = if (uv < 0 or (uv == 0 and was < 0)) -1 else 1;
    return @floatCast(sign * std.math.clamp(@abs(uv), dimna.thresholds.min_uv, dimna.thresholds.max_uv));
}

/// A fixed threshold: "-52 µV", "+80 µV", "-1.20 mV".
fn thresholdText(buf: []u8, uv: f32) []const u8 {
    var scale_buf: [24]u8 = undefined;
    const sign: []const u8 = if (uv < 0) "-" else "+";
    return format.fmt(buf, "{s}{s}", .{ sign, format.fmtScale(&scale_buf, .electrode, @abs(uv)) });
}

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

    const plot = Plot.of(r, line_h, tileRange(scene, ch)) orelse return;
    const shown = wavesOf(u, scene.max_waves);
    const x_step = (w - 10) / @as(f32, @floatFromInt(det.len - 1));
    // The threshold (under the pointer while it is dragged).
    batch.rect(x + 3, @round(plot.yOf(shownThreshold(scene, ch))), w - 6, 1, theme.tile_threshold);
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
                plot.yOf(wave[s - 1]),
                x + 5 + @as(f32, @floatFromInt(s)) * x_step,
                plot.yOf(wave[s]),
                1.2,
                colour,
            );
        }
    }
    if (h > 3 * line_h and w > 80) drawReadouts(batch, scene, r, ch);
}

/// Along a tile's bottom: the noise at the right; left of it a fixed threshold (or the
/// one being dragged); a fixed range at the left, where there is room for each, in that
/// order of priority.
fn drawReadouts(batch: *font.Batch, scene: Scene, r: [4]f32, ch: u32) void {
    const x = r[0];
    const text_y = r[1] + r[3] - @round(batch.font.line_height) - 2;
    var buf: [32]u8 = undefined;
    const sigma = format.fmt(&buf, "\u{03C3} {d:.1}", .{scene.det.units[ch].sigma() * uv_per_bit});
    var left_of = x + r[2] - batch.font.width(sigma) - 5;
    _ = batch.text(left_of, text_y, sigma, theme.text_dim);
    const fixed_uv: ?f32 = if (scene.view.drag != null and scene.view.drag.?.ch == ch)
        scene.view.drag.?.uv
    else if (scene.cfg.thresholds.isFixed(ch)) scene.cfg.thresholds.fixed_uv[ch] else null;
    if (fixed_uv) |t| {
        var thr_buf: [32]u8 = undefined;
        const text = thresholdText(&thr_buf, t);
        const thr_x = left_of - batch.font.width(text) - 8;
        if (thr_x >= x + 5) {
            _ = batch.text(thr_x, text_y, text, theme.tile_threshold_text);
            left_of = thr_x;
        }
    }
    const range = if (ch < scene.view.scale.n) scene.view.scale.ranges[ch] else 0;
    if (range > 0) {
        var range_buf: [32]u8 = undefined;
        const text = rangeText(&range_buf, range);
        if (x + 5 + batch.font.width(text) + 10 <= left_of) _ = batch.text(x + 5, text_y, text, theme.tile_range_text);
    }
}

/// Scripted input for tests (DIMNA_TILE_CLICKS): steps "SECONDS:X,Y[,ACTION]" separated by
/// ';'. SECONDS after the window opened, the pointer goes to (X, Y) in pixels and ACTION
/// happens; a negative X means at -X with Ctrl held. ACTION is:
///
///   (none)  a left click          r   a right click         m   a middle click
///   wN      the wheel, N axis units (15 = one click; negative the other way)
///   WN      Ctrl+wheel, N axis units
///   XN      Ctrl+Shift+wheel, N axis units (a tile's threshold)
///   kC      the key C             KC  Shift+C (KC with C = u: redo)
///   p       press the left button and hold it (a drag starts if on a red line)
///   v       move the pointer (with the button still held after a p)
///   l       release the left button
///
/// C is one character, and cannot be ';'. One step is taken per pass of the loop. From a
/// p to its l, every pass has the left button held and the pointer where the script last
/// put it (the real pointer is elsewhere); outside that, the real pointer is left alone.
const Script = struct {
    rest: []const u8,
    /// Where the pointer is while a scripted press is held.
    held: ?[2]f64 = null,

    /// Puts the next step into `in` if its time has come, and a held press.
    fn next(self: *Script, seconds: f64, in: *Input) void {
        self.step(seconds, in);
        if (self.held) |p| {
            in.left_down = true;
            in.pointer_x = p[0];
            in.pointer_y = p[1];
        }
    }

    fn step(self: *Script, seconds: f64, in: *Input) void {
        if (self.rest.len == 0) return;
        const end = std.mem.indexOfScalar(u8, self.rest, ';') orelse self.rest.len;
        const s = self.rest[0..end];
        const colon = std.mem.indexOfScalar(u8, s, ':') orelse s.len;
        const at = std.fmt.parseFloat(f64, s[0..colon]) catch 0;
        if (seconds < at) return;
        self.apply(s[@min(colon + 1, s.len)..], in);
        self.rest = self.rest[@min(end + 1, self.rest.len)..];
    }

    /// "X,Y[,ACTION]" into `in`.
    fn apply(self: *Script, s: []const u8, in: *Input) void {
        var it = std.mem.splitScalar(u8, s, ',');
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
            'w', 'W', 'X' => {
                in.scroll_y += std.fmt.parseFloat(f64, arg) catch 0;
                if (action[0] != 'w') in.ctrl = true;
                if (action[0] == 'X') in.shift = true;
            },
            'k', 'K' => if (arg.len == 1 and in.num_keys < in.keys.len) {
                in.keys[in.num_keys] = .{ .char = arg[0] };
                in.num_keys += 1;
                if (action[0] == 'K') in.shift = true;
            },
            'p' => {
                in.clicks += 1;
                self.held = .{ in.pointer_x, in.pointer_y };
            },
            'v' => if (self.held != null) {
                self.held = .{ in.pointer_x, in.pointer_y };
            },
            'l' => {
                in.left_down = false;
                self.held = null;
            },
            else => log.warn("DIMNA_TILE_CLICKS: unknown action \"{s}\"", .{action}),
        }
    }
};

const nowNs = dimna.clock.nowNs;

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
fn testLayout(heads: []const [2]usize) dimna.types.Layout {
    var l: dimna.types.Layout = .{ .sample_rate = test_fs, .hw_clock_hz = 50e6, .num_aux = 6, .num_adc = 8 };
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
fn testDetector(layout: *const dimna.types.Layout, seconds: f64) !spikes.Detector {
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

test "scripted input: press, move, release hold the button between steps; X is Ctrl+Shift+wheel" {
    var s: Script = .{ .rest = "1:5,6,X-15;2:-7,8,X30;3:100,200,p;4:110,230,v;5:120,240,v;6:130,250,l;7:1,2,v" };
    var in: Input = .{};
    s.next(1, &in);
    try testing.expect(in.scroll_y == -15 and in.ctrl and in.shift and in.clicks == 0 and !in.left_down);
    in = .{};
    s.next(2, &in);
    try testing.expect(in.scroll_y == 30 and in.ctrl and in.shift and in.pointer_x == 7);
    // The press: a click, the button held, and nothing else.
    in = .{};
    s.next(3, &in);
    try testing.expect(in.clicks == 1 and in.left_down and in.pointer_x == 100 and in.pointer_y == 200);
    try testing.expect(in.scroll_y == 0 and !in.ctrl and !in.shift);
    // Between steps: still held, the pointer where the script put it (not the real one).
    in = .{ .pointer_x = 900, .pointer_y = 900 };
    s.next(3.5, &in);
    try testing.expect(in.clicks == 0 and in.left_down and in.pointer_x == 100 and in.pointer_y == 200);
    in = .{};
    s.next(4, &in);
    try testing.expect(in.clicks == 0 and in.left_down and in.pointer_x == 110 and in.pointer_y == 230);
    in = .{};
    s.next(4.5, &in);
    try testing.expect(in.left_down and in.pointer_y == 230);
    in = .{};
    s.next(5, &in);
    try testing.expect(in.left_down and in.pointer_y == 240);
    // The release, at its own place; then the button is up and the real pointer is left alone.
    in = .{ .left_down = true };
    s.next(6, &in);
    try testing.expect(in.clicks == 0 and !in.left_down and in.pointer_x == 130 and in.pointer_y == 250);
    in = .{ .pointer_x = 900, .pointer_y = 901 };
    s.next(6.5, &in);
    try testing.expect(!in.left_down and in.pointer_x == 900 and in.pointer_y == 901);
    // A move without a press only moves.
    in = .{};
    s.next(7, &in);
    try testing.expect(!in.left_down and in.clicks == 0 and in.pointer_x == 1 and in.pointer_y == 2);
    try testing.expectEqual(0, s.rest.len);
}

test "scripted input drives a drag through the view as a pointer would" {
    const t = try testing.allocator.create(InputTest);
    defer testing.allocator.destroy(t);
    try t.init(&two_ports, .{});
    defer t.deinit();
    const ly = t.lineY(9);
    var buf: [128]u8 = undefined;
    const text = format.fmt(&buf, "0:180,{d};1:180,{d},p;2:180,{d},v;3:180,{d},l", .{ ly - 30, ly, ly + 10, ly + 12 });
    var s: Script = .{ .rest = text };
    var got: [16]link.Request = undefined;
    for (0..8) |k| {
        var in: Input = .{};
        s.next(@as(f64, @floatFromInt(k)) * 0.5, &in);
        _ = t.apply(in, @intCast(k * 500));
    }
    // The first step was a plain click above the line: focus. The drag: no focus, two values.
    try testing.expectEqual(link.Request{ .focus = 9 }, t.requests.pop().?);
    const sent = try t.thresholdRequests(&got);
    try testing.expectEqual(2, sent.len);
    try testing.expectEqual(@as(f32, @floatCast(t.plot(9).valueAt(ly + 12) * 0.195)), sent[1].threshold.uv);
    try testing.expectEqual(null, t.view.drag);
}

/// A view and what it acts in, for the tests of input.
const InputTest = struct {
    layout: dimna.types.Layout,
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

    /// A 1000 x 700 window.
    fn scene(self: *InputTest) Scene {
        return .{
            .det = &self.det,
            .layout = &self.layout,
            .cfg = &self.cfg,
            .view = &self.view,
            .face = &self.face,
            .width = 1000,
            .height = 700,
            .max_waves = spikes.max_waves,
        };
    }

    /// Applies `in` at `now_ms` in a 1000 x 700 window.
    fn apply(self: *InputTest, in: Input, now_ms: i64) bool {
        return self.view.apply(&in, self.scene(), &self.requests, now_ms);
    }

    fn grid(self: *InputTest) Grid {
        return tileGrid(self.view.num_shown, &self.face, 1000, 700);
    }

    /// Tile `i`'s plot.
    fn plot(self: *InputTest, i: usize) Plot {
        return tilePlot(self.scene(), self.grid(), i).?;
    }

    /// The top of tile `i`'s red line as drawn (`draw` puts it at the rounded height).
    fn lineY(self: *InputTest, i: usize) f32 {
        return @round(self.plot(i).yOf(shownThreshold(self.scene(), self.view.shown[i])));
    }

    /// As the display does it: the threshold set, and the detector given the new ones.
    fn answer(self: *InputTest, ch: u32, uv: f32) void {
        self.cfg.thresholds.set(ch, uv);
        self.det.thresholds = self.cfg.thresholds;
    }

    /// The threshold requests waiting, in order (and nothing else may be waiting).
    fn thresholdRequests(self: *InputTest, out: []link.Request) ![]link.Request {
        var n: usize = 0;
        while (self.requests.pop()) |r| {
            try testing.expect(r == .threshold);
            out[n] = r;
            n += 1;
        }
        return out[0..n];
    }
};

test "the red line's height and the µV under the pointer are one mapping, both ways, auto and fixed" {
    const t = try testing.allocator.create(InputTest);
    defer testing.allocator.destroy(t);
    var start: link.TileView = .{};
    start.range_uv[1] = 200;
    try t.init(&two_ports, start);
    defer t.deinit();
    // 48 tiles of 125 x 112: tile 0 at (3, 3, 119, 106), its waveforms from y 25 to 105.
    for ([_]usize{ 0, 1, 4 }) |i| {
        const p = t.plot(i);
        const r = t.grid().rect(i);
        try testing.expectEqual(r[1] + 22, p.top);
        try testing.expectEqual(r[1] + r[3] - 4, p.bottom);
        try testing.expectApproxEqAbs(p.top + 0.4 * (p.bottom - p.top), p.zero, 1e-4);
        // The range (a fixed 200 µV, or the tile's auto range) is at the bottom, below
        // zero (0.6 of the area's height); the top is two thirds of it above zero.
        const range: f64 = if (i == 1) 200.0 / 0.195 else autoRange(&t.det, &t.det.units[i], spikes.max_waves);
        try testing.expectApproxEqRel(-range, p.valueAt(p.bottom), 1e-5);
        try testing.expectApproxEqRel(range * 2.0 / 3.0, p.valueAt(p.top), 1e-5);
        try testing.expectEqual(0, p.valueAt(p.zero));
        var y = p.top;
        while (y <= p.bottom) : (y += 0.37) try testing.expectApproxEqAbs(y, p.yOf(p.valueAt(y)), 1e-3);
        // Values: inside the area they come back; beyond it, the edge.
        for ([_]f64{ -1, -0.6, -0.25, 0, 0.1, 0.6 }) |f| {
            try testing.expectApproxEqAbs(f * range, p.valueAt(p.yOf(f * range)), range * 1e-5);
        }
        try testing.expectEqual(p.top, p.yOf(10 * range));
        try testing.expectEqual(p.bottom, p.yOf(-10 * range));
        try testing.expectEqual(p.valueAt(p.top), p.valueAt(p.top - 50));
    }
}

test "the red line is taken within 4 px of it, inside its tile, and nowhere else" {
    const t = try testing.allocator.create(InputTest);
    defer testing.allocator.destroy(t);
    try t.init(&two_ports, .{});
    defer t.deinit();
    const s = t.scene();
    const g = t.grid();
    // Tile 9: column 1, row 1, at (128, 115, 119, 106). Its line (following the noise,
    // so below zero) is one pixel high from `ly`.
    const ly = t.lineY(9);
    try testing.expect(ly > t.plot(9).zero and ly <= t.plot(9).bottom);
    for ([_]f32{ -4, -2, 0, 0.5, 1, 3, 5 }) |dy| try testing.expectEqual(9, lineAt(s, g, 180, ly + dy).?);
    try testing.expectEqual(null, lineAt(s, g, 180, ly - 4.5));
    try testing.expectEqual(null, lineAt(s, g, 180, ly + 5.5));
    // Along the line's length only (x 131 to 244), and inside the tile.
    try testing.expectEqual(9, lineAt(s, g, 131, ly).?);
    try testing.expectEqual(null, lineAt(s, g, 130.5, ly));
    try testing.expectEqual(9, lineAt(s, g, 243.9, ly).?);
    try testing.expectEqual(null, lineAt(s, g, 244, ly));
    try testing.expectEqual(null, lineAt(s, g, 126, ly)); // the gap between tiles
    // The strip with the chips is no tile's.
    for ([_]f32{ 674, 680, 690 }) |y| {
        for ([_]f32{ 15, 50, 80, 500 }) |x| try testing.expectEqual(null, lineAt(s, g, x, y));
    }
    // The pointer's shape.
    try testing.expectEqual(.grab, t.view.cursor(s, 180, ly + 2));
    try testing.expectEqual(.default, t.view.cursor(s, 180, ly + 20));
    _ = t.apply(.{ .clicks = 1, .left_down = true, .pointer_x = 180, .pointer_y = ly }, 0);
    try testing.expectEqual(.grabbing, t.view.cursor(t.scene(), 900, 690));
    // A tile too small for waveforms has no line.
    const tiny: Grid = .of(48, 400, 150);
    try testing.expectEqual(null, tilePlot(s, tiny, 0));
    try testing.expectEqual(null, lineAt(s, tiny, 10, 20));
}

test "a drag sends the µV under the pointer, at most once per picture and at the release; no focus" {
    const t = try testing.allocator.create(InputTest);
    defer testing.allocator.destroy(t);
    try t.init(&two_ports, .{});
    defer t.deinit();
    var got: [16]link.Request = undefined;
    const ly = t.lineY(9);
    const p = t.plot(9);
    // The press: a drag, no focus, nothing sent yet; the auto range is held from here.
    try testing.expect(t.apply(.{ .clicks = 1, .left_down = true, .pointer_x = 180, .pointer_y = ly + 2 }, 1000));
    try testing.expectEqual(0, (try t.thresholdRequests(&got)).len);
    try testing.expectEqual(9, t.view.drag.?.ch);
    // The tile's auto range changes under the drag (its noise triples): the drag keeps
    // the range it began with, so the pointer still means what it did at the press.
    const mad = t.det.units[9].mad;
    t.det.units[9].mad *= 3;
    const before = t.det.threshold(9);
    // Held still: nothing.
    _ = t.apply(.{ .left_down = true, .pointer_x = 180, .pointer_y = ly + 2 }, 1010);
    try testing.expectEqual(0, (try t.thresholdRequests(&got)).len);
    // Moves: the first is sent at once, then one per 50 ms, each the newest.
    const uvAt = struct {
        fn f(pl: Plot, y: f32) f32 {
            return @floatCast(pl.valueAt(y) * 0.195);
        }
    }.f;
    _ = t.apply(.{ .left_down = true, .pointer_x = 180, .pointer_y = ly + 10 }, 1020);
    _ = t.apply(.{ .left_down = true, .pointer_x = 190, .pointer_y = ly + 14 }, 1030);
    _ = t.apply(.{ .left_down = true, .pointer_x = 190, .pointer_y = ly + 18 }, 1069);
    var sent = try t.thresholdRequests(&got);
    try testing.expectEqual(1, sent.len);
    try testing.expectEqual(link.Request{ .threshold = .{ .channel = 9, .uv = uvAt(p, ly + 10) } }, sent[0]);
    // The line is drawn at the pointer meanwhile, not where `Config` has it; the
    // detector's threshold is untouched.
    try testing.expectEqual(before, t.det.threshold(9));
    try testing.expectEqual(ly + 18, t.lineY(9));
    _ = t.apply(.{ .left_down = true, .pointer_x = 190, .pointer_y = ly + 20 }, 1070);
    sent = try t.thresholdRequests(&got);
    try testing.expectEqual(1, sent.len);
    try testing.expectEqual(uvAt(p, ly + 20), sent[0].threshold.uv);
    // The release, 10 ms later: sent at once, where it was released.
    _ = t.apply(.{ .left_down = false, .pointer_x = 190, .pointer_y = ly + 25 }, 1080);
    sent = try t.thresholdRequests(&got);
    try testing.expectEqual(1, sent.len);
    try testing.expectEqual(uvAt(p, ly + 25), sent[0].threshold.uv);
    try testing.expectEqual(null, t.view.drag);
    // Then the tile scales itself again, and the line is `Config`'s (the display has not
    // answered here).
    try testing.expect(t.plot(9).per_unit < p.per_unit * 0.9);
    t.det.units[9].mad = mad;
    try testing.expectEqual(ly, t.lineY(9));
    try testing.expectEqual(.grab, t.view.cursor(t.scene(), 180, ly));
}

test "a drag across zero changes the slope; a press on the line without a move sends nothing" {
    const t = try testing.allocator.create(InputTest);
    defer testing.allocator.destroy(t);
    try t.init(&two_ports, .{});
    defer t.deinit();
    var got: [16]link.Request = undefined;
    const ly = t.lineY(9);
    const p = t.plot(9);
    // Press and release on the line in one pass, and in two: nothing at all.
    _ = t.apply(.{ .clicks = 1, .pointer_x = 180, .pointer_y = ly }, 0);
    try testing.expectEqual(null, t.view.drag);
    _ = t.apply(.{ .clicks = 1, .left_down = true, .pointer_x = 180, .pointer_y = ly }, 100);
    _ = t.apply(.{ .pointer_x = 180, .pointer_y = ly }, 200);
    try testing.expectEqual(0, (try t.thresholdRequests(&got)).len);
    // Up past zero: rising.
    _ = t.apply(.{ .clicks = 1, .left_down = true, .pointer_x = 180, .pointer_y = ly }, 1000);
    _ = t.apply(.{ .left_down = true, .pointer_x = 180, .pointer_y = p.zero - 20 }, 1100);
    var sent = try t.thresholdRequests(&got);
    try testing.expectEqual(1, sent.len);
    try testing.expect(sent[0].threshold.uv > 5);
    try testing.expectApproxEqRel(p.valueAt(p.zero - 20) * 0.195, sent[0].threshold.uv, 1e-5);
    // At zero itself: the smallest threshold of the sign it had, not 0 (the noise).
    _ = t.apply(.{ .left_down = true, .pointer_x = 180, .pointer_y = p.zero }, 1200);
    sent = try t.thresholdRequests(&got);
    try testing.expectEqual(5, sent[0].threshold.uv);
    _ = t.apply(.{ .left_down = true, .pointer_x = 180, .pointer_y = p.zero + 30 }, 1300);
    _ = t.apply(.{ .left_down = false, .pointer_x = 180, .pointer_y = p.zero + 30 }, 1301);
    sent = try t.thresholdRequests(&got);
    // The release where the last move was sent: not sent again.
    try testing.expectEqual(1, sent.len);
    try testing.expect(sent[0].threshold.uv < -5);
}

test "Ctrl+Shift+wheel: the threshold under the pointer 5 % per click, larger the way waveforms grow" {
    const t = try testing.allocator.create(InputTest);
    defer testing.allocator.destroy(t);
    try t.init(&two_ports, .{});
    defer t.deinit();
    var got: [16]link.Request = undefined;
    t.answer(9, -50);
    // Tile 9 at (128, 115): one click the way the plain wheel makes waveforms larger.
    try testing.expect(!t.apply(.{ .scroll_y = -15, .ctrl = true, .shift = true, .pointer_x = 180, .pointer_y = 130 }, 0));
    var sent = try t.thresholdRequests(&got);
    try testing.expectEqual(1, sent.len);
    try testing.expectEqual(9, sent[0].threshold.channel);
    try testing.expectApproxEqRel(-52.5, sent[0].threshold.uv, 1e-6);
    // The scales are untouched.
    try testing.expect(!t.view.scale.pending and t.view.scale.ranges[9] == 0);
    // A second click before the display answers starts from the first.
    _ = t.apply(.{ .scroll_y = -15, .ctrl = true, .shift = true, .pointer_x = 180, .pointer_y = 130 }, 30);
    sent = try t.thresholdRequests(&got);
    try testing.expectApproxEqRel(-50 * 1.05 * 1.05, sent[0].threshold.uv, 1e-6);
    // The display answers; the other way, two clicks at once.
    t.answer(9, sent[0].threshold.uv);
    _ = t.apply(.{ .scroll_y = 30, .ctrl = true, .shift = true, .pointer_x = 180, .pointer_y = 130 }, 1000);
    sent = try t.thresholdRequests(&got);
    try testing.expectApproxEqRel(-50, sent[0].threshold.uv, 1e-5);
    // A channel following the noise is taken at its present value first: tile 1.
    const now: f32 = @floatCast(t.det.threshold(1) * 0.195);
    _ = t.apply(.{ .scroll_y = -15, .ctrl = true, .shift = true, .pointer_x = 130, .pointer_y = 10 }, 2000);
    sent = try t.thresholdRequests(&got);
    try testing.expectEqual(1, sent[0].threshold.channel);
    try testing.expectApproxEqRel(now * 1.05, sent[0].threshold.uv, 1e-5);
    // Off the tiles: nothing.
    _ = t.apply(.{ .scroll_y = -15, .ctrl = true, .shift = true, .pointer_x = 500, .pointer_y = 690 }, 3000);
    try testing.expectEqual(0, (try t.thresholdRequests(&got)).len);
}

test "n: a fixed threshold back to the noise, one following the noise fixed where it is" {
    const t = try testing.allocator.create(InputTest);
    defer testing.allocator.destroy(t);
    try t.init(&two_ports, .{});
    defer t.deinit();
    var got: [16]link.Request = undefined;
    t.answer(9, 80);
    var in = keyInput('n', false);
    in.pointer_x = 180;
    in.pointer_y = 130;
    try testing.expect(!t.apply(in, 0));
    var sent = try t.thresholdRequests(&got);
    try testing.expectEqual(1, sent.len);
    try testing.expectEqual(link.Request{ .threshold = .{ .channel = 9, .uv = 0 } }, sent[0]);
    // Pressed again before the display answers: fixed where the noise puts it.
    const by_noise: f32 = @floatCast(@as(f64, t.cfg.thresholds.sigmas) * -t.det.units[9].sigma() * 0.195);
    _ = t.apply(in, 20);
    sent = try t.thresholdRequests(&got);
    try testing.expectApproxEqRel(by_noise, sent[0].threshold.uv, 1e-5);
    // Once the display has answered (and the hold is over), from what `Config` says.
    t.answer(9, sent[0].threshold.uv);
    _ = t.apply(in, 1000);
    sent = try t.thresholdRequests(&got);
    try testing.expectEqual(0, sent[0].threshold.uv);
    t.answer(9, 0);
    _ = t.apply(in, 2000);
    sent = try t.thresholdRequests(&got);
    try testing.expectApproxEqRel(by_noise, sent[0].threshold.uv, 1e-5);
}

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

test "the report: every electrode's threshold in µV, published when it changes" {
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
    // The first report goes out at once, with all 48 electrodes' thresholds (the AUX and
    // ADC channels have none), each the detector's in µV: here following the noise, so
    // negative.
    t.view.publish(&sink, &t.det, 0);
    try testing.expectEqual(1, sink.count);
    try testing.expectEqual(48, sink.last.thresholds.len);
    try testing.expectEqual(null, sink.last.thresholds.get(48));
    for (0..48) |ch| {
        const want: f32 = @floatCast(t.det.threshold(ch) * 0.195);
        try testing.expect(want < 0);
        try testing.expectEqual(want, sink.last.thresholds.get(ch).?);
    }
    t.view.publish(&sink, &t.det, 1);
    try testing.expectEqual(1, sink.count);
    // A threshold moving with the noise: at most every 100 ms.
    t.det.units[4].mad *= 1.01;
    t.view.publish(&sink, &t.det, 50 * ms);
    try testing.expectEqual(1, sink.count);
    t.view.publish(&sink, &t.det, 102 * ms);
    try testing.expectEqual(2, sink.count);
    try testing.expectEqual(@as(f32, @floatCast(t.det.threshold(4) * 0.195)), sink.last.thresholds.get(4).?);
    // A fixed one, as the display's `Config` sets it: reported as it is (rising here).
    t.det.thresholds.set(9, 75);
    t.view.publish(&sink, &t.det, 210 * ms);
    try testing.expectEqual(3, sink.count);
    try testing.expectApproxEqAbs(75, sink.last.thresholds.get(9).?, 1e-4);
    // A change of the view goes out at once.
    t.view.scale.ranges[0] = 99;
    t.view.publish(&sink, &t.det, 211 * ms);
    try testing.expectEqual(4, sink.count);
    try testing.expectEqual(99, sink.last.view.range_uv[0]);
    try testing.expectEqual(null, sink.last.view.port);
}

test "the display's thresholds reach the detector with its config" {
    const shared = try testing.allocator.create(Shared);
    defer testing.allocator.destroy(shared);
    shared.* = .{};
    var det = try spikes.Detector.init(testing.allocator, test_fs, 8);
    defer det.deinit();
    var cfg: Config = .{};
    var seen: u32 = 0;
    try testing.expect(!takeConfig(shared, &cfg, &seen, &det));
    var sent: Config = .{};
    sent.thresholds.sigmas = 5.5;
    sent.thresholds.set(3, -80);
    shared.publish(&sent);
    try testing.expect(takeConfig(shared, &cfg, &seen, &det));
    try testing.expectEqual(5.5, det.thresholds.sigmas);
    try testing.expectEqual(-80, det.thresholds.fixed_uv[3]);
    try testing.expectEqual(@as(f64, -80) / 0.195, det.threshold(3));
    // Nothing new: nothing changes.
    det.thresholds = .{};
    try testing.expect(!takeConfig(shared, &cfg, &seen, &det));
    try testing.expect(!det.thresholds.isFixed(3));
}

// ---- What the tile window draws ----
//
// A stored-output test, as the display's and the control window's: `draw` is run on a
// few states with the hand-made font, and everything it puts into the batch is written
// out in order as text (rectangles; runs of waveform segments joined end to end, with
// their colour and width; runs of text) and compared with `testdata/tiles_draw.txt`. Set
// DIMNA_TILES_DRAW_OUT to a path to write what this run produced there. The detectors are
// fed `testSample`: noise on every channel, spikes of four sizes on channels 4, 9, 40, 70.

const draw_states = [_][]const u8{
    "all auto, no focus",
    "a common range of 150 µV, one tile 400 µV",
    "focus on A1-5, A1-5 and A1-10 listened to, the pointer over A1-10",
    "port A only, two ports",
    "three headstages on two ports, port A",
    "a small window, port B: no room for the range or the rate",
    "64 + 16 electrodes",
    "fixed thresholds: A1-5 at -52 µV (range 400 µV), A1-10 at +80 µV, a wide window",
    "a drag on A1-10, 20 px below its line; A1-5 fixed at -52 µV, no room for its range",
};

const DrawState = struct {
    layout: dimna.types.Layout,
    cfg: Config = .{},
    view: View = .{},
    width: f32 = 1000,
    height: f32 = 700,
    mouse: [2]f32 = .{ -1, -1 },
};

fn drawState(st: *DrawState, k: usize) void {
    const three = [_][2]usize{ .{ 0, 32 }, .{ 1, 16 }, .{ 2, 16 } };
    const big = [_][2]usize{ .{ 0, 64 }, .{ 2, 16 } };
    st.* = .{ .layout = testLayout(switch (k) {
        4 => &three,
        6 => &big,
        else => &two_ports,
    }) };
    var start: link.TileView = .{};
    switch (k) {
        1, 2 => {
            @memset(start.range_uv[0..48], 150);
            if (k == 1) start.range_uv[4] = 400;
        },
        3, 4 => start.port = 0,
        5 => {
            start.port = 1;
            @memset(start.range_uv[32..48], 150);
        },
        6 => {
            start.range_uv[4] = 250;
            start.range_uv[70] = 1500;
        },
        7, 8 => start.range_uv[4] = 400,
        else => {},
    }
    st.view.init(&st.layout, &start);
    if (k == 2) {
        st.cfg.focus = 4;
        st.cfg.listening[0] = 4;
        st.cfg.listening[1] = 9;
        st.cfg.num_listening = 2;
        // Tile 9: 48 tiles of 125 x 112 in 8 columns, so column 1 of row 1.
        st.mouse = .{ 130, 120 };
    }
    if (k == 5) {
        st.width = 400;
        st.height = 300;
    }
    if (k == 6) {
        st.width = 1600;
        st.height = 900;
        st.cfg.focus = 70;
    }
    if (k == 7 or k == 8) st.cfg.thresholds.set(4, -52);
    if (k == 7) {
        st.cfg.thresholds.set(9, 80);
        st.width = 1600;
        st.height = 900;
    }
}

/// State 8's drag: a press on A1-10's red line and a move 20 px down, as `View.apply`
/// takes them (the pointer stays there, over the tile).
fn dragForState(st: *DrawState, det: *const spikes.Detector) void {
    const face = testFont();
    const scene: Scene = .{
        .det = det,
        .layout = &st.layout,
        .cfg = &st.cfg,
        .view = &st.view,
        .face = &face,
        .width = st.width,
        .height = st.height,
        .max_waves = wavesShown(max_vertices, st.view.num_shown, det.len),
    };
    const grid = tileGrid(st.view.num_shown, &face, st.width, st.height);
    const y = @round(tilePlot(scene, grid, 9).?.yOf(det.threshold(9)));
    var requests: Requests = .{};
    _ = st.view.apply(&.{ .clicks = 1, .left_down = true, .pointer_x = 180, .pointer_y = y }, scene, &requests, 0);
    _ = st.view.apply(&.{ .left_down = true, .pointer_x = 180, .pointer_y = y + 20 }, scene, &requests, 100);
    st.mouse = .{ 180, y + 20 };
}

fn writePoint(w: *std.Io.Writer, x: f32, y: f32) !void {
    try w.print(" {d:.2},{d:.2}", .{ x, y });
}

/// Writes the batch's quads in order. Returns the counts of rectangles, waveform runs and
/// text runs; with `w` null, only counts.
fn writeDrawn(w: ?*std.Io.Writer, verts: []const font.Vertex) ![3]usize {
    var counts: [3]usize = @splat(0);
    const quads = verts.len / 6;
    var q: usize = 0;
    while (q < quads) {
        const v = verts[q * 6 ..][0..6];
        const col = v[0].colour;
        if (v[0].uv[0] * font.atlas_size >= 8) {
            // A run of glyphs on one row, of one colour, 8 pixels apart.
            counts[2] += 1;
            if (w) |out| try out.print("text {d} {d} {any} \"", .{ v[0].pos[0], v[0].pos[1], col });
            var next_x = v[0].pos[0];
            while (q < quads) : (q += 1) {
                const g = verts[q * 6 ..][0..6];
                const gu = g[0].uv[0] * font.atlas_size;
                if (gu < 8 or g[0].pos[0] != next_x or g[0].pos[1] != v[0].pos[1] or !std.mem.eql(u8, &g[0].colour, &col)) break;
                var utf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(testCodepoint(@intFromFloat(gu - 8)), &utf) catch unreachable;
                if (w) |out| try out.writeAll(utf[0..n]);
                next_x += 8;
            }
            if (w) |out| try out.writeAll("\"\n");
            continue;
        }
        const is_rect = v[1].pos[1] == v[0].pos[1] and v[5].pos[0] == v[0].pos[0] and
            v[2].pos[0] >= v[0].pos[0] and v[2].pos[1] >= v[0].pos[1];
        if (is_rect) {
            counts[0] += 1;
            const size: [2]f32 = .{ v[2].pos[0] - v[0].pos[0], v[2].pos[1] - v[0].pos[1] };
            if (w) |out| try out.print("rect {d} {d} {d} {d} {any}\n", .{ v[0].pos[0], v[0].pos[1], size[0], size[1], col });
            q += 1;
            continue;
        }
        // A line: from the middle of its start edge (v0, v5) to that of its end (v1, v2).
        // Segments that continue one another, in one colour and width, are one run.
        counts[1] += 1;
        const width = std.math.hypot(v[0].pos[0] - v[5].pos[0], v[0].pos[1] - v[5].pos[1]);
        if (w) |out| {
            try out.print("wave {any} {d:.2}:", .{ col, width });
            try writePoint(out, (v[0].pos[0] + v[5].pos[0]) / 2, (v[0].pos[1] + v[5].pos[1]) / 2);
        }
        var end: [2]f32 = .{ (v[1].pos[0] + v[2].pos[0]) / 2, (v[1].pos[1] + v[2].pos[1]) / 2 };
        if (w) |out| try writePoint(out, end[0], end[1]);
        q += 1;
        while (q < quads) : (q += 1) {
            const s = verts[q * 6 ..][0..6];
            if (s[0].uv[0] * font.atlas_size >= 8 or !std.mem.eql(u8, &s[0].colour, &col)) break;
            const start: [2]f32 = .{ (s[0].pos[0] + s[5].pos[0]) / 2, (s[0].pos[1] + s[5].pos[1]) / 2 };
            if (@abs(start[0] - end[0]) > 1e-3 or @abs(start[1] - end[1]) > 1e-3) break;
            if (@abs(std.math.hypot(s[0].pos[0] - s[5].pos[0], s[0].pos[1] - s[5].pos[1]) - width) > 1e-3) break;
            end = .{ (s[1].pos[0] + s[2].pos[0]) / 2, (s[1].pos[1] + s[2].pos[1]) / 2 };
            if (w) |out| try writePoint(out, end[0], end[1]);
        }
        if (w) |out| try out.writeByte('\n');
    }
    return counts;
}

fn writeState(w: *std.Io.Writer, name: []const u8, st: *const DrawState, det: *const spikes.Detector, vertices: []font.Vertex) !void {
    const face = testFont();
    var batch: font.Batch = .{ .font = &face, .vertices = vertices };
    draw(&batch, .{
        .det = det,
        .layout = &st.layout,
        .cfg = &st.cfg,
        .view = &st.view,
        .face = &face,
        .width = st.width,
        .height = st.height,
        .mouse_x = st.mouse[0],
        .mouse_y = st.mouse[1],
        .max_waves = wavesShown(vertices.len, st.view.num_shown, det.len),
    });
    // A full batch drops quads silently: the comparison would then miss them.
    try testing.expect(batch.len + 6 <= vertices.len);
    const counts = try writeDrawn(null, batch.vertices[0..batch.len]);
    try w.print("== {s}: {d} rects, {d} waveform runs, {d} text runs\n", .{ name, counts[0], counts[1], counts[2] });
    _ = try writeDrawn(w, batch.vertices[0..batch.len]);
}

test "what the tile window draws is unchanged" {
    const gpa = testing.allocator;
    const vertices = try gpa.alloc(font.Vertex, max_vertices);
    defer gpa.free(vertices);
    const st = try gpa.create(DrawState);
    defer gpa.destroy(st);
    // One detector per layout, fed 2.5 s.
    var dets: [3]?spikes.Detector = @splat(null);
    defer for (&dets) |*d| if (d.*) |*x| x.deinit();

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (draw_states, 0..) |name, k| {
        drawState(st, k);
        const which: usize = switch (k) {
            4 => 1,
            6 => 2,
            else => 0,
        };
        if (dets[which] == null) dets[which] = try testDetector(&st.layout, 2.5);
        // As `takeConfig` does: the detector's thresholds are `Config`'s.
        dets[which].?.thresholds = st.cfg.thresholds;
        if (k == 8) dragForState(st, &dets[which].?);
        try writeState(&out.writer, name, st, &dets[which].?, vertices);
    }
    const got = out.written();
    if (std.c.getenv("DIMNA_TILES_DRAW_OUT")) |path| {
        const file = try std.Io.Dir.cwd().createFile(testing.io, std.mem.span(path), .{});
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, got);
    }
    try testing.expectEqualStrings(@embedFile("testdata/tiles_draw.txt"), got);
}
