//! The panels of the neural display: rectangles of one fullscreen surface, each showing a run
//! of channels with its own time base and vertical scale. Laid out from the config file:
//!
//!   [[panel]]
//!   name = "Port B"
//!   source = "B1"                 # a headstage (A1..D2), "electrodes", "aux" or "adc"
//!   rect = [0.0, 0.0, 0.5, 1.0]   # x, y, width, height as fractions of the display
//!   span_s = 2.0                  # optional: time across the panel
//!   scale = 400                   # optional: µV per row (V per row for aux and adc)
//!   mode = "sweep"                # optional: see `Mode`; a top-level `mode` sets all panels
//!   trigger = 2                   # optional, with mode = "triggered": the TTL input line
//!   pre_ms = 10                   # optional: time shown before the trigger
//!   post_ms = 40                  # optional: and after it
//!   sweeps = 10                   # optional: how many sweeps are overlaid
//!   band = [300, 6000]            # optional, electrodes: show band-passed, corners in Hz
//!                                 # (0 leaves a side out: [10, 0] is a 10 Hz high-pass)
//!
//! With no [[panel]] in the config there is one panel per headstage, side by side.

const std = @import("std");
const types = @import("types.zig");
const toml = @import("toml.zig");

pub const max_panels = 16;

pub const Kind = enum { electrode, aux, adc };

/// How a panel shows time. `scroll` (the default): the newest sample is at the right edge
/// and the traces move left. `sweep`: the traces stand still and a cursor moves left to
/// right, overwriting the previous pass (as oers and the stock LFP viewer draw).
/// `triggered`: the panel shows the stretch of signal around each rising edge of a TTL
/// input line, the last few overlaid with the newest brightest (for opto-tagging: the
/// laser's TTL as the trigger).
pub const Mode = enum { scroll, sweep, triggered };

pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

pub const Panel = struct {
    name_buf: [32]u8 = undefined,
    name_len: usize = 0,
    /// Position and size as fractions of the display.
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    kind: Kind,
    /// First channel (index into a sample) and how many: one row each.
    first_ch: u32,
    rows: u32,
    /// Time across the panel, s.
    span_s: f64,
    /// Units per row: µV for electrodes, V for aux and adc.
    scale: f64,
    mode: Mode = .scroll,
    /// Triggered mode: the TTL input line (1-based), the window around the trigger in ms,
    /// and how many sweeps are overlaid.
    trig_line: u8 = 2,
    pre_ms: f64 = 10,
    post_ms: f64 = 40,
    overlay: u32 = 10,
    /// Display filter (electrodes only; never applied to what is recorded): whether the
    /// panel shows its channels band-passed, and the band's corners in Hz (0 = that side
    /// off). 4th-order Butterworth each side, see `dsp.Band`.
    filtered: bool = false,
    band_low_hz: f64 = 300,
    band_high_hz: f64 = 6000,
    /// Where the band-passed copy of the panel's channels is in a row of the display's
    /// sample history (set by `feed.Feed.init`).
    slot: u32 = 0,

    pub fn name(self: *const Panel) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// Physical units per stored LSB, in the panel's unit (µV or V).
    pub fn unitsPerLsb(self: *const Panel) f64 {
        return switch (self.kind) {
            .electrode => types.electrode_uv_per_bit,
            .aux => types.aux_v_per_bit,
            .adc => types.adc_v_per_bit,
        };
    }

    /// The first history column the panel draws: its filtered copy or its channels.
    pub fn drawColumn(self: *const Panel) u32 {
        return if (self.filtered and self.kind == .electrode) self.slot else self.first_ch;
    }

    /// The corners offered when stepping with keys (0 = that side off).
    pub const low_corners = [_]f64{ 0, 1, 3, 10, 30, 100, 300, 600, 1000 };
    pub const high_corners = [_]f64{ 100, 300, 1000, 3000, 6000, 10000, 0 };

    /// Moves the low (`high` false) or high corner one step up or down its list, keeping
    /// the high corner above the low one.
    pub fn stepCorner(self: *Panel, high: bool, up: bool) void {
        const list: []const f64 = if (high) &high_corners else &low_corners;
        const cur = if (high) self.band_high_hz else self.band_low_hz;
        // "Off" is the bottom of the low list and the top of the high list.
        const rank = struct {
            fn f(v: f64, is_high: bool) f64 {
                return if (v == 0 and is_high) std.math.inf(f64) else v;
            }
        }.f;
        var next = cur;
        if (up) {
            for (list) |v| {
                if (rank(v, high) > rank(cur, high)) {
                    next = v;
                    break;
                }
            }
        } else {
            for (list) |v| {
                if (rank(v, high) < rank(cur, high)) next = v;
            }
        }
        if (high) {
            if (next != 0 and next <= self.band_low_hz) return;
            self.band_high_hz = next;
        } else {
            if (self.band_high_hz != 0 and next >= self.band_high_hz) return;
            self.band_low_hz = next;
        }
    }

    pub fn unit(self: *const Panel) []const u8 {
        return if (self.kind == .electrode) "uV" else "V";
    }

    pub const span_min = 0.05;
    pub const span_max = 20.0;
    /// In sweep mode a column can be up to two spans old, and the sample history on the
    /// GPU holds `span_max` + 2 s at least.
    pub const sweep_span_max = 10.0;

    pub fn scaleLimits(self: *const Panel) [2]f64 {
        return if (self.kind == .electrode) .{ 5.0, 20000.0 } else .{ 0.001, 20.0 };
    }

    pub fn defaultScale(kind: Kind) f64 {
        return switch (kind) {
            .electrode => 400.0,
            // AUX is stored about its 1.2255 V mid-point and spans ±1.2 V; the ADCs span ±5 V.
            .aux => 1.0,
            .adc => 5.0,
        };
    }

    pub fn clamp(self: *Panel) void {
        const lim = self.scaleLimits();
        const longest: f64 = if (self.mode == .sweep) sweep_span_max else span_max;
        self.span_s = std.math.clamp(self.span_s, span_min, longest);
        self.scale = std.math.clamp(self.scale, lim[0], lim[1]);
        self.pre_ms = std.math.clamp(self.pre_ms, 0, 1000);
        self.post_ms = std.math.clamp(self.post_ms, 1, 2000);
        self.overlay = std.math.clamp(self.overlay, 1, @import("sweeps.zig").max_sweeps);
        self.trig_line = std.math.clamp(self.trig_line, 1, 8);
    }

    /// The panel's rectangle in pixels on a display of `width` x `height`. Neighbouring
    /// panels share edges exactly (both round the same fraction).
    pub fn pixelRect(self: *const Panel, width: u32, height: u32) Rect {
        const fw: f64 = @floatFromInt(width);
        const fh: f64 = @floatFromInt(height);
        const x0: u32 = @intFromFloat(@round(self.x * fw));
        const y0: u32 = @intFromFloat(@round(self.y * fh));
        const x1: u32 = @intFromFloat(@round((self.x + self.w) * fw));
        const y1: u32 = @intFromFloat(@round((self.y + self.h) * fh));
        return .{ .x = x0, .y = y0, .w = @max(x1, x0 + 1) - x0, .h = @max(y1, y0 + 1) - y0 };
    }

    fn setName(self: *Panel, text: []const u8) void {
        self.name_len = @min(text.len, self.name_buf.len);
        @memcpy(self.name_buf[0..self.name_len], text[0..self.name_len]);
    }
};

pub const Set = struct {
    items: [max_panels]Panel = undefined,
    len: usize = 0,

    pub fn slice(self: *Set) []Panel {
        return self.items[0..self.len];
    }

    /// The panel under a point given as fractions of the display; the last one listed wins
    /// where panels overlap (it is drawn on top).
    pub fn at(self: *const Set, fx: f64, fy: f64) ?usize {
        var i = self.len;
        while (i > 0) {
            i -= 1;
            const p = &self.items[i];
            if (fx >= p.x and fx < p.x + p.w and fy >= p.y and fy < p.y + p.h) return i;
        }
        return null;
    }
};

pub const Error = error{BadPanel};

/// What was wrong with the config, after `error.BadPanel`.
pub var error_message_buf: [200]u8 = undefined;
pub var error_message: []const u8 = "";

fn fail(comptime fmt: []const u8, args: anytype) Error {
    error_message = std.fmt.bufPrint(&error_message_buf, fmt, args) catch "bad panel";
    return error.BadPanel;
}

const Source = struct { kind: Kind, first: usize, rows: usize };

fn resolve(source: []const u8, layout: *const types.Layout) ?Source {
    if (std.ascii.eqlIgnoreCase(source, "electrodes")) return .{ .kind = .electrode, .first = 0, .rows = layout.num_electrodes };
    if (std.ascii.eqlIgnoreCase(source, "aux")) return .{ .kind = .aux, .first = layout.num_electrodes, .rows = layout.num_aux };
    if (std.ascii.eqlIgnoreCase(source, "adc")) return .{ .kind = .adc, .first = layout.num_electrodes + layout.num_aux, .rows = layout.num_adc };
    for (layout.headstageSlice()) |h| {
        if (std.ascii.eqlIgnoreCase(source, types.headstage_names[h.slot])) return .{ .kind = .electrode, .first = h.first_channel, .rows = h.num_channels };
    }
    return null;
}

/// The mode of the panels of the default layout (set from a top-level `mode`).
var default_mode: Mode = .scroll;

/// One panel per headstage, side by side in headstage order.
pub fn default(layout: *const types.Layout) Set {
    var set: Set = .{};
    const n = @min(layout.num_headstages, max_panels);
    const mode = default_mode;
    for (layout.headstageSlice()[0..n], 0..) |h, i| {
        var p: Panel = .{
            .x = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)),
            .y = 0,
            .w = 1.0 / @as(f64, @floatFromInt(n)),
            .h = 1,
            .kind = .electrode,
            .first_ch = @intCast(h.first_channel),
            .rows = @intCast(h.num_channels),
            .span_s = 2.0,
            .scale = Panel.defaultScale(.electrode),
            .mode = mode,
        };
        p.setName(types.headstage_names[h.slot]);
        set.items[i] = p;
    }
    set.len = n;
    return set;
}

fn parseMode(value: ?toml.Value, what: []const u8, n: usize) Error!?Mode {
    const v = value orelse return null;
    if (v == .string) {
        if (std.meta.stringToEnum(Mode, v.string)) |m| return m;
    }
    return if (n == 0) fail("{s} must be \"scroll\", \"sweep\" or \"triggered\"", .{what}) else fail("{s} {d}: mode must be \"scroll\", \"sweep\" or \"triggered\"", .{ what, n });
}

/// The panels of the config (`[[panel]]` tables), or the default layout if it has none.
pub fn fromConfig(doc: toml.Document, layout: *const types.Layout) Error!Set {
    const count = doc.count("panel");
    if (count == 0) {
        default_mode = (try parseMode(doc.get("", 0, "mode"), "mode", 0)) orelse .scroll;
        return default(layout);
    }
    if (count > max_panels) return fail("{d} panels; at most {d}", .{ count, max_panels });
    var set: Set = .{};
    const all_mode = try parseMode(doc.get("", 0, "mode"), "mode", 0);
    for (0..count) |i| {
        const source = doc.string("panel", i, "source") orelse return fail("panel {d}: no source (a headstage such as \"A1\", \"electrodes\", \"aux\" or \"adc\")", .{i + 1});
        const src = resolve(source, layout) orelse return fail("panel {d}: source \"{s}\" is not a connected headstage, \"electrodes\", \"aux\" or \"adc\"", .{ i + 1, source });
        if (src.rows == 0) return fail("panel {d}: source \"{s}\" has no channels (aux and adc must be acquired)", .{ i + 1, source });
        const rect = doc.numbers("panel", i, "rect") orelse return fail("panel {d}: no rect = [x, y, width, height]", .{i + 1});
        if (rect.len != 4) return fail("panel {d}: rect needs 4 numbers, has {d}", .{ i + 1, rect.len });
        if (rect[0] < 0 or rect[1] < 0 or rect[2] <= 0 or rect[3] <= 0 or rect[0] + rect[2] > 1.0001 or rect[1] + rect[3] > 1.0001)
            return fail("panel {d}: rect [{d}, {d}, {d}, {d}] is not inside the display (fractions 0..1)", .{ i + 1, rect[0], rect[1], rect[2], rect[3] });
        var p: Panel = .{
            .x = rect[0],
            .y = rect[1],
            .w = @min(rect[2], 1.0 - rect[0]),
            .h = @min(rect[3], 1.0 - rect[1]),
            .kind = src.kind,
            .first_ch = @intCast(src.first),
            .rows = @intCast(src.rows),
            .span_s = doc.number("panel", i, "span_s") orelse 2.0,
            .scale = doc.number("panel", i, "scale") orelse Panel.defaultScale(src.kind),
            .mode = (try parseMode(doc.get("panel", i, "mode"), "panel", i + 1)) orelse all_mode orelse .scroll,
        };
        if (doc.number("panel", i, "trigger")) |v| {
            if (v < 1 or v > 8 or v != @floor(v)) return fail("panel {d}: trigger is a TTL input line, 1 to 8", .{i + 1});
            p.trig_line = @intFromFloat(v);
        }
        if (doc.number("panel", i, "pre_ms")) |v| p.pre_ms = v;
        if (doc.number("panel", i, "post_ms")) |v| p.post_ms = v;
        if (doc.number("panel", i, "sweeps")) |v| p.overlay = @intFromFloat(std.math.clamp(v, 1, 1000));
        if (doc.get("panel", i, "band")) |v| {
            const band: []const f64 = if (v == .numbers) v.numbers else &.{};
            if (band.len != 2 or band[0] < 0 or band[1] < 0 or (band[1] != 0 and band[1] <= band[0]))
                return fail("panel {d}: band needs [low, high] in Hz, low below high (0 leaves a side out)", .{i + 1});
            if (src.kind != .electrode) return fail("panel {d}: band is for electrodes; aux and adc are drawn as they are", .{i + 1});
            p.filtered = true;
            p.band_low_hz = band[0];
            p.band_high_hz = band[1];
        }
        p.setName(doc.string("panel", i, "name") orelse source);
        p.clamp();
        set.items[i] = p;
    }
    set.len = count;
    return set;
}

const testing = std.testing;

fn testLayout() types.Layout {
    var l: types.Layout = .{ .sample_rate = 30000, .hw_clock_hz = 50e6 };
    l.headstages[0] = .{ .slot = 0, .chip = "RHD2132", .num_channels = 16, .first_channel = 0, .has_bno = false };
    l.headstages[1] = .{ .slot = 2, .chip = "RHD2216", .num_channels = 16, .first_channel = 16, .has_bno = false };
    l.num_headstages = 2;
    l.num_electrodes = 32;
    l.num_aux = 6;
    l.num_adc = 8;
    return l;
}

test "default layout: one panel per headstage, side by side" {
    const l = testLayout();
    var set = default(&l);
    try testing.expectEqual(2, set.len);
    try testing.expectEqualStrings("A1", set.items[0].name());
    try testing.expectEqualStrings("B1", set.items[1].name());
    try testing.expectEqual(16, set.items[1].first_ch);
    // The two panels tile a 1921-pixel-wide display without a gap or an overlap.
    const a = set.items[0].pixelRect(1921, 1080);
    const b = set.items[1].pixelRect(1921, 1080);
    try testing.expectEqual(0, a.x);
    try testing.expectEqual(a.x + a.w, b.x);
    try testing.expectEqual(1921, b.x + b.w);
    try testing.expectEqual(0, set.at(0.25, 0.5).?);
    try testing.expectEqual(1, set.at(0.75, 0.5).?);
    try testing.expectEqual(null, set.at(1.5, 0.5));
}

test "panels from the config" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const l = testLayout();
    const doc = try toml.parse(arena_state.allocator(),
        \\[[panel]]
        \\name = "Port B"
        \\source = "b1"
        \\rect = [0, 0, 0.5, 0.75]
        \\span_s = 0.5
        \\[[panel]]
        \\source = "A1"
        \\rect = [0.5, 0, 0.5, 0.75]
        \\scale = 100000
        \\[[panel]]
        \\source = "adc"
        \\rect = [0, 0.75, 1, 0.25]
    );
    var set = try fromConfig(doc, &l);
    try testing.expectEqual(3, set.len);
    const p = set.slice();
    try testing.expectEqualStrings("Port B", p[0].name());
    try testing.expectEqual(16, p[0].first_ch);
    try testing.expectEqual(0.5, p[0].span_s);
    try testing.expectEqualStrings("A1", p[1].name());
    try testing.expectEqual(20000, p[1].scale); // clamped
    try testing.expectEqual(Kind.adc, p[2].kind);
    try testing.expectEqual(38, p[2].first_ch);
    try testing.expectEqual(8, p[2].rows);
    try testing.expectEqual(5.0, p[2].scale);
    try testing.expectEqualStrings("V", p[2].unit());
    try testing.expectEqual(2, set.at(0.3, 0.9).?);
    try testing.expectEqual(Mode.scroll, p[0].mode);
}

test "band: from the config, and stepped by keys" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const l = testLayout();
    var set = try fromConfig(try toml.parse(a,
        \\[[panel]]
        \\source = "A1"
        \\rect = [0, 0, 0.5, 1]
        \\band = [10, 0]
        \\[[panel]]
        \\source = "B1"
        \\rect = [0.5, 0, 0.5, 1]
    ), &l);
    const p = &set.items[0];
    try testing.expect(p.filtered);
    try testing.expectEqual(10, p.band_low_hz);
    try testing.expectEqual(0, p.band_high_hz);
    try testing.expect(!set.items[1].filtered);
    try testing.expectEqual(300, set.items[1].band_low_hz);
    p.stepCorner(false, true);
    try testing.expectEqual(30, p.band_low_hz);
    p.stepCorner(true, false); // from off down to the top of the list
    try testing.expectEqual(10000, p.band_high_hz);
    p.band_high_hz = 100;
    p.stepCorner(false, true); // 100 would meet the high corner: refused
    try testing.expectEqual(30, p.band_low_hz);
    p.stepCorner(true, false); // already the lowest
    try testing.expectEqual(100, p.band_high_hz);
    p.band_low_hz = 1;
    p.stepCorner(false, false);
    try testing.expectEqual(0, p.band_low_hz);
    try testing.expectError(error.BadPanel, fromConfig(try toml.parse(a, "[[panel]]\nsource = \"A1\"\nrect = [0,0,1,1]\nband = [6000, 300]"), &l));
    try testing.expectError(error.BadPanel, fromConfig(try toml.parse(a, "[[panel]]\nsource = \"adc\"\nrect = [0,0,1,1]\nband = [1, 100]"), &l));
    try testing.expect(std.mem.indexOf(u8, error_message, "electrodes") != null);
}

test "triggered panels from the config" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const l = testLayout();
    var set = try fromConfig(try toml.parse(a,
        \\[[panel]]
        \\source = "A1"
        \\rect = [0, 0, 0.5, 1]
        \\mode = "triggered"
        \\trigger = 3
        \\pre_ms = 2
        \\post_ms = 5000
        \\sweeps = 100
        \\[[panel]]
        \\source = "B1"
        \\rect = [0.5, 0, 0.5, 1]
        \\mode = "triggered"
    ), &l);
    const p = &set.items[0];
    try testing.expectEqual(Mode.triggered, p.mode);
    try testing.expectEqual(3, p.trig_line);
    try testing.expectEqual(2, p.pre_ms);
    try testing.expectEqual(2000, p.post_ms); // clamped
    try testing.expectEqual(32, p.overlay); // clamped
    try testing.expectEqual(2, set.items[1].trig_line);
    try testing.expectEqual(10, set.items[1].pre_ms);
    try testing.expectEqual(40, set.items[1].post_ms);
    try testing.expectError(error.BadPanel, fromConfig(try toml.parse(a, "[[panel]]\nsource = \"A1\"\nrect = [0,0,1,1]\ntrigger = 9"), &l));
}

test "sweep mode: per panel or for all, with a shorter longest time base" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const l = testLayout();
    var set = try fromConfig(try toml.parse(a,
        \\mode = "sweep"
        \\[[panel]]
        \\source = "A1"
        \\rect = [0, 0, 0.5, 1]
        \\span_s = 18
        \\[[panel]]
        \\source = "B1"
        \\rect = [0.5, 0, 0.5, 1]
        \\mode = "scroll"
        \\span_s = 18
    ), &l);
    try testing.expectEqual(Mode.sweep, set.items[0].mode);
    try testing.expectEqual(Panel.sweep_span_max, set.items[0].span_s);
    try testing.expectEqual(Mode.scroll, set.items[1].mode);
    try testing.expectEqual(18, set.items[1].span_s);
    set = try fromConfig(try toml.parse(a, "mode = \"sweep\""), &l);
    try testing.expectEqual(Mode.sweep, set.items[0].mode);
    try testing.expectError(error.BadPanel, fromConfig(try toml.parse(a, "[[panel]]\nsource = \"A1\"\nrect = [0,0,1,1]\nmode = \"wipe\""), &l));
    try testing.expect(std.mem.indexOf(u8, error_message, "sweep") != null);
}

test "config mistakes are explained" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var l = testLayout();
    try testing.expectError(error.BadPanel, fromConfig(try toml.parse(a, "[[panel]]\nsource = \"C1\"\nrect = [0,0,1,1]"), &l));
    try testing.expect(std.mem.indexOf(u8, error_message, "C1") != null);
    try testing.expectError(error.BadPanel, fromConfig(try toml.parse(a, "[[panel]]\nsource = \"A1\"\nrect = [0.6,0,0.5,1]"), &l));
    try testing.expectError(error.BadPanel, fromConfig(try toml.parse(a, "[[panel]]\nsource = \"A1\""), &l));
    l.num_adc = 0;
    try testing.expectError(error.BadPanel, fromConfig(try toml.parse(a, "[[panel]]\nsource = \"adc\"\nrect = [0,0,1,1]"), &l));
    try testing.expect(std.mem.indexOf(u8, error_message, "acquired") != null);
}
