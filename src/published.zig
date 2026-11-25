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
//!
//! ## Why a torn copy cannot be accepted, on any CPU
//!
//! Zig has no memory model of its own written down; it compiles atomics to LLVM's, which
//! is C11's. Two things follow. A plain load racing with a plain store is a data race,
//! which is undefined behaviour, so the value is copied in and out one word at a time
//! (`usize`, then single bytes for a tail) with atomic loads and stores, never with plain
//! ones. And Zig 0.17 has no `@fence`, so the ordering cannot come from a fence after the
//! value's loads (the usual C11 form: relaxed loads, `atomic_thread_fence(acquire)`, a
//! relaxed re-read); it is carried by the orderings of the word accesses themselves:
//!
//! - Writer: increment to odd (`monotonic`); every word stored with `release`; increment
//!   to even (`release`). A release store keeps every earlier access of its thread before
//!   it, so each word's store comes after the odd increment, and the even increment after
//!   every word's store.
//! - Reader: `before` loaded with `acquire`; every word loaded with `acquire`; the
//!   sequence re-read (`monotonic`: the acquire loads before it already keep it after
//!   them).
//!
//! Say the reader's `before` is the even value E written at the end of write M (or 0, the
//! initial value). It read E with acquire from that release increment, so all of write M's
//! word stores happen before the reader's word loads, and each load returns write M's word
//! or a later write's (coherence; every write stores every word). Suppose one word came
//! from a later write K. That store was a release, the load an acquire that read it, so
//! write K's odd increment, which precedes that store in the writer, happens before the
//! reader's re-read. The re-read must then return the odd increment of K or a later value
//! of the counter (coherence again), and since only the one writer changes the counter,
//! by increments, that value is not E: the copy is thrown away. So a copy is accepted only
//! when every word is write M's: whole. (The counter wraps at 2^32; a reader would have to
//! stall across 2^31 writes, landing exactly, for a stale E to match. Not guarded.)
//!
//! The version before this one (to 0.2.1) copied with plain loads and stores and had the
//! writer's first increment `acq_rel`, which on arm64 does not keep the later plain stores
//! after it, and the reader's plain loads were not kept before its re-check: a torn copy
//! could be accepted on a weakly ordered CPU. On x86-64 every load is an acquire and every
//! store a release in the hardware, so the word-wise atomics cost nothing more than the
//! loss of a vectorised copy; on arm64 they are `ldar`/`stlr` per word, which is slower
//! but the values here are small and are read once a frame or an audio period.

const std = @import("std");
const Atomic = std.atomic.Value;
const clock = @import("clock.zig");

pub fn Published(comptime T: type) type {
    return struct {
        const Self = @This();
        const word = @sizeOf(usize);
        const n_words = @sizeOf(T) / word;
        const n_tail = @sizeOf(T) % word;

        seq: Atomic(u32) = .init(0),
        /// Touched only through `publish` and `read`, a word at a time with atomics.
        value: T align(@max(@alignOf(T), @alignOf(usize))) = .{},

        /// Writer: makes `v` the current value.
        pub fn publish(self: *Self, v: *const T) void {
            _ = self.seq.fetchAdd(1, .monotonic); // odd: being written
            // `v` may be less aligned than a word; `self.value` is not.
            const src_w: [*]align(1) const usize = @ptrCast(v);
            const dst_w: [*]usize = @ptrCast(&self.value);
            for (0..n_words) |i| @atomicStore(usize, &dst_w[i], src_w[i], .release);
            const src: [*]const u8 = @ptrCast(v);
            const dst_b: [*]u8 = @ptrCast(&self.value);
            for (n_words * word..n_words * word + n_tail) |i| {
                @atomicStore(u8, &dst_b[i], src[i], .release);
            }
            _ = self.seq.fetchAdd(1, .release); // even: whole
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
                var copy: T = undefined;
                const dst_w: [*]align(1) usize = @ptrCast(&copy);
                const src_w: [*]const usize = @ptrCast(&self.value);
                for (0..n_words) |i| dst_w[i] = @atomicLoad(usize, &src_w[i], .acquire);
                const dst: [*]u8 = @ptrCast(&copy);
                const src_b: [*]const u8 = @ptrCast(&self.value);
                for (n_words * word..n_words * word + n_tail) |i| {
                    dst[i] = @atomicLoad(u8, &src_b[i], .acquire);
                }
                if (self.seq.load(.monotonic) != before) continue;
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

test "a value whose size is not a whole number of words is copied whole" {
    // 11 bytes: one word and three bytes on 64-bit targets, two words and three on 32-bit.
    const V = struct { b: [11]u8 = @splat(0) };
    var p: Published(V) = .{};
    var out: V = .{};
    var seen: u32 = 0;
    var v: V = .{};
    for (&v.b, 0..) |*x, k| x.* = @intCast(k + 1);
    p.publish(&v);
    try testing.expect(p.read(&out, &seen));
    try testing.expectEqualSlices(u8, &v.b, &out.b);
}

/// One writer publishing without a pause, one reader checking every copy it is given: all
/// of a copy's elements must be equal (`len` of them, of type `E`), and, when `E` is wide
/// enough not to wrap, values must only go forward.
fn expectNeverTorn(comptime E: type, comptime len: usize) !void {
    const V = struct { f: [len]E = @splat(0) };
    const Ctx = struct {
        p: Published(V) = .{},
        stop: Atomic(bool) = .init(false),

        fn write(self: *@This()) void {
            var v: V = .{};
            var n: u64 = 0;
            while (!self.stop.load(.acquire)) {
                n += 1;
                v.f = @splat(@truncate(n));
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
    var last: E = 0;
    // A fixed time rather than a number of reads: with the writer never pausing, many
    // reads give up (see `read`), and how many depends on the machine.
    // On a busy machine (the tests run beside compiles) the reader may get few whole reads
    // in that time, so it goes on, for at most 20 s, until it has had enough of them.
    const until = clock.nowNs() + 500 * std.time.ns_per_ms;
    const give_up = until + 20 * std.time.ns_per_s;
    while (clock.nowNs() < until or (reads < 10 and clock.nowNs() < give_up)) {
        if (!ctx.p.read(&out, &seen)) continue;
        reads += 1;
        for (out.f) |x| {
            if (x != out.f[0]) {
                torn += 1;
                break;
            }
        }
        // Values only go forward.
        if (@bitSizeOf(E) >= 64 and out.f[0] < last) torn += 1;
        last = out.f[0];
    }
    ctx.stop.store(true, .release);
    writer.join();
    try testing.expectEqual(0, torn);
    // Enough whole reads that a torn one would have had its chances.
    try testing.expect(reads >= 10);
}

test "a reader never sees a torn value" {
    // Large enough that copying it takes many stores and loads.
    try expectNeverTorn(u64, 256);
}

test "a reader never sees a torn value, with a tail of single bytes" {
    // 1027 bytes: whole words and then three bytes, each copied on its own.
    try expectNeverTorn(u8, 1027);
}
