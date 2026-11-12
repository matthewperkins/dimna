//! Triggers for triggered-sweep panels: the rising edges of one TTL input line, found in the
//! digital words as blocks arrive, and the most recent ones kept so a panel can overlay the
//! stretches of signal around them.

const std = @import("std");

pub const max_sweeps = 32;

pub const Sweep = struct {
    /// Sample number of the rising edge.
    t0: i64,
    /// Sample number of the falling edge that followed, once seen.
    fall: ?i64 = null,
};

/// The triggers of triggered-sweep panels.
pub const Triggers = List(max_sweeps);
/// The pulses of a line shown as a tint over a panel (many more can be in view).
pub const Pulses = List(512);

pub fn List(comptime cap: usize) type {
    return struct {
        const Self = @This();

        /// TTL line, 1-based (line 1 is bit 0 of the digital word).
        line: u8 = 2,
        /// The last `cap` triggers, oldest first from `head`.
        list: [cap]Sweep = undefined,
        head: usize = 0,
        len: usize = 0,
        /// Triggers seen since `reset`.
        count: u64 = 0,
        high: bool = false,
        started: bool = false,

        pub fn reset(self: *Self, line: u8) void {
            self.* = .{ .line = line };
        }

        /// Looks for edges in the digital words of a block that starts at sample `first`.
        pub fn feed(self: *Self, first: i64, words: []const u16) void {
            if (self.line < 1 or self.line > 16) return;
            const mask = @as(u16, 1) << @intCast(self.line - 1);
            for (words, 0..) |w, i| {
                const high = w & mask != 0;
                if (!self.started) {
                    // A line that is already high when we start looking is not an edge.
                    self.started = true;
                    self.high = high;
                    continue;
                }
                if (high == self.high) continue;
                self.high = high;
                const n = first + @as(i64, @intCast(i));
                if (high) {
                    self.push(n);
                } else if (self.len > 0) {
                    self.list[(self.head + self.len - 1) % cap].fall = n;
                }
            }
        }

        /// Adds a trigger at sample `t0` (from a TTL edge, or a slope trigger).
        pub fn push(self: *Self, t0: i64) void {
            if (self.len == cap) {
                self.head = (self.head + 1) % cap;
                self.len -= 1;
            }
            self.list[(self.head + self.len) % cap] = .{ .t0 = t0 };
            self.len += 1;
            self.count += 1;
        }

        /// The `i`-th most recent trigger (0 = newest), if there are that many.
        pub fn recent(self: *const Self, i: usize) ?Sweep {
            if (i >= self.len) return null;
            return self.list[(self.head + self.len - 1 - i) % cap];
        }
    };
}

const testing = std.testing;

test "rising edges of one line become sweeps, with their falling edges" {
    var t: Triggers = .{ .line = 2 };
    // Line 2 (bit 1) already high at the start: no trigger. Line 1 toggling is ignored.
    t.feed(100, &.{ 2, 3, 2, 0, 1, 0 });
    try testing.expectEqual(0, t.len);
    // Edge split across blocks: low at the end of one, high at the start of the next.
    t.feed(106, &.{ 2, 2, 2 });
    try testing.expectEqual(1, t.len);
    try testing.expectEqual(106, t.recent(0).?.t0);
    try testing.expectEqual(null, t.recent(0).?.fall);
    t.feed(109, &.{ 0, 0, 3, 3, 1 });
    try testing.expectEqual(2, t.len);
    try testing.expectEqual(111, t.recent(0).?.t0);
    try testing.expectEqual(113, t.recent(0).?.fall.?);
    try testing.expectEqual(106, t.recent(1).?.t0);
    try testing.expectEqual(109, t.recent(1).?.fall.?);
    try testing.expectEqual(null, t.recent(2));
}

test "only the last max_sweeps triggers are kept" {
    var t: Triggers = .{ .line = 1 };
    var n: i64 = 0;
    for (0..max_sweeps + 5) |_| {
        t.feed(n, &.{ 0, 1 });
        n += 2;
    }
    try testing.expectEqual(max_sweeps, t.len);
    try testing.expectEqual(max_sweeps + 5, t.count);
    try testing.expectEqual(n - 1, t.recent(0).?.t0);
    try testing.expectEqual(n - 1 - 2 * (max_sweeps - 1), t.recent(max_sweeps - 1).?.t0);
}
