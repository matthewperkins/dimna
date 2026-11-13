//! The display's decimated history: beside the ring of samples (history rows), a ring of
//! buckets. A bucket holds, for every history column, the minimum and maximum of
//! `bucket` consecutive samples. The shader draws long time bases from buckets instead of
//! samples, so a pixel column that holds hundreds of samples costs it tens of reads, and
//! the buckets reach back twice as far as the samples in a quarter of the memory.
//!
//! Buckets are aligned to absolute sample numbers: bucket `b` is samples
//! [`b * bucket`, `(b + 1) * bucket`), kept at index `b` modulo the ring's capacity (a
//! power of two). One word per history column: the minimum in the low 16 bits, the maximum
//! in the high, both as int16.
//!
//! The ring is memory on the graphics card that is slow to read back, so nothing here
//! reads it: the bucket being filled is kept in ordinary memory (`open`) and written out
//! whole after every block, which also keeps the newest, partly filled bucket right.

const std = @import("std");

pub const shift = 4;
/// Samples per bucket.
pub const bucket = 1 << shift;

const Range = struct {
    min: i16 = std.math.maxInt(i16),
    max: i16 = std.math.minInt(i16),

    fn fold(self: *Range, v: i16) void {
        self.min = @min(self.min, v);
        self.max = @max(self.max, v);
    }

    fn word(self: Range) u32 {
        return @as(u32, @as(u16, @bitCast(self.min))) | @as(u32, @as(u16, @bitCast(self.max))) << 16;
    }
};

pub fn minOf(word: u32) i16 {
    return @bitCast(@as(u16, @truncate(word)));
}

pub fn maxOf(word: u32) i16 {
    return @bitCast(@as(u16, @truncate(word >> 16)));
}

pub const Ring = struct {
    /// `cap` buckets of `width` words. Written, never read.
    words: []u32 = &.{},
    /// Buckets (a power of two); 0: there is no ring, and everything here does nothing.
    cap: usize = 0,
    width: usize = 0,
    /// The bucket being filled, one range per history column.
    open: []Range = &.{},
    open_bucket: ?i64 = null,

    pub fn init(gpa: std.mem.Allocator, words: []u32, cap: usize, width: usize) !Ring {
        std.debug.assert(std.math.isPowerOfTwo(cap) and words.len == cap * width);
        const open = try gpa.alloc(Range, width);
        @memset(open, .{});
        return .{ .words = words, .cap = cap, .width = width, .open = open };
    }

    pub fn deinit(self: *Ring, gpa: std.mem.Allocator) void {
        gpa.free(self.open);
        self.* = .{};
    }

    fn at(self: *const Ring, b: i64) []u32 {
        const i: usize = @intCast(@as(u64, @bitCast(b)) & (self.cap - 1));
        return self.words[i * self.width ..][0..self.width];
    }

    /// Folds in history rows (`width` values each) from sample number `first` on. Rows that
    /// do not continue the open bucket start a new one (after a gap, the buckets in
    /// between keep what they held, as the sample ring does).
    pub fn add(self: *Ring, first: i64, rows: []const i16) void {
        if (self.cap == 0) return;
        const w = self.width;
        const n = rows.len / w;
        var i: usize = 0;
        while (i < n) {
            const s = first + @as(i64, @intCast(i));
            const b = s >> shift;
            if (self.open_bucket != b) {
                self.open_bucket = b;
                @memset(self.open, .{});
            }
            const left: usize = @intCast(bucket - (s & (bucket - 1)));
            const end = @min(n, i + left);
            for (rows[i * w .. end * w], 0..) |v, k| self.open[k % w].fold(v);
            for (self.at(b), self.open) |*out, r| out.* = r.word();
            i = end;
        }
    }

    /// Makes one history column again from sample `first` on, up to the newest sample (a
    /// display filter changed): `put` every value in order, then `finish`.
    pub fn redo(self: *Ring, column: usize, first: i64) Redo {
        return .{ .ring = self, .column = column, .next = first, .whole = false };
    }

    pub const Redo = struct {
        ring: *Ring,
        column: usize,
        next: i64,
        range: Range = .{},
        /// The bucket in hand has been seen from its first sample. One that has not (the
        /// stretch began inside it) is left as it was.
        whole: bool,

        pub fn put(self: *Redo, v: i16) void {
            if (self.ring.cap == 0) return;
            const s = self.next;
            self.next += 1;
            if (s & (bucket - 1) == 0) {
                self.range = .{};
                self.whole = true;
            }
            self.range.fold(v);
            if (self.whole and (s + 1) & (bucket - 1) == 0) self.ring.at(s >> shift)[self.column] = self.range.word();
        }

        /// The last value given was the newest sample.
        pub fn finish(self: *Redo) void {
            if (self.ring.cap == 0 or !self.whole) return;
            const b = (self.next - 1) >> shift;
            if (self.next & (bucket - 1) == 0) return; // ended on a bucket's last sample: written
            self.ring.at(b)[self.column] = self.range.word();
            if (self.ring.open_bucket == b) self.ring.open[self.column] = self.range;
        }
    };
};

const testing = std.testing;

/// The minimum and maximum of column `col` over the samples of bucket `b` that exist
/// (sample numbers [0, total)), from all the rows.
fn brute(rows: []const i16, width: usize, col: usize, b: usize, total: usize) Range {
    var r: Range = .{};
    var s = b * bucket;
    while (s < @min(total, (b + 1) * bucket)) : (s += 1) r.fold(rows[s * width + col]);
    return r;
}

test "buckets equal the minimum and maximum of their samples, the partly filled one too, across the wrap" {
    const gpa = testing.allocator;
    const width = 3;
    const cap = 8;
    var words: [cap * width]u32 = @splat(0);
    var ring = try Ring.init(gpa, &words, cap, width);
    defer ring.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    const total = 400; // 25 buckets: three times round the ring
    var rows: [total * width]i16 = undefined;
    for (&rows) |*v| v.* = rnd.int(i16);
    var done: usize = 0;
    while (done < total) {
        const n = @min(total - done, rnd.intRangeAtMost(usize, 1, 37));
        ring.add(@intCast(done), rows[done * width ..][0 .. n * width]);
        done += n;
        // Every bucket the ring still holds, the newest (perhaps partly filled) included.
        const newest = (done - 1) / bucket;
        var b = newest -| (cap - 1);
        while (b <= newest) : (b += 1) {
            for (0..width) |c| {
                const want = brute(&rows, width, c, b, done);
                const got = words[(b % cap) * width + c];
                try testing.expectEqual(want.min, minOf(got));
                try testing.expectEqual(want.max, maxOf(got));
            }
        }
    }
}

test "a gap starts a new bucket and leaves the ones in between alone" {
    const gpa = testing.allocator;
    var words: [4]u32 = @splat(0xDEAD);
    var ring = try Ring.init(gpa, &words, 4, 1);
    defer ring.deinit(gpa);
    ring.add(3, &.{ 5, -2 });
    ring.add(40, &.{9}); // bucket 2; bucket 1 never written
    try testing.expectEqual(@as(i16, -2), minOf(words[0]));
    try testing.expectEqual(@as(i16, 5), maxOf(words[0]));
    try testing.expectEqual(@as(u32, 0xDEAD), words[1]);
    try testing.expectEqual(@as(i16, 9), minOf(words[2]));
    try testing.expectEqual(@as(i16, 9), maxOf(words[2]));
}

test "redoing a column rewrites its whole buckets and the open one, and later samples continue from it" {
    const gpa = testing.allocator;
    const width = 2;
    const cap = 16;
    var words: [cap * width]u32 = @splat(0);
    var ring = try Ring.init(gpa, &words, cap, width);
    defer ring.deinit(gpa);
    const total = 71; // buckets 0..3 whole, 4 open with 7 samples
    var rows: [(total + 5) * width]i16 = undefined;
    for (&rows, 0..) |*v, i| v.* = @intCast(i % 23);
    ring.add(0, rows[0 .. total * width]);

    // Column 1 again from sample 10 (inside bucket 0), with other values.
    const from = 10;
    for (from..total) |s| rows[s * width + 1] = -@as(i16, @intCast(s));
    var redo = ring.redo(1, from);
    for (from..total) |s| redo.put(rows[s * width + 1]);
    redo.finish();
    // Bucket 0 was not seen whole: left as it was (its old minimum, 0 at sample 11; the
    // redone values there are negative).
    try testing.expectEqual(@as(i16, 0), minOf(words[0 * width + 1]));
    for (1..5) |b| {
        const want = brute(&rows, width, 1, b, total);
        try testing.expectEqual(want.min, minOf(words[b * width + 1]));
        try testing.expectEqual(want.max, maxOf(words[b * width + 1]));
    }
    // Column 0 untouched.
    for (0..5) |b| try testing.expectEqual(brute(&rows, width, 0, b, total).max, maxOf(words[b * width]));
    // More samples into the open bucket: it holds the redone values and the new ones.
    ring.add(total, rows[total * width ..]);
    const want = brute(&rows, width, 1, 4, total + 5);
    try testing.expectEqual(want.min, minOf(words[4 * width + 1]));
    try testing.expectEqual(want.max, maxOf(words[4 * width + 1]));
}
