//! Fixed-size single-producer, single-consumer queues, and the events that go into a
//! recording's events.tsv. No allocation.

const std = @import("std");
const Atomic = std.atomic.Value;

pub fn Spsc(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        buf: [capacity]T = undefined,
        head: Atomic(usize) align(std.atomic.cache_line) = .init(0),
        tail: Atomic(usize) align(std.atomic.cache_line) = .init(0),
        /// Pushes refused because the queue was full.
        refused: Atomic(u64) = .init(0),

        pub fn push(self: *Self, v: T) bool {
            const h = self.head.load(.monotonic);
            if (h -% self.tail.load(.acquire) == capacity) {
                _ = self.refused.fetchAdd(1, .monotonic);
                return false;
            }
            self.buf[h % capacity] = v;
            self.head.store(h +% 1, .release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            const t = self.tail.load(.monotonic);
            if (self.head.load(.acquire) == t) return null;
            const v = self.buf[t % capacity];
            self.tail.store(t +% 1, .release);
            return v;
        }
    };
}

/// One events.tsv line: `sample<TAB>kind<TAB>text`.
pub const Event = struct {
    sample: i64,
    kind_buf: [24]u8 = undefined,
    kind_len: u8 = 0,
    text_buf: [232]u8 = undefined,
    text_len: u8 = 0,

    /// Builds an event; `kind` and the formatted text are cut to fit.
    pub fn init(sample: i64, kind_name: []const u8, comptime fmt: []const u8, args: anytype) Event {
        var e: Event = .{ .sample = sample };
        const k = kind_name[0..@min(kind_name.len, e.kind_buf.len)];
        @memcpy(e.kind_buf[0..k.len], k);
        e.kind_len = @intCast(k.len);
        var w: std.Io.Writer = .fixed(&e.text_buf);
        w.print(fmt, args) catch {};
        e.text_len = @intCast(w.buffered().len);
        return e;
    }
    pub fn kind(self: *const Event) []const u8 {
        return self.kind_buf[0..self.kind_len];
    }
    pub fn text(self: *const Event) []const u8 {
        return self.text_buf[0..self.text_len];
    }
};

pub const EventQueue = Spsc(Event, 256);

test "spsc queue keeps order and refuses when full" {
    var q: Spsc(u32, 4) = .{};
    for (0..4) |i| try std.testing.expect(q.push(@intCast(i)));
    try std.testing.expect(!q.push(9));
    try std.testing.expectEqual(1, q.refused.load(.monotonic));
    for (0..4) |i| try std.testing.expectEqual(@as(u32, @intCast(i)), q.pop().?);
    try std.testing.expectEqual(null, q.pop());
}

test "event text is cut to fit" {
    const long: [300]u8 = @splat('x');
    const e = Event.init(5, "amplifier", "{s}", .{&long});
    try std.testing.expectEqual(232, e.text().len);
    try std.testing.expectEqualStrings("amplifier", e.kind());
}
