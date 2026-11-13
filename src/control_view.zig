//! Which sections of the control window are open. It is the control window's to change and
//! the display thread's to save, so it is plain data that crosses between them whole.
//! Panels are kept by name: after a restart the panels are made again, and a panel keeps
//! its place in the list only by its name.
//!
//! In views.toml:
//!
//!   [control]
//!   notes = false
//!   audio = true
//!   headstages = false
//!   panels = "Port A\nPort B"   # the names of the panels open, one per line

const std = @import("std");
const toml = @import("toml.zig");
const panels = @import("panels.zig");

pub const max_panels = panels.max_panels;
pub const max_name = @typeInfo(@FieldType(panels.Panel, "name_buf")).array.len;

pub const ControlView = struct {
    notes: bool = false,
    audio: bool = false,
    headstages: bool = false,
    /// The names of the panels open (the first `num_panels`), in the order they were
    /// opened.
    names: [max_panels][max_name]u8 = @splat(@splat(0)),
    name_lens: [max_panels]u8 = @splat(0),
    num_panels: usize = 0,

    pub fn name(self: *const ControlView, k: usize) []const u8 {
        return self.names[k][0..self.name_lens[k]];
    }

    fn find(self: *const ControlView, panel_name: []const u8) ?usize {
        for (0..self.num_panels) |k| {
            if (std.mem.eql(u8, self.name(k), panel_name)) return k;
        }
        return null;
    }

    /// The panel called `panel_name` is open.
    pub fn panelOpen(self: *const ControlView, panel_name: []const u8) bool {
        return self.find(panel_name) != null;
    }

    /// Opens or closes the panel called `panel_name`. A name too long, or one more than
    /// `max_panels` names, is not kept (the panel stays closed).
    pub fn setPanel(self: *ControlView, panel_name: []const u8, open: bool) void {
        if (self.find(panel_name)) |k| {
            if (open) return;
            for (k..self.num_panels - 1) |j| {
                self.names[j] = self.names[j + 1];
                self.name_lens[j] = self.name_lens[j + 1];
            }
            self.num_panels -= 1;
            self.names[self.num_panels] = @splat(0);
            self.name_lens[self.num_panels] = 0;
        } else if (open and panel_name.len <= max_name and self.num_panels < max_panels) {
            @memcpy(self.names[self.num_panels][0..panel_name.len], panel_name);
            self.name_lens[self.num_panels] = @intCast(panel_name.len);
            self.num_panels += 1;
        }
    }

    /// Reads the `[control]` table of a view file. Anything missing or wrong keeps its
    /// default (closed): an old or hand-edited file must not stop the program.
    pub fn read(doc: toml.Document) ControlView {
        var v: ControlView = .{};
        v.notes = doc.boolean("control", 0, "notes") orelse false;
        v.audio = doc.boolean("control", 0, "audio") orelse false;
        v.headstages = doc.boolean("control", 0, "headstages") orelse false;
        if (doc.string("control", 0, "panels")) |list| {
            var it = std.mem.splitScalar(u8, list, '\n');
            while (it.next()) |panel_name| {
                if (panel_name.len > 0) v.setPanel(panel_name, true);
            }
        }
        return v;
    }

    /// Writes the `[control]` table.
    pub fn render(self: *const ControlView, w: *std.Io.Writer) !void {
        try w.print("\n[control]\nnotes = {}\naudio = {}\nheadstages = {}\npanels = \"", .{ self.notes, self.audio, self.headstages });
        for (0..self.num_panels) |k| {
            if (k > 0) try w.writeAll("\\n");
            // A name is a TOML basic string: quotes, backslashes and line ends escaped.
            for (self.name(k)) |c| switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\t' => try w.writeAll("\\t"),
                else => try w.writeByte(c),
            };
        }
        try w.writeAll("\"\n");
    }

    /// The same sections and the same panels open (in whatever order).
    pub fn eql(a: *const ControlView, b: *const ControlView) bool {
        if (a.notes != b.notes or a.audio != b.audio or a.headstages != b.headstages) return false;
        if (a.num_panels != b.num_panels) return false;
        for (0..a.num_panels) |k| {
            if (!b.panelOpen(a.name(k))) return false;
        }
        return true;
    }
};

const testing = std.testing;

test "panels open and close by name" {
    var v: ControlView = .{};
    try testing.expect(!v.panelOpen("Port A"));
    v.setPanel("Port A", true);
    v.setPanel("Port B", true);
    v.setPanel("Port A", true);
    try testing.expectEqual(2, v.num_panels);
    try testing.expect(v.panelOpen("Port A") and v.panelOpen("Port B"));
    try testing.expect(!v.panelOpen("Port"));
    // Closing one keeps the others, in order.
    v.setPanel("Port A", false);
    try testing.expectEqual(1, v.num_panels);
    try testing.expectEqualStrings("Port B", v.name(0));
    v.setPanel("Port C", false);
    try testing.expectEqual(1, v.num_panels);
    // The order does not matter to `eql`; the sections do.
    var w: ControlView = .{};
    w.setPanel("Port C", true);
    w.setPanel("Port B", true);
    v.setPanel("Port C", true);
    try testing.expect(v.eql(&w) and w.eql(&v));
    w.notes = true;
    try testing.expect(!v.eql(&w));
    // A name longer than a panel's name is not kept; nor more names than there are panels.
    v = .{};
    v.setPanel(&@as([max_name + 1]u8, @splat('x')), true);
    try testing.expectEqual(0, v.num_panels);
    for (0..max_panels + 2) |k| {
        var buf: [8]u8 = undefined;
        v.setPanel(try std.fmt.bufPrint(&buf, "p{d}", .{k}), true);
    }
    try testing.expectEqual(max_panels, v.num_panels);
}

test "what is open is written as the [control] table and read back the same" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var v: ControlView = .{ .audio = true };
    v.setPanel("Port A", true);
    v.setPanel("say \"hi\" \\ there", true);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try v.render(&w);
    try testing.expectEqualStrings(
        "\n[control]\nnotes = false\naudio = true\nheadstages = false\npanels = \"Port A\\nsay \\\"hi\\\" \\\\ there\"\n",
        w.buffered(),
    );
    const back = ControlView.read(try toml.parse(a, w.buffered(), null));
    try testing.expect(back.eql(&v));
    try testing.expectEqualStrings("Port A", back.name(0));
    try testing.expectEqualStrings("say \"hi\" \\ there", back.name(1));
    // Nothing open; a file without the table; nonsense in it: all closed.
    const none: ControlView = .{};
    w = .fixed(&buf);
    try none.render(&w);
    try testing.expectEqualStrings("\n[control]\nnotes = false\naudio = false\nheadstages = false\npanels = \"\"\n", w.buffered());
    try testing.expect(ControlView.read(try toml.parse(a, w.buffered(), null)).eql(&none));
    try testing.expect(ControlView.read(try toml.parse(a, "", null)).eql(&none));
    const odd = ControlView.read(try toml.parse(a, "[control]\nnotes = 1\naudio = \"yes\"\nheadstages = true\npanels = [1, 2]", null));
    try testing.expect(!odd.notes and !odd.audio and odd.headstages and odd.num_panels == 0);
    // Empty lines are no panel; a name too long is left out.
    const too_long: [max_name + 1]u8 = @splat('x');
    const long = "[control]\npanels = \"\\nA\\n\\n" ++ too_long ++ "\\nB\"";
    const some = ControlView.read(try toml.parse(a, long, null));
    try testing.expectEqual(2, some.num_panels);
    try testing.expect(some.panelOpen("A") and some.panelOpen("B"));
}
