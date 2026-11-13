//! Which sections of the control window are open. It is the control window's to change and
//! the display thread's to save, so it is plain data that crosses between them whole.
//! Panels are kept by name: after a restart the panels are made again, and a panel keeps
//! its place in the list only by its name.

const std = @import("std");
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
