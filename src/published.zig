//! A value that one thread publishes and other threads read without a lock.
//!
//! The writer bumps a sequence counter before and after it copies the value in, so the
//! counter is odd while a write is under way and even when the value is whole. A reader
//! notes the counter, copies the value out, and looks at the counter again: if it was odd,
//! or changed in between, the writer was in the middle and the copy may be torn (half old,
//! half new), so the reader throws it away and tries again. Only a copy taken while the
//! counter stood still at an even value is handed out.
//!
//! The reader never waits for the writer: it gives up after a bounded number of tries and
//! keeps what it had; the next `read` will pick the value up. The writer never waits at all.
//! There is one writer; there may be several readers, each with its own `seen`.

const std = @import("std");
const Atomic = std.atomic.Value;
const clock = @import("clock.zig");

pub fn Published(comptime T: type) type {
    return struct {
        const Self = @This();

        seq: Atomic(u32) = .init(0),
        value: T = .{},

        /// Writer: makes `v` the current value.
        pub fn publish(self: *Self, v: *const T) void {
            _ = self.seq.fetchAdd(1, .acq_rel); // odd: being written
            self.value = v.*;
            _ = self.seq.fetchAdd(1, .release);
        }

        /// Reader: copies the current value into `out` if it is newer than `seen` (which is
        /// updated; start it at 0, which means "nothing seen yet"). False if there is nothing
        /// new, or if no whole copy could be taken in 100 tries (`out` is then unchanged).
        pub fn read(self: *Self, out: *T, seen: *u32) bool {
            var tries: usize = 0;
            while (tries < 100) : (tries += 1) {
                const before = self.seq.load(.acquire);
                if (before == seen.*) return false;
                if (before & 1 != 0) {
                    std.atomic.spinLoopHint();
                    continue;
                }
                const copy = self.value;
                if (self.seq.load(.acquire) != before) continue;
                out.* = copy;
                seen.* = before;
                return true;
            }
            return false;
        }
    };
}

const testing = std.testing;

test "a value published is read back, and only once" {
    const V = struct { a: u32 = 0, b: f64 = 0 };
    var p: Published(V) = .{};
    var out: V = .{};
    var seen: u32 = 0;
    // Nothing has been published yet.
    try testing.expect(!p.read(&out, &seen));
    p.publish(&.{ .a = 7, .b = 2.5 });
    try testing.expect(p.read(&out, &seen));
    try testing.expectEqual(7, out.a);
    try testing.expectEqual(2.5, out.b);
    // Nothing new since.
    out = .{};
    try testing.expect(!p.read(&out, &seen));
    try testing.expectEqual(0, out.a);
    // A newer value is seen; a second reader with its own `seen` gets it too.
    p.publish(&.{ .a = 8, .b = 3 });
    try testing.expect(p.read(&out, &seen));
    try testing.expectEqual(8, out.a);
    var out2: V = .{};
    var seen2: u32 = 0;
    try testing.expect(p.read(&out2, &seen2));
    try testing.expectEqual(8, out2.a);
}

test "a reader never sees a torn value" {
    // Large enough that copying it takes many stores and loads.
    const V = struct { f: [256]u64 = @splat(0) };
    const Ctx = struct {
        p: Published(V) = .{},
        stop: Atomic(bool) = .init(false),

        fn write(self: *@This()) void {
            var v: V = .{};
            var n: u64 = 0;
            while (!self.stop.load(.acquire)) {
                n += 1;
                v.f = @splat(n);
                self.p.publish(&v);
            }
        }
    };
    const ctx = try testing.allocator.create(Ctx);
    defer testing.allocator.destroy(ctx);
    ctx.* = .{};
    const writer = try std.Thread.spawn(.{}, Ctx.write, .{ctx});
    var out: V = .{};
    var seen: u32 = 0;
    var reads: usize = 0;
    var torn: usize = 0;
    var last: u64 = 0;
    // A fixed time rather than a number of reads: with the writer never pausing, many
    // reads give up (see `read`), and how many depends on the machine.
    const until = clock.nowNs() + 500 * std.time.ns_per_ms;
    while (clock.nowNs() < until) {
        if (!ctx.p.read(&out, &seen)) continue;
        reads += 1;
        for (out.f) |x| {
            if (x != out.f[0]) {
                torn += 1;
                break;
            }
        }
        // Values only go forward.
        if (out.f[0] < last) torn += 1;
        last = out.f[0];
    }
    ctx.stop.store(true, .release);
    writer.join();
    try testing.expectEqual(0, torn);
    // Enough whole reads that a torn one would have had its chances.
    try testing.expect(reads >= 10);
}
