//! What of the spike-tile window is kept in the view file: which port's tiles are shown,
//! and each tile's vertical range. It is the tile window's to change and the display
//! thread's to save, so it is plain data that crosses between them whole.
//!
//! In views.toml:
//!
//!   [tiles]
//!   port = "A"                 # "A" to "D", or "all"
//!   range_uv = [150, 150, 0]   # per electrode, in order: µV from zero to the tile's
//!                              # edge; 0 = that tile scales itself to its waveforms

const std = @import("std");
const toml = @import("toml.zig");

pub const max_tiles = 512;

pub const TileView = struct {
    /// The port whose tiles are shown (0 = A ... 3 = D), or null for all.
    port: ?u8 = null,
    /// µV from zero to the tile's edge, per electrode; 0 = the tile scales itself.
    range_uv: [max_tiles]f32 = @splat(0),

    /// Reads the `[tiles]` table of a view file. Anything missing or wrong keeps its
    /// default: an old or hand-edited file must not stop the program.
    pub fn read(doc: toml.Document) TileView {
        var v: TileView = .{};
        if (doc.string("tiles", 0, "port")) |name| {
            if (name.len == 1 and std.ascii.toUpper(name[0]) >= 'A' and std.ascii.toUpper(name[0]) <= 'D')
                v.port = std.ascii.toUpper(name[0]) - 'A';
        }
        if (doc.numbers("tiles", 0, "range_uv")) |list| {
            for (list, 0..) |x, i| {
                if (i < max_tiles and x > 0 and x < 1e6) v.range_uv[i] = @floatCast(x);
            }
        }
        return v;
    }

    /// Writes the `[tiles]` table for `n` electrodes.
    pub fn render(self: *const TileView, w: *std.Io.Writer, n: usize) !void {
        try w.writeAll("\n[tiles]\nport = \"");
        if (self.port) |p| try w.writeByte('A' + p) else try w.writeAll("all");
        try w.writeAll("\"\nrange_uv = [");
        for (self.range_uv[0..@min(n, max_tiles)], 0..) |r, i| {
            if (i > 0) try w.writeAll(", ");
            // To a hundredth of a µV: a range that went through the wheel is not a round
            // number, and seven digits of it say nothing.
            try w.print("{d}", .{@round(@as(f64, r) * 100) / 100});
        }
        try w.writeAll("]\n");
    }

    pub fn eql(a: *const TileView, b: *const TileView) bool {
        return a.port == b.port and std.mem.eql(f32, &a.range_uv, &b.range_uv);
    }
};

const testing = std.testing;

test "the tile view is written and read back the same" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var v: TileView = .{ .port = 1 };
    v.range_uv[0] = 150;
    v.range_uv[2] = 87.5;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try v.render(&w, 4);
    try testing.expectEqualStrings("\n[tiles]\nport = \"B\"\nrange_uv = [150, 0, 87.5, 0]\n", w.buffered());
    const back = TileView.read(try toml.parse(arena_state.allocator(), w.buffered(), null));
    try testing.expect(back.eql(&v));
    // All ports; and a file without the table, or with nonsense in it, gives the defaults.
    v.port = null;
    w = .fixed(&buf);
    try v.render(&w, 1);
    try testing.expect(TileView.read(try toml.parse(arena_state.allocator(), w.buffered(), null)).port == null);
    const none: TileView = .{};
    try testing.expect(TileView.read(try toml.parse(arena_state.allocator(), "", null)).eql(&none));
    const odd = TileView.read(try toml.parse(arena_state.allocator(), "[tiles]\nport = \"Q\"\nrange_uv = [-5, 1e9, 40]", null));
    try testing.expect(odd.port == null);
    try testing.expectEqual(0, odd.range_uv[0]);
    try testing.expectEqual(0, odd.range_uv[1]);
    try testing.expectEqual(40, odd.range_uv[2]);
}
