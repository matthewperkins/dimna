//! Min/max pyramids of the display's sample history, for review of long stretches.
//!
//! For every history column (see the top of `feed.zig`) the store keeps the (min, max) of
//! every bucket of 64 samples (level 0) and of every coarser level, x4 each (8 levels: 64
//! samples to 2^20, 35 s at 30 kHz). A stretch of up to hours across 1920 pixel columns is
//! then drawn from a few buckets per pixel column instead of millions of samples. Buckets
//! are aligned to absolute sample numbers: bucket k of level j holds samples
//! [k * 64 * 4^j, (k + 1) * 64 * 4^j).
//!
//! The store has two parts with their own coverage: the raw part (history columns 0 to
//! `nch` - 1, the channels as acquired, plus the OR of the TTL words per bucket) and the
//! slots part (columns `nch` to `width` - 1: what the panels show, filtered and
//! referenced). A change of the panels' filters, rows or references drops the slots part
//! only (`resetSlots`).
//!
//! `add` takes the history rows as the display makes them; coarser levels are merged
//! incrementally, so every level is right at the live edge, including the bucket that is
//! still filling. A gap in what `add` is given is a hole in the coverage; `Backfill` makes
//! the missing buckets from the recording (on another thread) and `put` splices them in.
//!
//! Storage is in chunks of `chunk_samples` samples (2^24, 9.3 min at 30 kHz; 2^20 under
//! test), aligned across levels and mapped when first written, so memory follows the
//! recording's length. A chunk is a fresh anonymous mapping that reads as empty without
//! being written (see `Held`), so starting one costs nothing up front; its pages are paid
//! for one by one as buckets fill. Over `budget_bytes`, the oldest chunks of level 0 are
//! released, then those of level 1; never the chunk at the live edge, never levels 2 and
//! up. Released chunks are unmapped a piece per `add` or `put` (`Retired`), not at once.
//! Spans that would be drawn from a released level are refused by `columns` (the caller
//! reads samples or uses a longer span).
//!
//! The store is single-threaded: the display thread owns it. Nothing here touches
//! acquisition or the recorder; `Backfill` reads the recording's files read-only.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const panels = @import("panels.zig");
const Review = @import("review.zig").Review;
const os = @import("os.zig");

/// Samples per bucket of level 0.
pub const bucket: i64 = 64;
pub const levels = 8;
/// Samples per storage chunk, the same on every level (a whole number of buckets of the
/// coarsest level).
pub const chunk_samples: i64 = if (builtin.is_test) 1 << 20 else 1 << 24;
/// Levels whose old chunks may be released under the budget.
pub const releasable = 2;

comptime {
    std.debug.assert(@mod(chunk_samples, bucketSize(levels - 1)) == 0);
    // Children of a bucket (4 at the level below) lie in the same chunk.
    std.debug.assert(perChunk(levels - 1) >= 1);
}

/// (min, max) of one history column over one bucket.
pub const Pair = [2]i16;
const empty: Pair = .{ std.math.maxInt(i16), std.math.minInt(i16) };

/// A pair as the store holds it: the minimum XOR 0x7FFF and the maximum XOR 0x8000, as
/// u16. Both halves then grow with what they stand for (a lower minimum, a higher
/// maximum), so merging is the larger of each, and `empty` is all-zero bytes. Chunks are
/// fresh anonymous mappings, which the kernel hands out zeroed on first touch: a new chunk
/// is empty without being written, and its pages are only paid for as buckets are filled.
const Held = [2]u16;

fn encode(p: Pair) Held {
    return .{ @as(u16, @bitCast(p[0])) ^ 0x7FFF, @as(u16, @bitCast(p[1])) ^ 0x8000 };
}

fn decode(h: Held) Pair {
    return .{ @bitCast(h[0] ^ 0x7FFF), @bitCast(h[1] ^ 0x8000) };
}

fn merge(d: *Held, v: Held) void {
    d[0] = @max(d[0], v[0]);
    d[1] = @max(d[1], v[1]);
}

comptime {
    std.debug.assert(@as(u32, @bitCast(encode(empty))) == 0);
}

pub fn bucketSize(k: usize) i64 {
    return bucket << @intCast(2 * k);
}

fn perChunk(k: usize) usize {
    return @intCast(@divExact(chunk_samples, bucketSize(k)));
}

/// The coarsest level whose buckets are no wider than `w` samples (a pixel column), or
/// null if `w` is under one level-0 bucket.
fn levelFor(w: i64) ?usize {
    if (w < bucket) return null;
    var k: usize = 0;
    while (k + 1 < levels and bucketSize(k + 1) <= w) k += 1;
    return k;
}

pub const Part = enum { raw, slots };
pub const Parts = enum {
    raw,
    slots,
    both,

    pub fn has(self: Parts, p: Part) bool {
        return self == .both or @backingInt(self) == @backingInt(p);
    }
};

/// Samples [lo, hi).
pub const Range = struct { lo: i64, hi: i64 };

const Chunk = struct {
    values: []Held,
    /// One word per bucket (raw part only; empty otherwise).
    ttl: []u16,
    /// The mapping both live in.
    mem: Mapping,
};

const Mapping = []align(std.heap.page_size_min) u8;

/// A fresh anonymous mapping (zeroed by the kernel on first touch) of `len` bytes rounded
/// up to whole pages.
fn mapZeroed(len: usize) !Mapping {
    const size = std.mem.alignForward(usize, @max(len, 1), std.heap.pageSize());
    const ptr = os.mapZeroed(size) orelse return error.OutOfMemory;
    return ptr[0..size];
}

/// Mappings let go of, unmapped a piece per `add` or `put` (`some`): unmapping a chunk
/// whose pages have all been touched frees them one by one, about 5 ms for a 75 MB
/// chunk, too long for one call on the display thread.
const Retired = struct {
    list: std.ArrayList(Mapping) = .empty,
    /// What one `add` or `put` unmaps at most (about 0.1 ms).
    const piece = 2 << 20;

    fn put(self: *Retired, gpa: std.mem.Allocator, mem: Mapping) void {
        self.list.append(gpa, mem) catch {
            os.unmap(mem.ptr, mem.len);
        };
    }

    /// Unmaps up to `max` bytes (whole pages), newest retired first, from its end.
    fn some(self: *Retired, max: usize) void {
        var left = std.mem.alignBackward(usize, max, std.heap.pageSize());
        while (left > 0 and self.list.items.len > 0) {
            const last = &self.list.items[self.list.items.len - 1];
            if (last.len <= left) {
                os.unmap(last.ptr, last.len);
                left -= last.len;
                _ = self.list.pop();
            } else {
                os.unmap(@alignCast(last.ptr + last.len - left), left);
                last.len -= left;
                left = 0;
            }
        }
    }

    fn all(self: *Retired, gpa: std.mem.Allocator) void {
        for (self.list.items) |m| os.unmap(m.ptr, m.len);
        self.list.deinit(gpa);
        self.list = .empty;
    }

    fn bytes(self: *const Retired) usize {
        var n: usize = 0;
        for (self.list.items) |m| n += m.len;
        return n;
    }
};

const Level = struct {
    chunks: std.ArrayList(?Chunk) = .empty,
};

/// One part of the store: its columns, levels and coverage.
const Half = struct {
    ncol: usize,
    with_ttl: bool,
    levels: [levels]Level = @splat(.{}),
    /// Samples held, sorted, disjoint and not touching.
    covered: std.ArrayList(Range) = .empty,

    fn chunkBytes(self: *const Half, k: usize) usize {
        return perChunk(k) * (self.ncol * @sizeOf(Pair) + (if (self.with_ttl) @as(usize, @sizeOf(u16)) else 0));
    }

    fn deinit(self: *Half, gpa: std.mem.Allocator, held: *usize, retired: *Retired) void {
        for (&self.levels, 0..) |*l, k| {
            for (l.chunks.items, 0..) |_, c| self.release(gpa, k, c, held, retired);
            l.chunks.deinit(gpa);
        }
        self.covered.deinit(gpa);
    }

    fn get(self: *const Half, k: usize, c: usize) ?Chunk {
        const list = self.levels[k].chunks.items;
        return if (c < list.len) list[c] else null;
    }

    /// Level `k`'s chunk `c`, mapped (all buckets empty: zero bytes, not written) if it
    /// was not.
    fn ensure(self: *Half, gpa: std.mem.Allocator, k: usize, c: usize, held: *usize) !Chunk {
        const list = &self.levels[k].chunks;
        while (list.items.len <= c) try list.append(gpa, null);
        if (list.items[c]) |ch| return ch;
        const per = perChunk(k);
        const nvalues = per * self.ncol;
        const nttl: usize = if (self.with_ttl) per else 0;
        const mem = try mapZeroed(nvalues * @sizeOf(Held) + nttl * @sizeOf(u16));
        const values: [*]Held = @ptrCast(mem.ptr);
        const ttl: [*]u16 = @ptrCast(@alignCast(mem.ptr + nvalues * @sizeOf(Held)));
        list.items[c] = .{ .values = values[0..nvalues], .ttl = ttl[0..nttl], .mem = mem };
        held.* += self.chunkBytes(k);
        return list.items[c].?;
    }

    fn release(self: *Half, gpa: std.mem.Allocator, k: usize, c: usize, held: *usize, retired: *Retired) void {
        const list = self.levels[k].chunks.items;
        if (c >= list.len) return;
        const ch = list[c] orelse return;
        retired.put(gpa, ch.mem);
        list[c] = null;
        held.* -= self.chunkBytes(k);
    }

    fn cover(self: *Half, gpa: std.mem.Allocator, lo: i64, hi: i64) !void {
        if (hi <= lo) return;
        const cov = &self.covered;
        // The usual case: continuing the newest stretch.
        if (cov.items.len > 0) {
            const last = &cov.items[cov.items.len - 1];
            if (lo >= last.lo and lo <= last.hi) {
                last.hi = @max(last.hi, hi);
                return;
            }
        }
        // The stretches it touches: [i, j).
        var i: usize = 0;
        while (i < cov.items.len and cov.items[i].hi < lo) i += 1;
        var j = i;
        var merged: Range = .{ .lo = lo, .hi = hi };
        while (j < cov.items.len and cov.items[j].lo <= hi) : (j += 1) {
            merged.lo = @min(merged.lo, cov.items[j].lo);
            merged.hi = @max(merged.hi, cov.items[j].hi);
        }
        try cov.replaceRange(gpa, i, j - i, &.{merged});
    }

    fn covers(self: *const Half, lo: i64, hi: i64) bool {
        for (self.covered.items) |r| {
            if (r.lo <= lo and r.hi >= hi) return true;
        }
        return false;
    }
};

/// Level-0 buckets made elsewhere (by `Backfill`), for `Store.put`. Every bucket has
/// `width` values (all history columns, whichever parts are meant) and a TTL word.
pub const Buckets = struct {
    parts: Parts,
    /// The slots layout they were made for (`Store.generation`).
    generation: u32,
    first_bucket: i64,
    count: usize,
    width: usize,
    /// `count` * `width`.
    values: []Pair,
    /// `count`.
    ttl: []u16,

    pub fn deinit(self: *Buckets, gpa: std.mem.Allocator) void {
        gpa.free(self.values);
        gpa.free(self.ttl);
    }
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    width: usize,
    nch: usize,
    budget: usize,
    raw: Half,
    slots: Half,
    /// Changed by every `resetSlots`; `put` refuses slot buckets made for another.
    generation: u32 = 0,
    /// One past the newest sample held (given to `add`, or in a bucket given to `put`).
    /// The chunk that holds the sample before it is the live edge, never released.
    newest: i64 = 0,
    /// Per releasable level: its chunks below this have been released (in both parts).
    floor: [releasable]usize = @splat(0),
    held: usize = 0,
    /// Released chunks not yet unmapped (not counted in `held`).
    retired: Retired = .{},
    /// Scratch for one bucket's run of rows: `width` each.
    acc_lo: []i16,
    acc_hi: []i16,

    pub fn init(gpa: std.mem.Allocator, width: usize, nch: usize, budget_bytes: usize) !Store {
        std.debug.assert(nch <= width);
        const acc_lo = try gpa.alloc(i16, width);
        errdefer gpa.free(acc_lo);
        return .{
            .gpa = gpa,
            .width = width,
            .nch = nch,
            .budget = budget_bytes,
            .raw = .{ .ncol = nch, .with_ttl = true },
            .slots = .{ .ncol = width - nch, .with_ttl = false },
            .acc_lo = acc_lo,
            .acc_hi = try gpa.alloc(i16, width),
        };
    }

    pub fn deinit(self: *Store) void {
        self.raw.deinit(self.gpa, &self.held, &self.retired);
        self.slots.deinit(self.gpa, &self.held, &self.retired);
        self.retired.all(self.gpa);
        self.gpa.free(self.acc_lo);
        self.gpa.free(self.acc_hi);
        // Chunks are mapped, not taken from `gpa`: this stands in for its leak check.
        std.debug.assert(self.held == 0);
    }

    /// Bytes of released chunks still mapped (unmapped a piece per `add` or `put`).
    pub fn retiredBytes(self: *const Store) usize {
        return self.retired.bytes();
    }

    /// Bytes of bucket storage held (both parts, every level).
    pub fn bytes(self: *const Store) usize {
        return self.held;
    }

    fn half(self: *Store, p: Part) *Half {
        return switch (p) {
            .raw => &self.raw,
            .slots => &self.slots,
        };
    }

    fn halfConst(self: *const Store, p: Part) *const Half {
        return switch (p) {
            .raw => &self.raw,
            .slots => &self.slots,
        };
    }

    fn released(self: *const Store, k: usize, c: usize) bool {
        return k < releasable and c < self.floor[k];
    }

    /// `rows.len / width` consecutive history rows starting at sample `first` (normally
    /// where the last call ended; anything else leaves a hole), with their TTL words `ttl`
    /// (one per row, or empty for none). Rows are merged into what the buckets hold, so
    /// samples given twice must be the same both times.
    pub fn add(self: *Store, first: i64, rows: []const i16, ttl: []const u16) !void {
        const width = self.width;
        if (rows.len % width != 0) return error.BadRows;
        const n = rows.len / width;
        if (ttl.len != 0 and ttl.len != n) return error.BadRows;
        if (first < 0) return error.NegativeSample;
        if (n == 0) return;
        var i: usize = 0;
        while (i < n) {
            const s = first + @as(i64, @intCast(i));
            const b: usize = @intCast(@divFloor(s, bucket));
            const run: usize = @intCast(@min(@as(i64, @intCast(n - i)), (@as(i64, @intCast(b)) + 1) * bucket - s));
            const words = if (ttl.len != 0) ttl[i..][0..run] else ttl;
            try self.fold(&self.raw, b, rows[i * width ..], run, 0, words);
            try self.fold(&self.slots, b, rows[i * width ..], run, self.nch, &.{});
            i += run;
        }
        const last = first + @as(i64, @intCast(n));
        try self.raw.cover(self.gpa, first, last);
        try self.slots.cover(self.gpa, first, last);
        self.newest = @max(self.newest, last);
        self.enforceBudget();
        self.retired.some(Retired.piece);
    }

    /// Folds `run` rows (all in level-0 bucket `b`) into every level of `h`.
    fn fold(self: *Store, h: *Half, b: usize, rows: []const i16, run: usize, col0: usize, words: []const u16) !void {
        const ncol = h.ncol;
        if (ncol == 0) return;
        const lo = self.acc_lo[0..ncol];
        const hi = self.acc_hi[0..ncol];
        @memset(lo, std.math.maxInt(i16));
        @memset(hi, std.math.minInt(i16));
        for (0..run) |r| {
            const row = rows[r * self.width + col0 ..][0..ncol];
            for (lo, hi, row) |*l, *x, v| {
                l.* = @min(l.*, v);
                x.* = @max(x.*, v);
            }
        }
        var word: u16 = 0;
        for (words) |w| word |= w;
        var idx = b;
        for (0..levels) |k| {
            defer idx >>= 2;
            const per = perChunk(k);
            const c = idx / per;
            if (self.released(k, c)) continue;
            const ch = try h.ensure(self.gpa, k, c, &self.held);
            const o = idx % per;
            for (ch.values[o * ncol ..][0..ncol], lo, hi) |*d, l, x| merge(d, encode(.{ l, x }));
            if (h.with_ttl) ch.ttl[o] |= word;
        }
    }

    /// The panels' filters, rows or references changed: the slots part is dropped (and is
    /// `width` - `nch` columns wide from now on); the raw part stays. Returns the new
    /// generation, which `Backfill` must be given.
    pub fn resetSlots(self: *Store, width: usize) !u32 {
        std.debug.assert(width >= self.nch);
        if (width > self.width) {
            const lo = try self.gpa.alloc(i16, width);
            errdefer self.gpa.free(lo);
            const hi = try self.gpa.alloc(i16, width);
            self.gpa.free(self.acc_lo);
            self.gpa.free(self.acc_hi);
            self.acc_lo = lo;
            self.acc_hi = hi;
        }
        self.slots.deinit(self.gpa, &self.held, &self.retired);
        self.slots = .{ .ncol = width - self.nch, .with_ttl = false };
        self.width = width;
        self.generation +%= 1;
        return self.generation;
    }

    /// Holes of a part's coverage within [lo, hi), newest first, as many as `out` holds.
    pub fn holes(self: *const Store, part: Part, lo: i64, hi: i64, out: []Range) []Range {
        const cov = self.halfConst(part).covered.items;
        var n: usize = 0;
        var top = hi;
        var i = cov.len;
        while (i > 0 and top > lo and n < out.len) {
            i -= 1;
            const r = cov[i];
            if (r.lo >= top) continue;
            if (r.hi < top) {
                const a = @max(r.hi, lo);
                if (a < top) {
                    out[n] = .{ .lo = a, .hi = top };
                    n += 1;
                }
            }
            top = @min(top, r.lo);
        }
        if (top > lo and n < out.len) {
            out[n] = .{ .lo = lo, .hi = top };
            n += 1;
        }
        return out[0..n];
    }

    /// Splices in level-0 buckets made elsewhere: they replace what the store had for those
    /// buckets, the coarser levels above them are made again, and they count as covered.
    /// Refused if made for another width, or (slots) for another generation.
    pub fn put(self: *Store, b: *const Buckets) !void {
        if (b.width != self.width) return error.WrongWidth;
        if (b.parts.has(.slots) and b.generation != self.generation) return error.Stale;
        if (b.first_bucket < 0) return error.NegativeSample;
        if (b.values.len != b.count * b.width or b.ttl.len != b.count) return error.BadRows;
        if (b.count == 0) return;
        const lo = b.first_bucket * bucket;
        const hi = (b.first_bucket + @as(i64, @intCast(b.count))) * bucket;
        if (b.parts.has(.raw)) {
            try self.splice(&self.raw, b, 0);
            try self.raw.cover(self.gpa, lo, hi);
        }
        if (b.parts.has(.slots)) {
            try self.splice(&self.slots, b, self.nch);
            try self.slots.cover(self.gpa, lo, hi);
        }
        self.newest = @max(self.newest, hi);
        self.enforceBudget();
        self.retired.some(Retired.piece);
    }

    fn splice(self: *Store, h: *Half, b: *const Buckets, col0: usize) !void {
        const ncol = h.ncol;
        if (ncol == 0) return;
        const fb: usize = @intCast(b.first_bucket);
        const per0 = perChunk(0);
        for (0..b.count) |i| {
            const idx = fb + i;
            if (self.released(0, idx / per0)) continue;
            const ch = try h.ensure(self.gpa, 0, idx / per0, &self.held);
            const o = idx % per0;
            for (ch.values[o * ncol ..][0..ncol], b.values[i * b.width + col0 ..][0..ncol]) |*d, v| d.* = encode(v);
            if (h.with_ttl) ch.ttl[o] = b.ttl[i];
        }
        // Each coarser bucket above them: from its four children if their level is held,
        // else (released below) what it had merged with the new buckets.
        for (1..levels) |k| {
            const shift: u6 = @intCast(2 * k);
            const j0 = fb >> shift;
            const j1 = ((fb + b.count - 1) >> shift) + 1;
            const per = perChunk(k);
            for (j0..j1) |j| {
                const c = j / per;
                if (self.released(k, c)) continue;
                const ch = try h.ensure(self.gpa, k, c, &self.held);
                const o = j % per;
                const dst = ch.values[o * ncol ..][0..ncol];
                if (!self.released(k - 1, c)) {
                    @memset(dst, encode(empty));
                    if (h.with_ttl) ch.ttl[o] = 0;
                    const child = h.get(k - 1, c) orelse continue;
                    for (0..4) |q| {
                        const co = 4 * o + q;
                        for (dst, child.values[co * ncol ..][0..ncol]) |*d, v| merge(d, v);
                        if (h.with_ttl) ch.ttl[o] |= child.ttl[co];
                    }
                } else {
                    const a = @max(fb, j << shift) - fb;
                    const e = @min(fb + b.count, (j + 1) << shift) - fb;
                    for (a..e) |i| {
                        for (dst, b.values[i * b.width + col0 ..][0..ncol]) |*d, v| merge(d, encode(v));
                        if (h.with_ttl) ch.ttl[o] |= b.ttl[i];
                    }
                }
            }
        }
    }

    /// Over the budget: releases the oldest chunks of level 0, then of level 1, in both
    /// parts, never the chunk that holds the newest sample.
    fn enforceBudget(self: *Store) void {
        if (self.held <= self.budget or self.newest <= 0) return;
        const live: usize = @intCast(@divFloor(self.newest - 1, chunk_samples));
        while (self.held > self.budget) {
            const k = for (0..releasable) |k| {
                if (self.floor[k] < live) break k;
            } else return;
            self.raw.release(self.gpa, k, self.floor[k], &self.held, &self.retired);
            self.slots.release(self.gpa, k, self.floor[k], &self.held, &self.retired);
            self.floor[k] += 1;
        }
    }

    /// The level `columns` draws [lo, hi) across `cols` pixel columns from, or null if it
    /// cannot: under 64 samples per pixel column, or that level released for part of it.
    fn plan(self: *const Store, lo: i64, hi: i64, cols: usize) ?usize {
        if (cols == 0 or lo < 0 or hi <= lo) return null;
        const k = levelFor(@divFloor(hi - lo, @as(i64, @intCast(cols)))) orelse return null;
        const first_chunk: usize = @intCast(@divFloor(@divFloor(lo, bucketSize(k)), @as(i64, @intCast(perChunk(k)))));
        if (self.released(k, first_chunk)) return null;
        return k;
    }

    /// For each of `cols` pixel columns over samples [lo, hi) and each of the history
    /// columns `history_columns`, the min and max: `out[c * history_columns.len + i]`.
    /// From the coarsest level whose buckets are no wider than the narrowest pixel column
    /// (so a pixel column reads 1 to 4 buckets, plus the two it shares with its
    /// neighbours).
    ///
    /// Pixel column c covers samples [s0, s1), s0 = lo + c * (hi - lo) / cols (rounded
    /// down), s1 the next one's s0. It is drawn from the buckets that hold any of them, so
    /// it also includes the rest of its first bucket before s0 and the rest of its last
    /// bucket from s1 on, and nothing else (as far as those were added).
    ///
    /// False (and `out` not usable) if part of [lo, hi) is not covered, its level has been
    /// released, or the span is under 64 samples per pixel column.
    pub fn columns(self: *const Store, lo: i64, hi: i64, cols: usize, history_columns: []const usize, out: []Pair) bool {
        const k = self.plan(lo, hi, cols) orelse return false;
        const nh = history_columns.len;
        if (out.len < cols * nh) return false;
        var need_raw = false;
        var need_slots = false;
        for (history_columns) |hc| {
            if (hc >= self.width) return false;
            if (hc < self.nch) need_raw = true else need_slots = true;
        }
        if (need_raw and !self.raw.covers(lo, hi)) return false;
        if (need_slots and !self.slots.covers(lo, hi)) return false;
        const size = bucketSize(k);
        const per = perChunk(k);
        const span = hi - lo;
        const ncols: i64 = @intCast(cols);
        for (0..cols) |c| {
            const ci: i64 = @intCast(c);
            const s0 = lo + @divFloor(ci * span, ncols);
            const s1 = lo + @divFloor((ci + 1) * span, ncols);
            const b0: usize = @intCast(@divFloor(s0, size));
            const b1: usize = @intCast(@divFloor(s1 - 1, size) + 1);
            const o = out[c * nh ..][0..nh];
            @memset(o, empty);
            for (b0..b1) |bk| {
                for (history_columns, o) |hc, *d| {
                    const h = if (hc < self.nch) &self.raw else &self.slots;
                    const col = if (hc < self.nch) hc else hc - self.nch;
                    const ch = h.get(k, bk / per) orelse return false;
                    const v = decode(ch.values[(bk % per) * h.ncol + col]);
                    d[0] = @min(d[0], v[0]);
                    d[1] = @max(d[1], v[1]);
                }
            }
        }
        return true;
    }

    /// As `columns`, for the TTL words: the OR per pixel column (same buckets).
    pub fn ttlColumns(self: *const Store, lo: i64, hi: i64, cols: usize, out: []u16) bool {
        const k = self.plan(lo, hi, cols) orelse return false;
        if (out.len < cols or !self.raw.covers(lo, hi)) return false;
        const size = bucketSize(k);
        const per = perChunk(k);
        const span = hi - lo;
        const ncols: i64 = @intCast(cols);
        for (out[0..cols], 0..) |*o, c| {
            const ci: i64 = @intCast(c);
            const s0 = lo + @divFloor(ci * span, ncols);
            const s1 = lo + @divFloor((ci + 1) * span, ncols);
            const b0: usize = @intCast(@divFloor(s0, size));
            const b1: usize = @intCast(@divFloor(s1 - 1, size) + 1);
            o.* = 0;
            for (b0..b1) |bk| {
                const ch = self.raw.get(k, bk / per) orelse return false;
                o.* |= ch.ttl[bk % per];
            }
        }
        return true;
    }

    /// Bucket `j` of level `k` for history column `hc`, if its chunk is held.
    fn bucketValue(self: *const Store, hc: usize, k: usize, j: usize) ?Pair {
        const h = if (hc < self.nch) &self.raw else &self.slots;
        const col = if (hc < self.nch) hc else hc - self.nch;
        const ch = h.get(k, j / perChunk(k)) orelse return null;
        return decode(ch.values[(j % perChunk(k)) * h.ncol + col]);
    }

    fn bucketTtl(self: *const Store, k: usize, j: usize) ?u16 {
        const ch = self.raw.get(k, j / perChunk(k)) orelse return null;
        return ch.ttl[j % perChunk(k)];
    }

    /// How one part of two stores compares, bucket by bucket on every level (for tests).
    pub const Comparison = struct {
        /// The same chunks are held (if not, the rest is not looked at).
        same_chunks: bool = true,
        /// The TTL words (raw part) are the same.
        same_ttl: bool = true,
        /// The largest difference of a minimum or maximum, LSB, and how many pairs differ.
        worst: u32 = 0,
        differ: usize = 0,
    };

    pub fn compare(a: *const Store, b: *const Store, part: Part) Comparison {
        var r: Comparison = .{};
        const ha = a.halfConst(part);
        const hb = b.halfConst(part);
        if (ha.ncol != hb.ncol) return .{ .same_chunks = false };
        for (0..levels) |k| {
            const n = @max(ha.levels[k].chunks.items.len, hb.levels[k].chunks.items.len);
            for (0..n) |c| {
                const ca = ha.get(k, c);
                const cb = hb.get(k, c);
                if ((ca == null) != (cb == null)) return .{ .same_chunks = false };
                if (ca == null) continue;
                for (ca.?.values, cb.?.values) |x, y| {
                    const p = decode(x);
                    const q = decode(y);
                    const d = @max(@abs(@as(i32, p[0]) - q[0]), @abs(@as(i32, p[1]) - q[1]));
                    r.worst = @max(r.worst, d);
                    r.differ += @intFromBool(d != 0);
                }
                if (!std.mem.eql(u16, ca.?.ttl, cb.?.ttl)) r.same_ttl = false;
            }
        }
        return r;
    }
};

/// Fills a store's holes from the recording: reads it back through a `Review` (a private
/// feed set up as the live one, with a lead-in so the filters have settled) and makes the
/// level-0 buckets. For another thread: it owns nothing of the store, and its results own
/// their memory (`Buckets.deinit`), so they can be handed over. No sleeping or pacing here.
pub const Backfill = struct {
    gpa: std.mem.Allocator,
    review: Review,
    /// The review's ring: `cap` history rows.
    ring: []i16,
    cap: usize,
    generation: u32,
    /// The most samples one `step` processes (2 s, whole buckets).
    max_samples: i64,
    words: []u16,
    /// The recording's folder, for `follow`.
    dir_buf: [std.fs.max_path_bytes]u8 = undefined,
    dir_len: usize = 0,

    /// `set` are the live panels (their slots must be the live feed's); `generation` is the
    /// store's (`Store.generation`).
    pub fn init(gpa: std.mem.Allocator, layout: *const types.Layout, set: *const panels.Set, generation: u32) !Backfill {
        const max_samples = @divFloor(@as(i64, @intFromFloat(2.0 * layout.sample_rate)), bucket) * bucket;
        const cap = try std.math.ceilPowerOfTwo(usize, @intCast(max_samples + bucket));
        var probe = set.*;
        var feed = try @import("feed.zig").Feed.init(gpa, layout, &probe, 64, 64);
        const width = feed.width;
        feed.deinit(gpa);
        const ring = try gpa.alloc(i16, cap * width);
        errdefer gpa.free(ring);
        @memset(ring, 0);
        const words = try gpa.alloc(u16, @intCast(max_samples + bucket));
        errdefer gpa.free(words);
        return .{
            .gpa = gpa,
            .review = try Review.init(gpa, layout, set, ring, cap),
            .ring = ring,
            .cap = cap,
            .generation = generation,
            .max_samples = max_samples,
            .words = words,
        };
    }

    pub fn deinit(self: *Backfill) void {
        self.review.deinit();
        self.gpa.free(self.ring);
        self.gpa.free(self.words);
    }

    /// Opens the recording in folder `dir`, whose first sample is `first_sample`.
    pub fn open(self: *Backfill, dir: []const u8, first_sample: i64) !void {
        if (dir.len > self.dir_buf.len) return error.NameTooLong;
        try self.review.open(dir, first_sample);
        @memcpy(self.dir_buf[0..dir.len], dir);
        self.dir_len = dir.len;
    }

    /// The panels changed (the store was `resetSlots` to `generation`). Made afresh rather
    /// than with `Review.follow`: the private ring is `cap` rows of the history's width,
    /// and the width may have changed with the panels (`Review.follow` makes a new feed
    /// but keeps the ring it was given).
    pub fn follow(self: *Backfill, set: *const panels.Set, generation: u32) !void {
        var fresh = try Backfill.init(self.gpa, &self.review.layout, set, generation);
        errdefer fresh.deinit();
        if (self.dir_len > 0) try fresh.open(self.dir_buf[0..self.dir_len], self.review.first_sample);
        self.deinit();
        self.* = fresh;
    }

    /// Works on the hole [hole_lo, hole_hi) of `parts` of a store, in a recording that ends
    /// before sample `end`: processes at most 2 s of samples at the hole's newest end and
    /// returns their level-0 buckets, every bucket that holds a sample of the hole and lies
    /// whole within the recording (the recording's first bucket counts as whole from its
    /// first sample). Null if there is no such bucket (yet).
    pub fn step(self: *Backfill, parts: Parts, hole_lo: i64, hole_hi: i64, end: i64) !?Buckets {
        const first = self.review.first_sample;
        const lo = @max(hole_lo, first);
        const hi = @min(hole_hi, end);
        if (hi <= lo) return null;
        const e_b = @min(@divFloor(hi - 1, bucket) + 1, @divFloor(end, bucket));
        const s_b = @max(@divFloor(lo, bucket), e_b - @divExact(self.max_samples, bucket));
        if (e_b <= s_b) return null;
        const a = @max(s_b * bucket, first);
        const e = e_b * bucket;
        const n: usize = @intCast(e - a);
        // Afresh (a lead-in) every time: each step is older than the one before.
        self.review.invalidate();
        if (!try self.review.fill(a, e, end, n)) return error.ReviewIncomplete;
        const words = self.words[0..n];
        self.review.ttlWords(a, words);
        const width = self.review.feed.width;
        const count: usize = @intCast(e_b - s_b);
        const values = try self.gpa.alloc(Pair, count * width);
        errdefer self.gpa.free(values);
        const ttl = try self.gpa.alloc(u16, count);
        @memset(values, empty);
        @memset(ttl, 0);
        const mask = self.cap - 1;
        var s = a;
        while (s < e) : (s += 1) {
            const i: usize = @intCast(@divFloor(s, bucket) - s_b);
            const row = self.ring[@as(usize, @intCast(@as(u64, @bitCast(s)) & mask)) * width ..][0..width];
            for (values[i * width ..][0..width], row) |*d, v| {
                d[0] = @min(d[0], v);
                d[1] = @max(d[1], v);
            }
            ttl[i] |= words[@intCast(s - a)];
        }
        return .{
            .parts = parts,
            .generation = self.generation,
            .first_bucket = s_b,
            .count = count,
            .width = width,
            .values = values,
            .ttl = ttl,
        };
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A test signal: a slow and a faster sine per column, noise and rare spikes, so the
/// extremes differ from bucket to bucket at every level.
fn testValue(s: i64, col: usize) i16 {
    var z: u64 = @as(u64, @bitCast(s)) *% 0x9E3779B97F4A7C15 +% @as(u64, col) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z ^= z >> 31;
    const x: f64 = @floatFromInt(s);
    const cf: f64 = @floatFromInt(col);
    var v = 12000.0 * @sin(x / (40000.0 + 7000.0 * cf)) + 3000.0 * @sin(x / (37.0 + cf)) +
        @as(f64, @floatFromInt(z % 1001)) - 500.0;
    if ((z >> 20) % 4999 == 0) v += if ((z >> 40) & 1 == 0) 15000.0 else -15000.0;
    return @intFromFloat(std.math.clamp(@round(v), -32768.0, 32767.0));
}

fn testWord(s: i64) u16 {
    var w: u16 = if (@mod(@divFloor(s, 1000), 2) == 1) 1 else 0;
    if (@mod(s, 50021) < 7) w |= 8;
    if (@mod(s, 3_000_017) < 100) w |= 0x40;
    return w;
}

/// `n` rows of `width` test values from sample `first`, and their words.
fn testRows(gpa: std.mem.Allocator, first: i64, n: usize, width: usize) !struct { rows: []i16, words: []u16 } {
    const rows = try gpa.alloc(i16, n * width);
    errdefer gpa.free(rows);
    const words = try gpa.alloc(u16, n);
    for (0..n) |i| {
        const s = first + @as(i64, @intCast(i));
        for (0..width) |c| rows[i * width + c] = testValue(s, c);
        words[i] = testWord(s);
    }
    return .{ .rows = rows, .words = words };
}

const odd_blocks = [_]usize{ 1, 63, 64, 65, 127, 1000, 4097, 7, 333, 2 };

/// Adds rows [from, to) (relative to the arrays, which start at sample `first`) in blocks
/// of odd lengths.
fn addOdd(store: *Store, first: i64, rows: []const i16, words: []const u16, from: usize, to: usize) !void {
    const w = store.width;
    var i = from;
    var b: usize = 0;
    while (i < to) : (b += 1) {
        const n = @min(odd_blocks[b % odd_blocks.len], to - i);
        try store.add(first + @as(i64, @intCast(i)), rows[i * w ..][0 .. n * w], words[i..][0..n]);
        i += n;
    }
}

/// Brute force: min/max of column `col` and the OR of the words over samples [a, b)
/// clipped to the arrays (which start at `first`).
fn brute(rows: []const i16, words: []const u16, width: usize, first: i64, a: i64, b: i64, col: usize) struct { p: Pair, w: u16 } {
    const n: i64 = @intCast(words.len);
    var p = empty;
    var w: u16 = 0;
    var s = @max(a, first);
    while (s < @min(b, first + n)) : (s += 1) {
        const i: usize = @intCast(s - first);
        p[0] = @min(p[0], rows[i * width + col]);
        p[1] = @max(p[1], rows[i * width + col]);
        w |= words[i];
    }
    return .{ .p = p, .w = w };
}

fn expectSameHalf(a: *const Half, b: *const Half) !void {
    try testing.expectEqual(a.ncol, b.ncol);
    for (0..levels) |k| {
        const la = a.levels[k].chunks.items;
        const lb = b.levels[k].chunks.items;
        for (0..@max(la.len, lb.len)) |c| {
            const ca = a.get(k, c);
            const cb = b.get(k, c);
            try testing.expectEqual(ca == null, cb == null);
            if (ca == null) continue;
            for (ca.?.values, cb.?.values) |x, y| try testing.expectEqual(x, y);
            try testing.expectEqualSlices(u16, ca.?.ttl, cb.?.ttl);
        }
    }
}

test "every level equals brute force, added in odd blocks, with a filling bucket and across a chunk boundary" {
    const gpa = testing.allocator;
    const width = 3;
    // Starts mid-bucket, crosses the chunk boundary at 2^20, ends mid-bucket.
    const first: i64 = chunk_samples - 150_001;
    const n: usize = 300_037;
    const d = try testRows(gpa, first, n, width);
    defer gpa.free(d.rows);
    defer gpa.free(d.words);
    var store = try Store.init(gpa, width, 2, std.math.maxInt(usize));
    defer store.deinit();

    var i: usize = 0;
    var b: usize = 0;
    while (i < n) : (b += 1) {
        const m = @min(odd_blocks[b % odd_blocks.len], n - i);
        try store.add(first + @as(i64, @intCast(i)), d.rows[i * width ..][0 .. m * width], d.words[i..][0..m]);
        i += m;
        // Now and then: the newest bucket of every level, still filling, is what has
        // arrived of it.
        if (b % 97 == 0 or i == n) {
            const now = first + @as(i64, @intCast(i));
            for (0..levels) |k| {
                const size = bucketSize(k);
                const j = @divFloor(now - 1, size);
                for (0..width) |col| {
                    const want = brute(d.rows[0 .. i * width], d.words[0..i], width, first, j * size, (j + 1) * size, col);
                    try testing.expectEqual(want.p, store.bucketValue(col, k, @intCast(j)).?);
                    if (col == 0) try testing.expectEqual(want.w, store.bucketTtl(k, @intCast(j)).?);
                }
            }
        }
    }
    // Everything: every bucket of every level that holds a sample.
    const end = first + @as(i64, @intCast(n));
    for (0..levels) |k| {
        const size = bucketSize(k);
        var j = @divFloor(first, size);
        while (j * size < end) : (j += 1) {
            for (0..width) |col| {
                const want = brute(d.rows, d.words, width, first, j * size, (j + 1) * size, col);
                try testing.expectEqual(want.p, store.bucketValue(col, k, @intCast(j)).?);
                if (col == 0) try testing.expectEqual(want.w, store.bucketTtl(k, @intCast(j)).?);
            }
        }
    }
    // The chunk boundary was crossed at level 0 (two chunks held there).
    try testing.expect(store.raw.get(0, 0) != null and store.raw.get(0, 1) != null);
}

test "a fresh chunk reads as empty without having been written" {
    const gpa = testing.allocator;
    const width = 3;
    var store = try Store.init(gpa, width, 2, std.math.maxInt(usize));
    defer store.deinit();
    // One row, in the middle of the second chunk: that chunk is made on every level of
    // both parts, and only the buckets holding the row are written.
    const s: i64 = chunk_samples + 3 * bucketSize(levels - 2) + 3;
    const row = [_]i16{ -5, 7, 300 };
    try store.add(s, &row, &.{0x21});
    for (0..levels) |k| {
        const per = perChunk(k);
        const own: usize = @intCast(@divFloor(s, bucketSize(k)));
        for ([_]*const Half{ &store.raw, &store.slots }) |h| {
            const ch = h.get(k, 1).?;
            try testing.expect(h.get(k, 0) == null);
            // Every pair but the written bucket's is all-zero bytes...
            for (ch.values, 0..) |v, i| {
                if (i / h.ncol == own - per) continue;
                try testing.expectEqual(Held{ 0, 0 }, v);
            }
            for (ch.ttl, 0..) |w, i| {
                if (i != own - per) try testing.expectEqual(0, w);
            }
        }
        // ...and reads as empty; the written bucket as the row.
        for (0..width) |col| {
            for ([_]usize{ per, per + 1, own - 1, own + 1, 2 * per - 1 }) |j| {
                // Within the chunk (level 7 has one bucket per chunk).
                if (j == own or j < per or j >= 2 * per) continue;
                try testing.expectEqual(empty, store.bucketValue(col, k, j).?);
            }
            try testing.expectEqual(Pair{ row[col], row[col] }, store.bucketValue(col, k, own).?);
        }
        if (own + 1 < 2 * per) try testing.expectEqual(0, store.bucketTtl(k, own + 1).?);
        try testing.expectEqual(0x21, store.bucketTtl(k, own).?);
    }
    // The extremes survive the encoding: -32768 and 32767 as a minimum and a maximum.
    const ext = [_]i16{ -32768, 32767, 0 };
    try store.add(s + 1, &ext, &.{0});
    try testing.expectEqual(Pair{ -32768, -5 }, store.bucketValue(0, 0, @intCast(@divFloor(s, bucket))).?);
    try testing.expectEqual(Pair{ 7, 32767 }, store.bucketValue(1, 0, @intCast(@divFloor(s, bucket))).?);
}

test "released chunks are unmapped a piece per add" {
    const gpa = testing.allocator;
    var store = try Store.init(gpa, 3, 2, std.math.maxInt(usize));
    defer store.deinit();
    // Two mappings of 2.5 and 1 pieces, touched, retired.
    const big = try mapZeroed(Retired.piece * 5 / 2);
    @memset(big, 7);
    const small = try mapZeroed(Retired.piece);
    @memset(small, 7);
    store.retired.put(gpa, big);
    store.retired.put(gpa, small);
    try testing.expectEqual(Retired.piece * 7 / 2, store.retiredBytes());
    const row = [_]i16{ 1, 2, 3 };
    var s: i64 = 0;
    for ([_]usize{ Retired.piece * 5 / 2, Retired.piece * 3 / 2, Retired.piece / 2, 0, 0 }) |left| {
        try store.add(s, &row, &.{0});
        s += 1;
        try testing.expectEqual(left, store.retiredBytes());
    }
    // What is still mapped of the first one is its start, untouched by the unmapping.
    store.retired.put(gpa, try mapZeroed(Retired.piece * 3));
    try store.add(s, &row, &.{0});
    try testing.expectEqual(Retired.piece * 2, store.retiredBytes());
    try testing.expectEqual(0, store.retired.list.items[0][Retired.piece * 2 - 1]);
}

test "columns equals brute force, from 64 to 2^18 samples per pixel column, unaligned" {
    const gpa = testing.allocator;
    const width = 3;
    const first: i64 = 12_345;
    const n: usize = 1_200_000;
    const d = try testRows(gpa, first, n, width);
    defer gpa.free(d.rows);
    defer gpa.free(d.words);
    var store = try Store.init(gpa, width, 2, std.math.maxInt(usize));
    defer store.deinit();
    try addOdd(&store, first, d.rows, d.words, 0, n);
    const end = first + @as(i64, @intCast(n));

    // Slots column first, then the raw ones out of order.
    const hcols = [_]usize{ 2, 0, 1 };
    var out: [7 * hcols.len]Pair = undefined;
    var words: [7]u16 = undefined;
    const spans = [_]i64{ 64, 65, 100, 255, 256, 257, 1000, 1023, 1024, 4095, 4096, 5000, 16384, 65535, 65536, 65537, 200_000, 262_143, 262_144 };
    for (spans) |w| {
        for ([_]usize{ 4, 7 }) |cols| {
            const ncols: i64 = @intCast(cols);
            const lo = first + 777;
            // hi - lo = w * cols + cols - 1: the narrowest pixel column is w samples.
            const hi = lo + w * ncols + ncols - 1;
            if (hi > end) continue;
            try testing.expect(store.columns(lo, hi, cols, &hcols, &out));
            try testing.expect(store.ttlColumns(lo, hi, cols, &words));
            // The level: the coarsest whose buckets are no wider than w.
            var k: usize = 0;
            while (k + 1 < levels and bucketSize(k + 1) <= w) k += 1;
            const size = bucketSize(k);
            for (0..cols) |c| {
                const ci: i64 = @intCast(c);
                const s0 = lo + @divFloor(ci * (hi - lo), ncols);
                const s1 = lo + @divFloor((ci + 1) * (hi - lo), ncols);
                // Its own samples, plus the rest of its first and last buckets.
                const a = @divFloor(s0, size) * size;
                const e = (@divFloor(s1 - 1, size) + 1) * size;
                for (hcols, 0..) |hc, x| {
                    const want = brute(d.rows, d.words, width, first, a, e, hc);
                    try testing.expectEqual(want.p, out[c * hcols.len + x]);
                    if (x == 0) try testing.expectEqual(want.w, words[c]);
                }
            }
        }
    }
    // Under 64 samples per pixel column, past the newest sample, before the first: no.
    try testing.expect(!store.columns(first + 100, first + 100 + 63 * 4 + 3, 4, &hcols, &out));
    try testing.expect(!store.columns(end - 10_000, end + 1, 4, &hcols, &out));
    try testing.expect(!store.columns(first - 1, first + 10_000, 4, &hcols, &out));
    try testing.expect(!store.columns(first, first + 10_000, 4, &.{3}, &out));
}

test "a gap is a hole, columns refuse it, put closes it as if it never was" {
    const gpa = testing.allocator;
    const width = 3;
    const first: i64 = 1000;
    const n: usize = 200_000;
    const d = try testRows(gpa, first, n, width);
    defer gpa.free(d.rows);
    defer gpa.free(d.words);
    var full = try Store.init(gpa, width, 2, std.math.maxInt(usize));
    defer full.deinit();
    try addOdd(&full, first, d.rows, d.words, 0, n);
    var gappy = try Store.init(gpa, width, 2, std.math.maxInt(usize));
    defer gappy.deinit();
    const g0: usize = 60_013;
    const g1: usize = 80_101;
    try addOdd(&gappy, first, d.rows, d.words, 0, g0);
    try addOdd(&gappy, first, d.rows, d.words, g1, n);
    const end = first + @as(i64, @intCast(n));
    const hole: Range = .{ .lo = first + g0, .hi = first + g1 };

    var buf: [4]Range = undefined;
    for ([_]Part{ .raw, .slots }) |part| {
        const hs = gappy.holes(part, first, end, &buf);
        try testing.expectEqual(1, hs.len);
        try testing.expectEqual(hole, hs[0]);
        // From sample 0: also what was before the first sample, older, so second.
        const all = gappy.holes(part, 0, end, &buf);
        try testing.expectEqual(2, all.len);
        try testing.expectEqual(hole, all[0]);
        try testing.expectEqual(Range{ .lo = 0, .hi = first }, all[1]);
    }
    var out: [4 * 3]Pair = undefined;
    try testing.expect(!gappy.columns(hole.lo - 5000, hole.hi + 5000, 4, &.{ 0, 1, 2 }, &out));
    try testing.expect(!gappy.columns(hole.lo + 10, hole.lo + 10_000, 4, &.{0}, &out));
    try testing.expect(!gappy.columns(hole.lo + 10, hole.lo + 10_000, 4, &.{2}, &out));
    try testing.expect(gappy.columns(first, hole.lo, 4, &.{ 0, 1, 2 }, &out));
    try testing.expect(gappy.columns(hole.hi, end, 4, &.{ 0, 1, 2 }, &out));

    // The whole buckets that hold the hole, made from the samples.
    const b0 = @divFloor(hole.lo, bucket);
    const b1 = @divFloor(hole.hi - 1, bucket) + 1;
    const count: usize = @intCast(b1 - b0);
    var bk: Buckets = .{
        .parts = .both,
        .generation = gappy.generation,
        .first_bucket = b0,
        .count = count,
        .width = width,
        .values = try gpa.alloc(Pair, count * width),
        .ttl = try gpa.alloc(u16, count),
    };
    defer bk.deinit(gpa);
    for (0..count) |i| {
        const s = (b0 + @as(i64, @intCast(i))) * bucket;
        for (0..width) |c| {
            const r = brute(d.rows, d.words, width, first, s, s + bucket, c);
            bk.values[i * width + c] = r.p;
            bk.ttl[i] = r.w;
        }
    }
    try gappy.put(&bk);
    for ([_]Part{ .raw, .slots }) |part| try testing.expectEqual(0, gappy.holes(part, first, end, &buf).len);
    try expectSameHalf(&full.raw, &gappy.raw);
    try expectSameHalf(&full.slots, &gappy.slots);
    try testing.expect(gappy.columns(hole.lo - 5000, hole.hi + 5000, 4, &.{ 0, 1, 2 }, &out));
}

test "resetSlots drops only the slots part; a put for the old layout is refused" {
    const gpa = testing.allocator;
    const first: i64 = 0;
    const n: usize = 100_000;
    const d = try testRows(gpa, first, n, 3);
    defer gpa.free(d.rows);
    defer gpa.free(d.words);
    var store = try Store.init(gpa, 3, 2, std.math.maxInt(usize));
    defer store.deinit();
    try addOdd(&store, first, d.rows, d.words, 0, n);
    const end = first + @as(i64, @intCast(n));
    var before: [5 * 2]Pair = undefined;
    try testing.expect(store.columns(0, end, 5, &.{ 0, 1 }, &before));
    const bytes_before = store.bytes();
    const old_gen = store.generation;
    var stale: Buckets = .{
        .parts = .both,
        .generation = old_gen,
        .first_bucket = 10,
        .count = 1,
        .width = 4,
        .values = try gpa.alloc(Pair, 4),
        .ttl = try gpa.alloc(u16, 1),
    };
    defer stale.deinit(gpa);
    @memset(stale.values, .{ -7, 7 });
    stale.ttl[0] = 0;

    // A new layout, one column wider.
    const gen = try store.resetSlots(4);
    try testing.expect(gen != old_gen);
    try testing.expectEqual(gen, store.generation);
    var buf: [2]Range = undefined;
    try testing.expectEqual(0, store.holes(.raw, first, end, &buf).len);
    const hs = store.holes(.slots, first, end, &buf);
    try testing.expectEqual(1, hs.len);
    try testing.expectEqual(Range{ .lo = first, .hi = end }, hs[0]);
    var after: [5 * 2]Pair = undefined;
    try testing.expect(store.columns(0, end, 5, &.{ 0, 1 }, &after));
    try testing.expectEqualSlices(Pair, &before, &after);
    try testing.expect(!store.columns(0, end, 5, &.{2}, &after));
    try testing.expect(store.bytes() < bytes_before);
    try testing.expect(store.slots.get(0, 0) == null);

    // Made for the old layout: refused, nothing changes.
    try testing.expectError(error.Stale, store.put(&stale));
    try testing.expectEqual(1, store.holes(.slots, first, end, &buf).len);
    try testing.expect(store.slots.get(0, 0) == null);
    // Raw buckets do not depend on the layout: those are taken.
    stale.parts = .raw;
    try store.put(&stale);
    try testing.expectEqual(Pair{ -7, 7 }, store.bucketValue(0, 0, 10).?);
    // For the new generation: taken.
    stale.parts = .slots;
    stale.generation = gen;
    try store.put(&stale);
    try testing.expectEqual(Pair{ -7, 7 }, store.bucketValue(3, 0, 10).?);
    // That bucket is covered now: the slots hole is two, on either side of it.
    try testing.expectEqual(2, store.holes(.slots, first, end, &buf).len);
    try testing.expectEqual(Range{ .lo = 704, .hi = end }, buf[0]);
    try testing.expectEqual(Range{ .lo = first, .hi = 640 }, buf[1]);

    // New rows, four wide: the slots part fills again from there.
    const d4 = try testRows(gpa, end, 5000, 4);
    defer gpa.free(d4.rows);
    defer gpa.free(d4.words);
    try store.add(end, d4.rows, d4.words);
    try testing.expect(store.columns(end, end + 5000, 5, &.{ 2, 3 }, &after));
    try testing.expectError(error.BadRows, store.add(end + 5000, d.rows[0..3], &.{}));
}

test "the budget: level 0's oldest chunks go first, then level 1's, the live edge stays, coarse levels answer" {
    const gpa = testing.allocator;
    const width = 3;
    var probe = try Store.init(gpa, width, 2, std.math.maxInt(usize));
    defer probe.deinit();
    // The bytes one chunk's stretch takes on every level.
    const block = 8192;
    const d = try testRows(gpa, 0, block, width);
    defer gpa.free(d.rows);
    defer gpa.free(d.words);
    try probe.add(0, d.rows, d.words);
    const per_stretch = probe.bytes();
    // Small enough that level 0 alone (all but the live chunk) is not enough.
    const budget = per_stretch * 18 / 10;
    var store = try Store.init(gpa, width, 2, budget);
    defer store.deinit();

    // 4.5 chunks, in blocks of the same rows shifted in time (values from the sample
    // number, so brute force can be made later for any stretch).
    const total: i64 = chunk_samples * 9 / 2;
    const rows = try gpa.alloc(i16, block * width);
    defer gpa.free(rows);
    const words = try gpa.alloc(u16, block);
    defer gpa.free(words);
    var s: i64 = 0;
    var level1_went_at: ?usize = null;
    while (s < total) : (s += block) {
        for (0..block) |i| {
            const t = s + @as(i64, @intCast(i));
            for (0..width) |c| rows[i * width + c] = testValue(t, c);
            words[i] = testWord(t);
        }
        const floor1 = store.floor[1];
        try store.add(s, rows, words);
        try testing.expect(store.bytes() <= budget);
        // A chunk of level 1 goes only when nothing else would do: had it been kept, the
        // store would be over the budget.
        if (store.floor[1] > floor1) {
            const level1_chunk = store.raw.chunkBytes(1) + store.slots.chunkBytes(1);
            try testing.expect(store.bytes() + level1_chunk > budget);
        }
        const live: usize = @intCast(@divFloor(s + block - 1, chunk_samples));
        // The live chunk is held on every level.
        for (0..levels) |k| try testing.expect(store.raw.get(k, live) != null and store.slots.get(k, live) != null);
        // Level 1 loses a chunk only once level 0 has nothing but the live one left.
        if (store.floor[1] > 0 and level1_went_at == null) {
            level1_went_at = live;
            try testing.expectEqual(live, store.floor[0]);
            for (0..live) |c| try testing.expect(store.raw.get(0, c) == null);
        }
        if (store.floor[1] == 0) {
            for (0..store.floor[0]) |c| try testing.expect(store.raw.get(0, c) == null);
            try testing.expect(store.raw.get(1, 0) != null);
        }
    }
    try testing.expect(level1_went_at != null);
    try testing.expect(store.raw.get(0, 0) == null and store.raw.get(1, 0) == null);
    // Levels 2 and up keep everything.
    for (2..levels) |k| {
        for (0..5) |c| try testing.expect(store.raw.get(k, c) != null and store.slots.get(k, c) != null);
    }
    // The released stretch: at levels 0 and 1 refused, from level 2 on drawn, and right.
    var out: [5 * 3]Pair = undefined;
    var tw: [5]u16 = undefined;
    try testing.expect(!store.columns(100, 100 + 64 * 5, 5, &.{0}, &out));
    try testing.expect(!store.columns(100, 100 + 256 * 5, 5, &.{0}, &out));
    const lo: i64 = 100;
    const hi: i64 = lo + 1024 * 5 + 4;
    try testing.expect(store.columns(lo, hi, 5, &.{ 0, 1, 2 }, &out));
    try testing.expect(store.ttlColumns(lo, hi, 5, &tw));
    for (0..5) |c| {
        const ci: i64 = @intCast(c);
        const a = @divFloor(lo + @divFloor(ci * (hi - lo), 5), 1024) * 1024;
        const e = (@divFloor(lo + @divFloor((ci + 1) * (hi - lo), 5) - 1, 1024) + 1) * 1024;
        var w: u16 = 0;
        for (0..3) |col| {
            var p = empty;
            var t = a;
            while (t < e) : (t += 1) {
                p[0] = @min(p[0], testValue(t, col));
                p[1] = @max(p[1], testValue(t, col));
                if (col == 0) w |= testWord(t);
            }
            try testing.expectEqual(p, out[c * 3 + col]);
        }
        try testing.expectEqual(w, tw[c]);
    }
    // A put into the released stretch: levels 0 and 1 stay released (nothing allocated),
    // level 2 up take the new bucket merged into what they had.
    const held = store.bytes();
    const level2_before = store.bucketValue(0, 2, 3).?;
    var bk: Buckets = .{
        .parts = .both,
        .generation = store.generation,
        .first_bucket = 3 * 16 + 5,
        .count = 1,
        .width = width,
        .values = try gpa.alloc(Pair, width),
        .ttl = try gpa.alloc(u16, 1),
    };
    defer bk.deinit(gpa);
    @memset(bk.values, .{ -32000, 32000 });
    bk.ttl[0] = 0x80;
    try store.put(&bk);
    try testing.expectEqual(held, store.bytes());
    try testing.expect(store.raw.get(0, 0) == null and store.raw.get(1, 0) == null);
    try testing.expect(level2_before[0] > -32000 and level2_before[1] < 32000);
    for (2..levels) |k| {
        try testing.expectEqual(Pair{ -32000, 32000 }, store.bucketValue(0, k, @as(usize, 3 * 16 + 5) >> @intCast(2 * k)).?);
        try testing.expect(store.bucketTtl(k, @as(usize, 3 * 16 + 5) >> @intCast(2 * k)).? & 0x80 != 0);
    }
    // Its neighbour at level 2 is untouched.
    try testing.expectEqual(store.bucketValue(0, 2, 2).?, blk: {
        var p = empty;
        var t: i64 = 2 * 1024;
        while (t < 3 * 1024) : (t += 1) {
            p[0] = @min(p[0], testValue(t, 0));
            p[1] = @max(p[1], testValue(t, 0));
        }
        break :blk p;
    });
}

test "backfill from a recording equals the live store, apart from the lead-ins" {
    const gpa = testing.allocator;
    var layout: types.Layout = .{ .sample_rate = 30000, .hw_clock_hz = 50e6 };
    layout.headstages[0] = .{ .slot = 0, .chip = "RHD2132", .num_channels = 4, .first_channel = 0, .has_bno = false };
    layout.num_headstages = 1;
    layout.num_electrodes = 4;
    layout.num_adc = 1;
    var set = panels.default(&layout, .scroll);
    // Band-passed 300 Hz to 6 kHz, row 3 shown as acquired, referenced to rows 1, 2 and 4,
    // subtracted from rows 1 to 3; and a panel of TTL lanes (lines 1 and 4).
    const p = &set.items[0];
    p.filter.on = true;
    p.filter.low_hz = 300;
    p.filter.high_hz = 6000;
    p.per_row.raw.set(2, true);
    p.reference.on = true;
    for ([_]usize{ 0, 1, 3 }) |r| p.reference.ref.set(r, true);
    for ([_]usize{ 0, 1, 2 }) |r| p.reference.sub.set(r, true);
    set.items[1] = set.items[0];
    set.items[1].kind = .ttl;
    set.items[1].rows = 2;
    set.items[1].ttl_lines[0] = 1;
    set.items[1].ttl_lines[1] = 4;
    set.len = 2;

    // A recording of 5 s from sample 5000 (mid-bucket); it ends on a bucket boundary.
    const nch = 5;
    const first: i64 = 5000;
    const end: i64 = 64 * 2422;
    const total: usize = @intCast(end - first);
    const data = try gpa.alloc(i16, total * nch);
    defer gpa.free(data);
    const words = try gpa.alloc(u16, total);
    defer gpa.free(words);
    for (0..total) |i| {
        const t = @as(f64, @floatFromInt(first + @as(i64, @intCast(i)))) / 30000.0;
        const common = 2000.0 * @sin(2.0 * std.math.pi * 50.0 * t);
        for (0..4) |c| {
            const cf: f64 = @floatFromInt(c);
            const own = 600.0 * @sin(2.0 * std.math.pi * (900.0 + 130.0 * cf) * t) + 1000.0 * cf;
            const noise: f64 = @floatFromInt(@as(i32, testValue(@intCast(i), c)) >> 6);
            data[i * nch + c] = @intFromFloat(@round(common + own + noise));
        }
        data[i * nch + 4] = @intCast(@mod(@as(i64, @intCast(i)), 20000) - 10000);
        // Line 1 toggles every 7 ms; line 4 high in short pulses.
        var w: u16 = if (@mod(@divFloor(@as(i64, @intCast(i)), 210), 2) == 1) 1 else 0;
        if (@mod(@as(i64, @intCast(i)), 9001) < 300) w |= 8;
        words[i] = w;
    }
    // The edge files: every change of the word (and the first).
    var es: std.ArrayList(i64) = .empty;
    defer es.deinit(gpa);
    var ew: std.ArrayList(u16) = .empty;
    defer ew.deinit(gpa);
    for (words, 0..) |w, i| {
        if (i == 0 or w != words[i - 1]) {
            try es.append(gpa, first + @as(i64, @intCast(i)));
            try ew.append(gpa, w);
        }
    }
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buf, "/tmp/dimna-pyramid-test-{d}", .{os.getpid()}, 0);
    try std.Io.Dir.cwd().createDirPath(testing.io, dir);
    defer std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    inline for (
        .{ "samples.i16", "ttl_sample.i64", "ttl_word.u16" },
        .{ std.mem.sliceAsBytes(data), std.mem.sliceAsBytes(es.items), std.mem.sliceAsBytes(ew.items) },
    ) |name, bytes_| {
        var b: [96:0]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&b, "{s}/{s}", .{ dir, name }, 0);
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = bytes_ });
    }

    // Live: the rows of a feed made from the same panels, in blocks of 256.
    var probe = set;
    var feed = try @import("feed.zig").Feed.init(gpa, &layout, &probe, 4096, 256);
    defer feed.deinit(gpa);
    var live = try Store.init(gpa, feed.width, nch, std.math.maxInt(usize));
    defer live.deinit();
    var i: usize = 0;
    while (i < total) {
        const n: usize = @min(256, total - i);
        const s = first + @as(i64, @intCast(i));
        const rows = try feed.rows(s, data[i * nch ..][0 .. n * nch], words[i..][0..n]);
        try live.add(s, rows, words[i..][0..n]);
        i += n;
    }

    // Backfill only: newest hole first, until none is left.
    var filled = try Store.init(gpa, feed.width, nch, std.math.maxInt(usize));
    defer filled.deinit();
    var bf = try Backfill.init(gpa, &layout, &set, filled.generation);
    defer bf.deinit();
    try bf.open(dir, first);
    var steps: usize = 0;
    var buf: [4]Range = undefined;
    var top = end;
    while (true) : (steps += 1) {
        try testing.expect(steps < 10);
        const hs = filled.holes(.raw, first, end, &buf);
        if (hs.len == 0) break;
        // One hole, shrinking from the newest end: [first, where the last step began).
        try testing.expectEqual(1, hs.len);
        try testing.expectEqual(Range{ .lo = first, .hi = top }, hs[0]);
        var r = (try bf.step(.both, hs[0].lo, hs[0].hi, end)).?;
        defer r.deinit(gpa);
        try testing.expectEqual(@divFloor(top - 1, bucket) + 1, r.first_bucket + @as(i64, @intCast(r.count)));
        try filled.put(&r);
        top = r.first_bucket * bucket;
    }
    try testing.expectEqual(3, steps); // 5 s in 2 s steps
    try testing.expectEqual(0, filled.holes(.slots, first, end, &buf).len);
    // The raw part (and the TTL words) exactly.
    try expectSameHalf(&live.raw, &filled.raw);
    // The slots part: filtered afresh after a lead-in at the start of every step, where
    // the live filters ran through.
    const cmp = live.compare(&filled, .slots);
    try testing.expect(cmp.same_chunks);
    // Measured: exact. The lead-in is 0.05 s for a 300 Hz corner, over which the slowest
    // pole's transient decays by about e^-36, far below rounding to int16.
    try testing.expectEqual(0, cmp.worst);
    try testing.expectEqual(0, cmp.differ);

    // The panels change and the rows get wider (a third TTL lane): the slots part is
    // dropped, a result made before is refused, the backfill follows and fills it again.
    var before = (try bf.step(.slots, end - 6400, end, end)).?;
    defer before.deinit(gpa);
    set.items[1].rows = 3;
    set.items[1].ttl_lines[2] = 2;
    var probe2 = set;
    var feed2 = try @import("feed.zig").Feed.init(gpa, &layout, &probe2, 64, 64);
    const width2 = feed2.width;
    feed2.deinit(gpa);
    try testing.expectEqual(feed.width + 1, width2);
    const gen = try filled.resetSlots(width2);
    try testing.expectError(error.WrongWidth, filled.put(&before));
    try bf.follow(&set, gen);
    steps = 0;
    while (true) : (steps += 1) {
        try testing.expect(steps < 10);
        const hs = filled.holes(.slots, first, end, &buf);
        if (hs.len == 0) break;
        var r = (try bf.step(.slots, hs[0].lo, hs[0].hi, end)).?;
        defer r.deinit(gpa);
        try testing.expectEqual(width2, r.width);
        try filled.put(&r);
    }
    try testing.expectEqual(3, steps);
    // The new lane (line 2 was never high): its lowest level holds -ttl_level throughout.
    const low: i16 = @intFromFloat(-panels.ttl_level);
    try testing.expectEqual(Pair{ low, low }, filled.bucketValue(width2 - 1, 0, 1000).?);
    try expectSameHalf(&live.raw, &filled.raw);
}
