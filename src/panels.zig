//! The panels of the neural display: rectangles of one fullscreen surface, each showing a run
//! of channels with its own time base and vertical scale. Laid out from the config file:
//!
//!   [[panel]]
//!   name = "Port B"
//!   source = "B1"                 # a headstage (A1..D2), "electrodes", "aux" or "adc"
//!   rect = [0.0, 0.0, 0.5, 1.0]   # x, y, width, height as fractions of the display
//!   span_s = 2.0                  # optional: time across the panel
//!   scale = 400                   # optional: µV per row (V per row for aux and adc)
//!
//! With no [[panel]] in the config there is one panel per headstage, side by side.

const std = @import("std");
const types = @import("types.zig");
const toml = @import("toml.zig");

pub const max_panels = 16;

pub const Kind = enum { electrode, aux, adc };

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

    pub fn unit(self: *const Panel) []const u8 {
        return if (self.kind == .electrode) "uV" else "V";
    }

    pub const span_min = 0.05;
    pub const span_max = 20.0;

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
        self.span_s = std.math.clamp(self.span_s, span_min, span_max);
        self.scale = std.math.clamp(self.scale, lim[0], lim[1]);
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

/// One panel per headstage, side by side in headstage order.
pub fn default(layout: *const types.Layout) Set {
    var set: Set = .{};
    const n = @min(layout.num_headstages, max_panels);
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
        };
        p.setName(types.headstage_names[h.slot]);
        set.items[i] = p;
    }
    set.len = n;
    return set;
}

/// The panels of the config (`[[panel]]` tables), or the default layout if it has none.
pub fn fromConfig(doc: toml.Document, layout: *const types.Layout) Error!Set {
    const count = doc.count("panel");
    if (count == 0) return default(layout);
    if (count > max_panels) return fail("{d} panels; at most {d}", .{ count, max_panels });
    var set: Set = .{};
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
        };
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
