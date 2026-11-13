//! The board's settings as the config file holds them, the `[board]` table:
//!
//!   [board]
//!   sample_rate = 30000
//!   lower_hz = 1.0             # amplifier bandwidth, set on the headstage chips
//!   upper_hz = 7500
//!   dsp = true                 # the chips' digital high-pass (offset removal)
//!   dsp_cutoff_hz = 0.5
//!   half_channels = "A1"       # RHD2132 headstages wired for 16 channels (comma separated)
//!   aux = false
//!   adc = true
//!   leds = false
//!
//! Reading it into `Settings`, writing it back (replacing only that table in the file's
//! text), a short description of what differs between two settings, and the steps the
//! control window's buttons take through the values the hardware offers.

const std = @import("std");
const types = @import("types.zig");
const toml = @import("toml.zig");
const Settings = types.Settings;

/// What `read` found wrong, for the caller's message. The caller owns it and passes a
/// pointer.
pub const Diagnostics = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,

    /// After `error.BadBoardConfig`, what was wrong with the `[board]` table.
    pub fn message(self: *const Diagnostics) []const u8 {
        return self.buf[0..self.len];
    }

    fn fail(self: *Diagnostics, comptime fmt: []const u8, args: anytype) error{BadBoardConfig} {
        const text = std.fmt.bufPrint(&self.buf, fmt, args) catch blk: {
            const fallback = "bad [board] table";
            @memcpy(self.buf[0..fallback.len], fallback);
            break :blk self.buf[0..fallback.len];
        };
        self.len = text.len;
        return error.BadBoardConfig;
    }
};

pub const sample_rates = [_]u32{ 1000, 1250, 1500, 2000, 2500, 3000, 3333, 5000, 6250, 10000, 12500, 15000, 20000, 25000, 30000 };
pub const lower_steps = [_]f64{ 0.1, 0.3, 1, 3, 10, 30, 100, 300, 500 };
pub const upper_steps = [_]f64{ 100, 300, 1000, 3000, 5000, 7500, 10000, 15000, 20000 };

/// Applies the `[board]` table of `doc` to `s`. After `error.BadBoardConfig`, `diag` says
/// what was wrong.
pub fn read(doc: toml.Document, s: *Settings, diag: *Diagnostics) error{BadBoardConfig}!void {
    for (doc.entries) |e| {
        if (!std.mem.eql(u8, e.table, "board")) continue;
        const k = e.key;
        const is = struct {
            fn f(a: []const u8, b: []const u8) bool {
                return std.mem.eql(u8, a, b);
            }
        }.f;
        if (is(k, "sample_rate") and e.value == .number) {
            const want: u32 = @intFromFloat(std.math.clamp(e.value.number, 0, 1e6));
            if (std.mem.indexOfScalar(u32, &sample_rates, want) == null) return diag.fail("line {d}: sample_rate {d} is not one the board offers (1000 ... 30000)", .{ e.line, want });
            s.sample_rate = want;
        } else if (is(k, "lower_hz") and e.value == .number) {
            s.lower_bandwidth = e.value.number;
        } else if (is(k, "upper_hz") and e.value == .number) {
            s.upper_bandwidth = e.value.number;
        } else if (is(k, "dsp") and e.value == .boolean) {
            s.dsp_enabled = e.value.boolean;
        } else if (is(k, "dsp_cutoff_hz") and e.value == .number) {
            s.dsp_cutoff = e.value.number;
        } else if (is(k, "aux") and e.value == .boolean) {
            s.acquire_aux = e.value.boolean;
        } else if (is(k, "adc") and e.value == .boolean) {
            s.acquire_adc = e.value.boolean;
        } else if (is(k, "leds") and e.value == .boolean) {
            s.leds = e.value.boolean;
        } else if (is(k, "half_channels") and e.value == .string) {
            s.rhd2132_16ch = @splat(false);
            var it = std.mem.tokenizeAny(u8, e.value.string, ", ");
            while (it.next()) |name| {
                const slot = for (types.headstage_names, 0..) |n, i| {
                    if (std.ascii.eqlIgnoreCase(n, name)) break i;
                } else return diag.fail("line {d}: half_channels: '{s}' is not a headstage (A1 ... D2)", .{ e.line, name });
                s.rhd2132_16ch[slot] = true;
            }
        } else return diag.fail("line {d}: unknown [board] key '{s}' or wrong type", .{ e.line, k });
    }
}

fn halfList(buf: []u8, s: *const Settings) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var first = true;
    for (s.rhd2132_16ch, 0..) |on, i| {
        if (!on) continue;
        w.print("{s}{s}", .{ if (first) "" else ",", types.headstage_names[i] }) catch {};
        first = false;
    }
    return w.buffered();
}

/// The `[board]` table for `s`, as text.
pub fn render(buf: []u8, s: *const Settings) []const u8 {
    var half_buf: [40]u8 = undefined;
    return std.fmt.bufPrint(buf,
        \\[board]
        \\sample_rate = {d}
        \\lower_hz = {d}
        \\upper_hz = {d}
        \\dsp = {}
        \\dsp_cutoff_hz = {d}
        \\half_channels = "{s}"
        \\aux = {}
        \\adc = {}
        \\leds = {}
        \\
    , .{ s.sample_rate, s.lower_bandwidth, s.upper_bandwidth, s.dsp_enabled, s.dsp_cutoff, halfList(&half_buf, s), s.acquire_aux, s.acquire_adc, s.leds }) catch "";
}

/// `text` (a config file) with its `[board]` table replaced by `table`, or with `table`
/// added at the end if it has none. Everything else is kept byte for byte.
pub fn replaceTable(gpa: std.mem.Allocator, text: []const u8, table: []const u8) ![]u8 {
    // The table runs from its "[board]" line to the next line that opens a table.
    var start: ?usize = null;
    var end: usize = text.len;
    var pos: usize = 0;
    while (pos < text.len) {
        const eol = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const line = std.mem.trim(u8, text[pos..eol], " \t\r");
        if (start == null) {
            if (std.mem.eql(u8, line, "[board]")) start = pos;
        } else if (line.len > 0 and line[0] == '[') {
            end = pos;
            break;
        }
        pos = @min(eol + 1, text.len);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (start) |s| {
        try out.appendSlice(gpa, text[0..s]);
        try out.appendSlice(gpa, table);
        if (end < text.len) try out.append(gpa, '\n');
        try out.appendSlice(gpa, text[end..]);
    } else {
        try out.appendSlice(gpa, text);
        if (text.len > 0 and text[text.len - 1] != '\n') try out.append(gpa, '\n');
        if (text.len > 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, table);
    }
    return out.toOwnedSlice(gpa);
}

/// Lines of text saying what changed, kept as plain data (it is copied between threads).
pub const Diff = struct {
    pub const max_lines = 12;
    pub const max_len = 64;

    bufs: [max_lines][max_len]u8 = undefined,
    lens: [max_lines]usize = @splat(0),
    count: usize = 0,

    pub fn line(self: *const Diff, i: usize) []const u8 {
        return self.bufs[i][0..self.lens[i]];
    }

    /// Adds a line; one that does not fit (more than `max_len` bytes, or no room left)
    /// is left out.
    pub fn add(self: *Diff, comptime fmt: []const u8, args: anytype) void {
        if (self.count >= max_lines) return;
        const text: []const u8 = std.fmt.bufPrint(&self.bufs[self.count], fmt, args) catch return;
        self.lens[self.count] = text.len;
        self.count += 1;
    }
};

/// One line per setting that differs: "sample_rate  30000 -> 20000".
pub fn diff(old: *const Settings, new: *const Settings) Diff {
    var d: Diff = .{};
    if (old.sample_rate != new.sample_rate) d.add("sample_rate   {d} -> {d}", .{ old.sample_rate, new.sample_rate });
    if (old.lower_bandwidth != new.lower_bandwidth) d.add("lower_hz   {d} -> {d}", .{ old.lower_bandwidth, new.lower_bandwidth });
    if (old.upper_bandwidth != new.upper_bandwidth) d.add("upper_hz   {d} -> {d}", .{ old.upper_bandwidth, new.upper_bandwidth });
    if (old.dsp_enabled != new.dsp_enabled) d.add("dsp   {} -> {}", .{ old.dsp_enabled, new.dsp_enabled });
    if (old.dsp_cutoff != new.dsp_cutoff) d.add("dsp_cutoff_hz   {d:.3} -> {d:.3}", .{ old.dsp_cutoff, new.dsp_cutoff });
    if (!std.mem.eql(bool, &old.rhd2132_16ch, &new.rhd2132_16ch)) {
        var a: [40]u8 = undefined;
        var b: [40]u8 = undefined;
        d.add("half_channels   \"{s}\" -> \"{s}\"", .{ halfList(&a, old), halfList(&b, new) });
    }
    if (old.acquire_aux != new.acquire_aux) d.add("aux   {} -> {}", .{ old.acquire_aux, new.acquire_aux });
    if (old.acquire_adc != new.acquire_adc) d.add("adc   {} -> {}", .{ old.acquire_adc, new.acquire_adc });
    if (old.leds != new.leds) d.add("leds   {} -> {}", .{ old.leds, new.leds });
    return d;
}

/// The neighbour of `current` in `list` (ascending), one step up or down; `current` itself
/// at the ends. `current` need not be in the list.
pub fn step(comptime T: type, list: []const T, current: T, up: bool) T {
    if (up) {
        for (list) |v| {
            if (v > current) return v;
        }
        return list[list.len - 1];
    }
    var best = list[0];
    for (list) |v| {
        if (v < current) best = v;
    }
    return best;
}

/// The chips' DSP high-pass offers 15 cutoffs that scale with the sample rate; `n` is 1
/// (highest) to 15.
pub fn dspCutoff(sample_rate: f64, n: u32) f64 {
    const x = std.math.pow(f64, 2.0, @floatFromInt(n));
    return sample_rate * @log(x / (x - 1.0)) / (2.0 * std.math.pi);
}

/// The DSP cutoff one step above or below `current`.
pub fn stepDsp(sample_rate: f64, current: f64, up: bool) f64 {
    // Nearest offered value first (in log terms, as the chip code chooses).
    var nearest: u32 = 1;
    var best: f64 = std.math.inf(f64);
    for (1..16) |n| {
        const d = @abs(@log10(@max(current, 1e-9)) - @log10(dspCutoff(sample_rate, @intCast(n))));
        if (d < best) {
            best = d;
            nearest = @intCast(n);
        }
    }
    // A larger n is a lower cutoff.
    const n = if (up) @max(nearest, 2) - 1 else @min(nearest + 1, 15);
    return dspCutoff(sample_rate, n);
}

const testing = std.testing;

test "the [board] table is read, rendered and read back the same" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s: Settings = .{};
    var diag: Diagnostics = .{};
    try read(try toml.parse(a,
        \\monitor = "DP-2"
        \\[board]
        \\sample_rate = 20000
        \\lower_hz = 0.3
        \\upper_hz = 10000
        \\dsp = false
        \\half_channels = "a1, B2"
        \\adc = true
        \\[[panel]]
        \\source = "A1"
    , null), &s, &diag);
    try testing.expectEqual(20000, s.sample_rate);
    try testing.expectEqual(0.3, s.lower_bandwidth);
    try testing.expectEqual(10000, s.upper_bandwidth);
    try testing.expect(!s.dsp_enabled);
    try testing.expect(s.rhd2132_16ch[0] and s.rhd2132_16ch[3] and !s.rhd2132_16ch[1]);
    try testing.expect(s.acquire_adc and !s.acquire_aux);

    var buf: [400]u8 = undefined;
    var back: Settings = .{};
    try read(try toml.parse(a, render(&buf, &s), null), &back, &diag);
    try testing.expectEqual(s.sample_rate, back.sample_rate);
    try testing.expectEqual(s.lower_bandwidth, back.lower_bandwidth);
    try testing.expectEqual(s.dsp_cutoff, back.dsp_cutoff);
    try testing.expectEqualSlices(bool, &s.rhd2132_16ch, &back.rhd2132_16ch);
    try testing.expectEqual(s.acquire_adc, back.acquire_adc);

    try testing.expectError(error.BadBoardConfig, read(try toml.parse(a, "[board]\nsample_rate = 44100", null), &back, &diag));
    try testing.expectError(error.BadBoardConfig, read(try toml.parse(a, "[board]\nhalf_channels = \"E1\"", null), &back, &diag));
    try testing.expectError(error.BadBoardConfig, read(try toml.parse(a, "[board]\nspeed = 3", null), &back, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "speed") != null);
}

test "two reads with different errors each report their own message" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s: Settings = .{};
    var first: Diagnostics = .{};
    var second: Diagnostics = .{};
    // The text `parseArgs` logs after "config: ".
    try testing.expectError(error.BadBoardConfig, read(try toml.parse(a, "[board]\nspeed = 3", null), &s, &first));
    try testing.expectError(error.BadBoardConfig, read(try toml.parse(a, "\n\n[board]\nsample_rate = 44100", null), &s, &second));
    try testing.expectEqualStrings("line 2: unknown [board] key 'speed' or wrong type", first.message());
    try testing.expectEqualStrings("line 4: sample_rate 44100 is not one the board offers (1000 ... 30000)", second.message());
    // A message too long for the buffer says only which table.
    try testing.expectError(error.BadBoardConfig, read(try toml.parse(a, "[board]\nhalf_channels = \"" ++ &@as([150]u8, @splat('x')) ++ "\"", null), &s, &first));
    try testing.expectEqualStrings("bad [board] table", first.message());
}

test "replacing the [board] table leaves the rest of the file alone" {
    const gpa = testing.allocator;
    const table = "[board]\nsample_rate = 20000\n";
    // In the middle.
    const a = try replaceTable(gpa, "monitor = \"DP-2\"\n\n[board]\nsample_rate = 30000\nadc = true\n\n[[panel]]\nsource = \"A1\"\n", table);
    defer gpa.free(a);
    try testing.expectEqualStrings("monitor = \"DP-2\"\n\n[board]\nsample_rate = 20000\n\n[[panel]]\nsource = \"A1\"\n", a);
    // At the end.
    const b = try replaceTable(gpa, "x = 1\n[board]\nadc = true", table);
    defer gpa.free(b);
    try testing.expectEqualStrings("x = 1\n[board]\nsample_rate = 20000\n", b);
    // Not there yet, and an empty file.
    const c = try replaceTable(gpa, "x = 1", table);
    defer gpa.free(c);
    try testing.expectEqualStrings("x = 1\n\n[board]\nsample_rate = 20000\n", c);
    const d = try replaceTable(gpa, "", table);
    defer gpa.free(d);
    try testing.expectEqualStrings(table, d);
}

test "diff lists what changed; steps walk the offered values" {
    var old: Settings = .{};
    var new: Settings = .{};
    try testing.expectEqual(0, diff(&old, &new).count);
    new.sample_rate = 20000;
    new.rhd2132_16ch[0] = true;
    new.dsp_enabled = false;
    var d = diff(&old, &new);
    try testing.expectEqual(3, d.count);
    try testing.expectEqualStrings("sample_rate   30000 -> 20000", d.line(0));
    try testing.expectEqualStrings("dsp   true -> false", d.line(1));
    try testing.expectEqualStrings("half_channels   \"\" -> \"A1\"", d.line(2));
    // A line added after, as the quit prompt does; one too long and one too many are
    // left out.
    d.add("panel views", .{});
    try testing.expectEqual(4, d.count);
    try testing.expectEqualStrings("panel views", d.line(3));
    d.add("{s}", .{&@as([Diff.max_len + 1]u8, @splat('x'))});
    try testing.expectEqual(4, d.count);
    for (4..Diff.max_lines) |_| d.add("more", .{});
    d.add("one too many", .{});
    try testing.expectEqual(Diff.max_lines, d.count);
    try testing.expectEqualStrings("more", d.line(Diff.max_lines - 1));
    old = new;

    try testing.expectEqual(25000, step(u32, &sample_rates, 20000, true));
    try testing.expectEqual(30000, step(u32, &sample_rates, 30000, true));
    try testing.expectEqual(3.0, step(f64, &lower_steps, 7.5, false));
    try testing.expectEqual(10000.0, step(f64, &upper_steps, 7500, true));
    // DSP: about 0.58 Hz at 30 kHz is n = 13; one up is n = 12 (1.17 Hz).
    try testing.expectApproxEqAbs(1.166, stepDsp(30000, 0.5, true), 0.01);
    try testing.expectApproxEqAbs(0.291, stepDsp(30000, 0.5, false), 0.01);
    try testing.expectApproxEqAbs(3310.0, stepDsp(30000, 3310, true), 5.0);
}
