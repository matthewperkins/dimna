//! Single-producer ring of preallocated blocks with up to `max_consumers` readers. The
//! producer (acquisition thread) fills a slot in place and commits it; every attached reader
//! sees every block, reads it in place and releases it. A slot is reused only after all
//! attached readers released it. A reader that fails (e.g. the recorder on a disk error)
//! detaches, so it can never stall acquisition. No allocation and no locks after `init`.

const std = @import("std");
const Block = @import("types.zig").Block;
const Atomic = std.atomic.Value;

pub const max_consumers = 4;

const Tail = struct {
    pos: Atomic(usize) align(std.atomic.cache_line) = .init(0),
    attached: Atomic(bool) = .init(false),
};

pub const BlockRing = struct {
    slots: []Block,
    mask: usize,
    /// Next slot the producer commits (monotonic, wraps via `mask`).
    head: Atomic(usize) align(std.atomic.cache_line) = .init(0),
    tails: [max_consumers]Tail = @splat(.{}),
    num_consumers: usize = 0,

    /// `n_slots` is rounded up to a power of two.
    pub fn init(gpa: std.mem.Allocator, n_slots: usize, num_channels: usize, block_samples: usize) !BlockRing {
        const n = std.math.ceilPowerOfTwo(usize, @max(n_slots, 2)) catch return error.OutOfMemory;
        const slots = try gpa.alloc(Block, n);
        var made: usize = 0;
        errdefer {
            for (slots[0..made]) |*b| b.deinit(gpa);
            gpa.free(slots);
        }
        for (slots) |*b| {
            b.* = try Block.init(gpa, num_channels, block_samples);
            // Touch every page now, so the hot path never takes a first-use page fault.
            @memset(b.data, 0);
            @memset(b.hw_time, 0);
            @memset(b.ttl, 0);
            made += 1;
        }
        return .{ .slots = slots, .mask = n - 1 };
    }

    pub fn deinit(self: *BlockRing, gpa: std.mem.Allocator) void {
        for (self.slots) |*b| b.deinit(gpa);
        gpa.free(self.slots);
    }

    pub fn capacity(self: *const BlockRing) usize {
        return self.slots.len;
    }

    /// Registers a reader starting at the current head. Call before the producer starts.
    pub fn addConsumer(self: *BlockRing) usize {
        std.debug.assert(self.num_consumers < max_consumers);
        const id = self.num_consumers;
        self.num_consumers += 1;
        self.tails[id].pos.store(self.head.load(.acquire), .release);
        self.tails[id].attached.store(true, .release);
        return id;
    }

    /// Stops reader `id` from holding slots back. It must not read afterwards.
    pub fn detach(self: *BlockRing, id: usize) void {
        self.tails[id].attached.store(false, .release);
    }

    /// Blocks committed but not yet released by reader `id`.
    pub fn backlog(self: *const BlockRing, id: usize) usize {
        return self.head.load(.acquire) -% self.tails[id].pos.load(.acquire);
    }

    // ---- producer ----
    /// The slot to fill next, or null if some attached reader still holds it.
    pub fn writeSlot(self: *BlockRing) ?*Block {
        const h = self.head.load(.monotonic);
        for (self.tails[0..self.num_consumers]) |*t| {
            if (t.attached.load(.acquire) and h -% t.pos.load(.acquire) >= self.slots.len) return null;
        }
        return &self.slots[h & self.mask];
    }
    pub fn commit(self: *BlockRing) void {
        _ = self.head.fetchAdd(1, .release);
    }

    // ---- reader `id` ----
    /// Its oldest unreleased block, or null if it has seen everything.
    pub fn readSlot(self: *BlockRing, id: usize) ?*const Block {
        const t = self.tails[id].pos.load(.monotonic);
        if (self.head.load(.acquire) == t) return null;
        return &self.slots[t & self.mask];
    }
    pub fn release(self: *BlockRing, id: usize) void {
        _ = self.tails[id].pos.fetchAdd(1, .release);
    }
};

/// A reader that never holds the producer back (for displays): it copies each block out and
/// then checks that the producer did not start reusing the slot meanwhile. When it has fallen
/// a whole ring behind it skips ahead and counts the blocks it lost. Not registered with the
/// ring, so any number may exist; each belongs to one thread.
pub const LossyReader = struct {
    ring: *BlockRing,
    /// Position of the next block to read (same numbering as the ring's head).
    pos: usize,
    lost: u64 = 0,

    /// Starts at the newest block.
    pub fn init(ring: *BlockRing) LossyReader {
        return .{ .ring = ring, .pos = ring.head.load(.acquire) };
    }

    /// Copies the next block into `out` (which must have the ring's block shape). Returns
    /// false when there is nothing new.
    pub fn next(self: *LossyReader, out: *Block) bool {
        const cap = self.ring.slots.len;
        while (true) {
            const h = self.ring.head.load(.acquire);
            if (self.pos == h) return false;
            // The producer fills the slot of position p + cap while head == p + cap, so
            // position p is intact only while head - p < cap.
            if (h -% self.pos >= cap) {
                const to = h -% cap / 2;
                self.lost += to -% self.pos;
                self.pos = to;
                continue;
            }
            const src = &self.ring.slots[self.pos & self.ring.mask];
            // These may be torn if the slot is being rewritten; the check below rejects that
            // case, the clamp keeps the copy in bounds meanwhile.
            const n = @min(src.len, src.capacity, out.capacity);
            out.first_sample = src.first_sample;
            out.acquired_ns = src.acquired_ns;
            out.len = n;
            @memcpy(out.data[0 .. n * out.num_channels], src.data[0 .. n * out.num_channels]);
            @memcpy(out.hw_time[0..n], src.hw_time[0..n]);
            @memcpy(out.ttl[0..n], src.ttl[0..n]);
            if (self.ring.head.load(.acquire) -% self.pos >= cap) continue; // overwritten: skip ahead
            self.pos +%= 1;
            return true;
        }
    }
};

const testing = std.testing;

test "lossy reader follows, and skips ahead when a ring behind" {
    var r = try BlockRing.init(testing.allocator, 4, 1, 1);
    defer r.deinit(testing.allocator);
    var out = try Block.init(testing.allocator, 1, 1);
    defer out.deinit(testing.allocator);
    var rd = LossyReader.init(&r);
    try testing.expect(!rd.next(&out));
    // No gating reader is attached, so the producer never waits.
    for (0..3) |i| {
        const b = r.writeSlot().?;
        b.first_sample = @intCast(i);
        b.len = 1;
        r.commit();
    }
    for (0..3) |i| {
        try testing.expect(rd.next(&out));
        try testing.expectEqual(@as(i64, @intCast(i)), out.first_sample);
    }
    try testing.expect(!rd.next(&out));
    for (3..13) |i| {
        const b = r.writeSlot().?;
        b.first_sample = @intCast(i);
        b.len = 1;
        r.commit();
    }
    // Ten blocks behind a ring of four: jumps to two behind the head (position 11).
    try testing.expect(rd.next(&out));
    try testing.expectEqual(@as(i64, 11), out.first_sample);
    try testing.expectEqual(@as(u64, 8), rd.lost);
    try testing.expect(rd.next(&out));
    try testing.expectEqual(@as(i64, 12), out.first_sample);
    try testing.expect(!rd.next(&out));
}

test "lossy reader never returns a torn block while the producer laps it" {
    const nch = 8;
    const bs = 16;
    var r = try BlockRing.init(testing.allocator, 4, nch, bs);
    defer r.deinit(testing.allocator);
    const n_blocks = 300_000;
    const Producer = struct {
        fn run(ring: *BlockRing) void {
            var i: i64 = 0;
            while (i < n_blocks) : (i += 1) {
                const b = ring.writeSlot().?;
                b.first_sample = i;
                b.len = bs;
                // Every value in the block is derived from its number.
                @memset(b.data, @truncate(i));
                @memset(b.ttl, @truncate(@as(u64, @intCast(i))));
                ring.commit();
            }
        }
    };
    var out = try Block.init(testing.allocator, nch, bs);
    defer out.deinit(testing.allocator);
    var rd = LossyReader.init(&r);
    const t = try std.Thread.spawn(.{}, Producer.run, .{&r});
    var got: u64 = 0;
    var last: i64 = -1;
    var torn: u64 = 0;
    while (last < n_blocks - 1) {
        if (!rd.next(&out)) {
            if (r.head.load(.acquire) == n_blocks and rd.pos == n_blocks) break;
            std.atomic.spinLoopHint();
            continue;
        }
        got += 1;
        if (out.first_sample <= last or out.len != bs) torn += 1;
        last = out.first_sample;
        const want: i16 = @truncate(out.first_sample);
        for (out.data) |v| {
            if (v != want) {
                torn += 1;
                break;
            }
        }
        for (out.ttl) |v| {
            if (v != @as(u16, @truncate(@as(u64, @intCast(out.first_sample))))) {
                torn += 1;
                break;
            }
        }
    }
    t.join();
    try testing.expectEqual(@as(u64, 0), torn);
    try testing.expect(got > 0);
    try testing.expectEqual(@as(u64, n_blocks), got + rd.lost);
}

test "ring preserves order and reports full and empty" {
    var r = try BlockRing.init(testing.allocator, 3, 2, 4);
    defer r.deinit(testing.allocator);
    const c = r.addConsumer();
    try testing.expectEqual(4, r.capacity());
    try testing.expectEqual(null, r.readSlot(c));
    for (0..4) |i| {
        const b = r.writeSlot().?;
        b.first_sample = @intCast(i);
        r.commit();
    }
    try testing.expectEqual(null, r.writeSlot());
    for (0..10) |i| {
        const b = r.readSlot(c).?;
        try testing.expectEqual(@as(i64, @intCast(i)), b.first_sample);
        r.release(c);
        const w = r.writeSlot().?;
        w.first_sample = @intCast(i + 4);
        r.commit();
    }
    try testing.expectEqual(4, r.backlog(c));
}

test "slowest reader gates the producer; a detached reader does not" {
    var r = try BlockRing.init(testing.allocator, 2, 1, 1);
    defer r.deinit(testing.allocator);
    const fast = r.addConsumer();
    const slow = r.addConsumer();
    for (0..2) |_| {
        _ = r.writeSlot().?;
        r.commit();
    }
    while (r.readSlot(fast)) |_| r.release(fast);
    try testing.expectEqual(null, r.writeSlot()); // slow still holds both
    r.detach(slow);
    try testing.expect(r.writeSlot() != null);
}

test "ring hands blocks across threads in order to two readers" {
    var r = try BlockRing.init(testing.allocator, 8, 1, 1);
    defer r.deinit(testing.allocator);
    const a = r.addConsumer();
    const b = r.addConsumer();
    const n = 200_000;
    const Producer = struct {
        fn run(ring: *BlockRing) void {
            var i: i64 = 0;
            while (i < n) {
                if (ring.writeSlot()) |blk| {
                    blk.first_sample = i;
                    blk.data[0] = @truncate(i);
                    ring.commit();
                    i += 1;
                } else std.atomic.spinLoopHint();
            }
        }
    };
    const Reader = struct {
        fn run(ring: *BlockRing, id: usize, ok: *bool) void {
            var expect: i64 = 0;
            while (expect < n) {
                if (ring.readSlot(id)) |blk| {
                    if (blk.first_sample != expect or blk.data[0] != @as(i16, @truncate(expect))) ok.* = false;
                    ring.release(id);
                    expect += 1;
                } else std.atomic.spinLoopHint();
            }
        }
    };
    var ok_a = true;
    var ok_b = true;
    const tp = try std.Thread.spawn(.{}, Producer.run, .{&r});
    const tb = try std.Thread.spawn(.{}, Reader.run, .{ &r, b, &ok_b });
    Reader.run(&r, a, &ok_a);
    tp.join();
    tb.join();
    try testing.expect(ok_a and ok_b);
}
