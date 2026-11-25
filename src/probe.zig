//! What is plugged into a headstage, as far as a spike sorter needs to know: which of its
//! channels can see the same unit. In the config file, one table per headstage:
//!
//!   [[probe]]
//!   headstage = "A1"
//!   name = "microwire bundle, 16 wires"   # optional, free text
//!   group = "each"     # "each": every channel alone (wires too far apart to share a
//!                      #         unit, or of unknown geometry: sort each on its own);
//!                      # "all": one group (a shank); a number n: consecutive groups of
//!                      #        n channels (4: tetrodes)
//!
//! A recording's meta.toml then has `[channels] group` (one number per channel) and the
//! `[[probe]]` tables as given. There are no coordinates: a group says what may be sorted
//! together, not where the contacts are.

const std = @import("std");
const types = @import("types.zig");
const toml = @import("toml.zig");

pub const Grouping = union(enum) {
    each,
    all,
    /// Consecutive groups of this many channels (the last may be shorter).
    of: u16,
};

pub const Probe = struct {
    /// Slot 0..8 (A1, A2, B1, … D2).
    slot: usize,
    grouping: Grouping,
    name_buf: [80]u8 = undefined,
    name_len: usize = 0,

    pub fn name(self: *const Probe) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// The probes the config names: at most one per headstage. Holds its own text.
pub const Probes = struct {
    list: [types.headstage_names.len]Probe = undefined,
    len: usize = 0,

    pub fn slice(self: *const Probes) []const Probe {
        return self.list[0..self.len];
    }

    pub fn ofSlot(self: *const Probes, slot: usize) ?*const Probe {
        for (self.slice()) |*p| if (p.slot == slot) return p;
        return null;
    }

    /// Adds a probe; `error.Twice` if the headstage has one.
    pub fn add(self: *Probes, slot: usize, grouping: Grouping, name: []const u8) error{Twice}!void {
        if (self.ofSlot(slot) != null) return error.Twice;
        var p: Probe = .{ .slot = slot, .grouping = grouping };
        p.name_len = @min(name.len, p.name_buf.len);
        @memcpy(p.name_buf[0..p.name_len], name[0..p.name_len]);
        self.list[self.len] = p;
        self.len += 1;
    }

    /// The group of electrode `ch` (an index into the recording's channels): the index of
    /// the first channel of its group, so groups are numbered alike in every recording of
    /// the same layout and never shared between headstages. Null: its headstage has no
    /// probe named, or `ch` is not an electrode.
    pub fn groupOf(self: *const Probes, layout: *const types.Layout, ch: usize) ?usize {
        for (layout.headstageSlice()) |h| {
            if (ch < h.first_channel or ch >= h.first_channel + h.num_channels) continue;
            const p = self.ofSlot(h.slot) orelse return null;
            return switch (p.grouping) {
                .each => ch,
                .all => h.first_channel,
                .of => |n| h.first_channel + (ch - h.first_channel) / n * n,
            };
        }
        return null;
    }
};

pub fn slotOf(name: []const u8) ?usize {
    for (types.headstage_names, 0..) |n, i| {
        if (std.ascii.eqlIgnoreCase(n, name)) return i;
    }
    return null;
}

/// "each", "all" or a number from 1.
pub fn parseGrouping(text: []const u8) ?Grouping {
    if (std.ascii.eqlIgnoreCase(text, "each")) return .each;
    if (std.ascii.eqlIgnoreCase(text, "all")) return .all;
    const n = std.fmt.parseInt(u16, text, 10) catch return null;
    return if (n == 0) null else .{ .of = n };
}

/// What `read` found wrong: a message for the user.
pub const Diagnostics = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diagnostics) []const u8 {
        return self.buf[0..self.len];
    }

    fn fail(self: *Diagnostics, comptime fmt: []const u8, args: anytype) error{BadProbeConfig} {
        const text = std.fmt.bufPrint(&self.buf, fmt, args) catch self.buf[0..0];
        self.len = text.len;
        return error.BadProbeConfig;
    }
};

/// The `[[probe]]` tables of a config. On an error nothing is kept: a recording that says
/// nothing of groups is better than one that says something the user did not write.
pub fn read(doc: toml.Document, diag: *Diagnostics) error{BadProbeConfig}!Probes {
    var out: Probes = .{};
    var index: usize = 0;
    while (true) : (index += 1) {
        var any = false;
        var slot: ?usize = null;
        var grouping: ?Grouping = null;
        var name: []const u8 = "";
        var line: usize = 0;
        for (doc.entries) |e| {
            if (!std.mem.eql(u8, e.table, "probe") or e.index != index) continue;
            any = true;
            line = e.line;
            if (std.mem.eql(u8, e.key, "headstage") and e.value == .string) {
                slot = slotOf(e.value.string) orelse
                    return diag.fail("line {d}: [[probe]] headstage '{s}' is not a headstage (A1 ... D2)", .{ e.line, e.value.string });
            } else if (std.mem.eql(u8, e.key, "name") and e.value == .string) {
                name = e.value.string;
            } else if (std.mem.eql(u8, e.key, "group") and e.value == .string) {
                grouping = parseGrouping(e.value.string) orelse
                    return diag.fail("line {d}: [[probe]] group '{s}': use \"each\", \"all\" or a number of channels", .{ e.line, e.value.string });
            } else if (std.mem.eql(u8, e.key, "group") and e.value == .number) {
                const v = e.value.number;
                if (v < 1 or v > 64 or v != @floor(v))
                    return diag.fail("line {d}: [[probe]] group {d}: a whole number of channels, 1 to 64", .{ e.line, v });
                grouping = .{ .of = @intFromFloat(v) };
            } else return diag.fail("line {d}: unknown [[probe]] key '{s}' or wrong type", .{ e.line, e.key });
        }
        if (!any) return out;
        const s = slot orelse return diag.fail("line {d}: [[probe]] without headstage = \"A1\" (... \"D2\")", .{line});
        const g = grouping orelse return diag.fail("line {d}: [[probe]] without group = \"each\", \"all\" or a number", .{line});
        out.add(s, g, name) catch return diag.fail("line {d}: two [[probe]] tables for headstage {s}", .{ line, types.headstage_names[s] });
    }
}

const testing = std.testing;

fn layoutOf(slots: []const usize, counts: []const usize) types.Layout {
    var l: types.Layout = .{ .sample_rate = 30000, .hw_clock_hz = 50e6 };
    var first: usize = 0;
    for (slots, counts) |s, n| {
        l.headstages[l.num_headstages] = .{ .slot = s, .chip = "RHD2132", .num_channels = n, .first_channel = first, .has_bno = false };
        l.num_headstages += 1;
        first += n;
    }
    l.num_electrodes = first;
    l.num_adc = 8;
    return l;
}

test "groups: each, all, of n; numbered by their first channel; none without a probe" {
    const l = layoutOf(&.{ 0, 2, 3 }, &.{ 16, 32, 16 });
    var p: Probes = .{};
    try p.add(0, .each, "bundle");
    try p.add(2, .{ .of = 4 }, "tetrodes");
    try testing.expectError(error.Twice, p.add(0, .all, ""));
    try testing.expectEqualStrings("bundle", p.ofSlot(0).?.name());
    // A1, each: every wire its own group.
    try testing.expectEqual(@as(?usize, 0), p.groupOf(&l, 0));
    try testing.expectEqual(@as(?usize, 15), p.groupOf(&l, 15));
    // B1 (channels 16..47), tetrodes.
    try testing.expectEqual(@as(?usize, 16), p.groupOf(&l, 16));
    try testing.expectEqual(@as(?usize, 16), p.groupOf(&l, 19));
    try testing.expectEqual(@as(?usize, 20), p.groupOf(&l, 20));
    try testing.expectEqual(@as(?usize, 44), p.groupOf(&l, 47));
    // B2 has no probe; channel 64 is an ADC input.
    try testing.expectEqual(@as(?usize, null), p.groupOf(&l, 48));
    try testing.expectEqual(@as(?usize, null), p.groupOf(&l, 64));
    var all: Probes = .{};
    try all.add(3, .all, "");
    try testing.expectEqual(@as(?usize, 48), all.groupOf(&l, 48));
    try testing.expectEqual(@as(?usize, 48), all.groupOf(&l, 63));
}

test "[[probe]] tables: read, and what is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    var diag: Diagnostics = .{};
    {
        const doc = try toml.parse(gpa,
            \\[[probe]]
            \\headstage = "a1"
            \\name = "microwire bundle"
            \\group = "each"
            \\[[probe]]
            \\headstage = "B1"
            \\group = 4
        , null);
        const p = try read(doc, &diag);
        try testing.expectEqual(@as(usize, 2), p.len);
        try testing.expectEqual(Grouping.each, p.ofSlot(0).?.grouping);
        try testing.expectEqualStrings("microwire bundle", p.ofSlot(0).?.name());
        try testing.expectEqual(Grouping{ .of = 4 }, p.ofSlot(2).?.grouping);
    }
    const bad = [_]struct { text: []const u8, says: []const u8 }{
        .{ .text = "[[probe]]\nheadstage = \"E1\"\ngroup = \"each\"", .says = "not a headstage" },
        .{ .text = "[[probe]]\nheadstage = \"A1\"", .says = "without group" },
        .{ .text = "[[probe]]\ngroup = \"each\"", .says = "without headstage" },
        .{ .text = "[[probe]]\nheadstage = \"A1\"\ngroup = \"pairs\"", .says = "use \"each\"" },
        .{ .text = "[[probe]]\nheadstage = \"A1\"\ngroup = 0", .says = "whole number" },
        .{ .text = "[[probe]]\nheadstage = \"A1\"\ngroup = \"each\"\nx_um = 3", .says = "unknown [[probe]] key" },
        .{ .text = "[[probe]]\nheadstage = \"A1\"\ngroup = \"each\"\n[[probe]]\nheadstage = \"A1\"\ngroup = \"all\"", .says = "two [[probe]] tables" },
    };
    for (bad) |b| {
        const doc = try toml.parse(gpa, b.text, null);
        try testing.expectError(error.BadProbeConfig, read(doc, &diag));
        if (std.mem.indexOf(u8, diag.message(), b.says) == null) {
            std.debug.print("'{s}' is not in '{s}'\n", .{ b.says, diag.message() });
            return error.TestUnexpectedResult;
        }
    }
}
