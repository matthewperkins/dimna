//! The spike tiles: a window (meant for the other monitor) with one tile per electrode,
//! each showing that channel's last spike waveforms on top of each other, its threshold,
//! its noise and its firing rate. Click a tile to listen to the channel; Ctrl+click adds
//! it to (or takes it out of) what is listened to.
//!
//! Like the control window it is a thread of its own with its own Wayland connection and
//! its own renderer (on the display's Vulkan instance). Here it also does its own work:
//! it reads the acquisition ring with a lossy reader and runs the detector (spikes.zig),
//! so neither the display nor acquisition waits on it, and a hidden tile window costs
//! only the detection. With the display it shares no lock: the display publishes which
//! channels are listened to and the panels' common average references (`Shared.publish`),
//! and clicks go back through a small queue.

const std = @import("std");
const Env = @import("env.zig").Env;
const oez = @import("oez");
const spikes = oez.spikes;
const Window = @import("window.zig").Window;
const gpu_mod = @import("gpu.zig");
const font = @import("font.zig");
const theme = @import("theme.zig");
const format = @import("format.zig");
const Atomic = std.atomic.Value;
const log = std.log.scoped(.tiles);

/// What the tile window needs to know from the display.
pub const Config = struct {
    listening: [oez.audio.max_channels]u32 = @splat(0),
    num_listening: usize = 0,
    /// The panels' common average references, for the detection.
    car: spikes.Car = .{},
    use_car: bool = false,
};

pub const Click = struct { channel: u32, add: bool };

pub const Shared = struct {
    cfg: oez.published.Published(Config) = .{},
    clicks: oez.events.Spsc(Click, 32) = .{},
    stop: Atomic(bool) = .init(false),

    /// Display thread.
    pub fn publish(self: *Shared, cfg: *const Config) void {
        self.cfg.publish(cfg);
    }

    fn read(self: *Shared, out: *Config, seen: *u32) void {
        _ = self.cfg.read(out, seen);
    }
};

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
        const fs = self.layout.sample_rate;

        var reader = oez.ring.LossyReader.init(self.ring);
        var blk = try oez.types.Block.init(gpa, nch, self.block_samples);
        defer blk.deinit(gpa);
        var det = try spikes.Detector.init(gpa, fs, self.layout.num_electrodes);
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
        // Waveforms are many short lines: room for 16 of 47 segments on 64 tiles.
        const max_vertices = 300 * 1024;
        const vertices = try gpa.alloc(font.Vertex, max_vertices);
        defer gpa.free(vertices);
        try gpu.createText(face.atlas, font.atlas_size, max_vertices);
        var batch: font.Batch = .{ .font = &face, .vertices = vertices };

        var cfg: Config = .{};
        var seen: u32 = 0;
        var dirty = true;
        var last_draw: i128 = 0;
        var tag: u64 = 0;
        var pointer: [2]f64 = .{ -1, -1 };
        var script: []const u8 = self.env.tile_clicks;
        const t_start = nowNs();
        while (!shared.stop.load(.acquire) and !win.closed) {
            try win.pump(4);
            // Detection goes on whether or not the window is being shown.
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
            // For tests: OEZ_TILE_CLICKS="SECONDS:X,Y;..." clicks at those pixels (a
            // negative X: with Ctrl, at -X).
            if (script.len > 0) {
                const end = std.mem.indexOfScalar(u8, script, ';') orelse script.len;
                var it = std.mem.tokenizeAny(u8, script[0..end], ":,");
                const at = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
                if (@as(f64, @floatFromInt(nowNs() - t_start)) / 1e9 >= at) {
                    const px = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
                    in.pointer_x = @abs(px);
                    in.pointer_y = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
                    in.ctrl = px < 0;
                    in.clicks += 1;
                    script = script[@min(end + 1, script.len)..];
                }
            }
            if (in.pointer_x != pointer[0] or in.pointer_y != pointer[1] or win.resized) dirty = true;
            pointer = .{ in.pointer_x, in.pointer_y };
            const grid: Grid = .of(det.units.len, @floatFromInt(win.width), @floatFromInt(win.height));
            if (in.clicks > 0) {
                if (grid.at(@floatCast(in.pointer_x), @floatCast(in.pointer_y))) |ch| _ = shared.clicks.push(.{
                    .channel = @intCast(ch),
                    .add = in.ctrl,
                });
            }
            // At most 20 pictures a second: the tiles are for looking at, not for timing.
            const now = nowNs();
            if (!dirty or !win.frame_ready or now - last_draw < 50 * std.time.ns_per_ms) continue;
            if (win.resized or gpu.swapchain == .null) {
                try gpu.resize(win.width, win.height);
                win.resized = false;
            }
            batch.clear();
            draw(
                &batch,
                &det,
                &self.layout,
                &cfg,
                .of(det.units.len, @floatFromInt(gpu.extent.width), @floatFromInt(gpu.extent.height)),
                @floatCast(in.pointer_x),
                @floatCast(in.pointer_y),
            );
            det.changed = false;
            tag += 1;
            const Ctx = struct { win: *Window, tag: u64 };
            const result = try gpu.draw(&.{}, &.{}, batch.vertices[0..batch.len], Ctx{ .win = &win, .tag = tag }, struct {
                fn f(c: Ctx) void {
                    c.win.beforePresent(c.tag);
                }
            }.f);
            switch (result) {
                .presented => {
                    dirty = false;
                    last_draw = now;
                },
                .out_of_date => win.resized = true,
                .busy => {},
            }
        }
        if (win.closed) log.info("spike tile window closed", .{});
    }
};

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

fn draw(
    batch: *font.Batch,
    det: *const spikes.Detector,
    layout: *const oez.types.Layout,
    cfg: *const Config,
    grid: Grid,
    mouse_x: f32,
    mouse_y: f32,
) void {
    const line_h = @round(batch.font.line_height);
    const uv = oez.types.electrode_uv_per_bit;
    const hover = grid.at(mouse_x, mouse_y);
    // Fewer waveforms per tile when there are very many tiles (the vertex budget).
    const per_tile = batch.vertices.len / @max(grid.n, 1) -| 400;
    const max_waves: usize = std.math.clamp(per_tile / ((det.len - 1) * 6), 2, spikes.max_waves);
    for (det.units, 0..) |*u, i| {
        const r = grid.rect(i);
        const x = r[0];
        const y = r[1];
        const w = r[2];
        const h = r[3];
        const listened = std.mem.indexOfScalar(u32, cfg.listening[0..cfg.num_listening], @intCast(i)) != null;
        batch.rect(x, y, w, h, if (hover == i) theme.tile_bg_hover else theme.tile_bg);
        if (listened) {
            // A frame in the colour of the rows listened to on the display.
            batch.rect(x, y, w, 1, theme.heard);
            batch.rect(x, y + h - 1, w, 1, theme.heard);
            batch.rect(x, y, 1, h, theme.heard);
            batch.rect(x + w - 1, y, 1, h, theme.heard);
        }
        // Name and firing rate along the top.
        var buf: [32]u8 = undefined;
        var name_buf: [16]u8 = undefined;
        const name = layout.channelName(&name_buf, i);
        _ = batch.text(x + 5, y + 3, name, if (listened) theme.heard else theme.text_dim);
        if (w > 110) {
            const rate = format.fmt(&buf, "{d:.1} Hz", .{u.rate});
            _ = batch.text(x + w - batch.font.width(rate) - 5, y + 3, rate, theme.text_dim);
        }

        // The waveforms: zero at two fifths of the height, so troughs have the room.
        const top = y + line_h + 6;
        const bottom = y + h - 4;
        if (bottom - top < 12) continue;
        var range: f64 = 8.0 * u.sigma();
        const shown = @min(@as(usize, @intCast(@min(u.wave_count, spikes.max_waves))), max_waves);
        for (0..shown) |k| {
            for (u.wave(k).?[0..det.len]) |v| range = @max(range, 1.15 * @abs(v));
        }
        range = @max(range, 1);
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
            var colour = if (listened) theme.heard else theme.tile_wave;
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
        // The noise, bottom right.
        if (h > 3 * line_h and w > 80) {
            const sigma = format.fmt(&buf, "\u{03C3} {d:.1}", .{u.sigma() * uv});
            _ = batch.text(x + w - batch.font.width(sigma) - 5, y + h - line_h - 2, sigma, theme.text_dim);
        }
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
