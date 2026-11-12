//! Scroll-back review: the display looking at an earlier stretch of the recording while
//! acquisition, the recorder and the live display's own history carry on.
//!
//! Old samples are read back from the recording's samples.i16 (and its TTL edge files) and
//! put through a feed of their own, set up exactly as the live one, so what review shows
//! is filtered, referenced and laid out as the live display would show it. The result goes
//! into a second sample history (a ring indexed by sample number, like the live one) that
//! the panels draw from while in review.
//!
//! The ring holds the stretch [lo, hi) of the recording. `fill` extends it towards what
//! the view needs, a bounded amount per call, so panning costs only the newly exposed
//! part and a long jump fills over a few frames. A stretch that does not continue where
//! the feed's filters left off is started with a lead-in (read and filtered, not kept), so
//! the filters have settled by the first sample that is shown.
//!
//! Only the recording's files are read, read-only; nothing here touches acquisition or
//! the recorder. If the recording has gaps (lost blocks), samples after a gap are shown
//! at the wrong time by the length of the gap.

const std = @import("std");
const types = @import("types.zig");
const panels = @import("panels.zig");
const Feed = @import("feed.zig").Feed;
const linux = std.os.linux;
const log = std.log.scoped(.review);

const chunk = 4096;

pub const Review = struct {
    gpa: std.mem.Allocator,
    nch: usize,
    fs: f64,
    layout: types.Layout,
    feed: Feed,
    /// What the feed was set up for (see `Panel.signalSignature`).
    signature: u64 = 0,
    /// The review history: `cap` rows of `feed.width`, indexed by sample number.
    ring: []i16,
    cap: usize,
    /// The stretch of the recording the ring holds.
    lo: i64 = 0,
    hi: i64 = 0,
    /// The sample the feed's filters are ready to continue at, if any.
    feed_at: ?i64 = null,
    samples_fd: i32 = -1,
    ttl_sample_fd: i32 = -1,
    ttl_word_fd: i32 = -1,
    /// The first sample in the file.
    first_sample: i64 = 0,
    read_buf: []i16,
    ttl_buf: []u16,
    /// The recording's TTL edges read so far (sample, word from that sample on).
    edge_samples: std.ArrayList(i64) = .empty,
    edge_words: std.ArrayList(u16) = .empty,

    /// `ring` is the review history (`cap` rows, a power of two). `set` gives the panels;
    /// their slots must be the live feed's (they are, when both are made from the same
    /// panels in the same order).
    pub fn init(gpa: std.mem.Allocator, layout: *const types.Layout, set: *const panels.Set, ring: []i16, cap: usize) !Review {
        var copy = set.*;
        var feed = try Feed.init(gpa, layout, &copy, chunk);
        errdefer feed.deinit(gpa);
        const read_buf = try gpa.alloc(i16, chunk * layout.numChannels());
        errdefer gpa.free(read_buf);
        return .{
            .gpa = gpa,
            .nch = layout.numChannels(),
            .fs = layout.sample_rate,
            .layout = layout.*,
            .feed = feed,
            .signature = signatureOf(set),
            .ring = ring,
            .cap = cap,
            .read_buf = read_buf,
            .ttl_buf = try gpa.alloc(u16, chunk),
        };
    }

    pub fn deinit(self: *Review) void {
        self.close();
        self.feed.deinit(self.gpa);
        self.gpa.free(self.read_buf);
        self.gpa.free(self.ttl_buf);
        self.edge_samples.deinit(self.gpa);
        self.edge_words.deinit(self.gpa);
    }

    fn signatureOf(set: *const panels.Set) u64 {
        var h: u64 = set.len;
        for (set.items[0..set.len]) |*p| h = h *% 0x9E3779B97F4A7C15 +% p.signalSignature();
        return h;
    }

    /// Follows a change of the panels' filters, rows or references: what the ring holds
    /// was made for the old ones and is dropped.
    pub fn follow(self: *Review, set: *const panels.Set) !void {
        const sig = signatureOf(set);
        if (sig == self.signature) return;
        var copy = set.*;
        const feed = try Feed.init(self.gpa, &self.layout, &copy, chunk);
        self.feed.deinit(self.gpa);
        self.feed = feed;
        self.signature = sig;
        self.invalidate();
    }

    pub fn invalidate(self: *Review) void {
        self.lo = 0;
        self.hi = 0;
        self.feed_at = null;
    }

    /// Opens the files of the recording in folder `dir` (the one that holds samples.i16),
    /// whose first sample is `first_sample`.
    pub fn open(self: *Review, dir: []const u8, first_sample: i64) !void {
        self.close();
        var buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const names = [_][]const u8{ "samples.i16", "ttl_sample.i64", "ttl_word.u16" };
        var fds: [3]i32 = @splat(-1);
        errdefer for (fds) |fd| {
            if (fd >= 0) _ = linux.close(fd);
        };
        for (names, &fds) |name, *fd| {
            const path = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, name }, 0);
            const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
            if (linux.errno(rc) != .SUCCESS) return error.CannotOpenRecording;
            fd.* = @intCast(rc);
        }
        self.samples_fd = fds[0];
        self.ttl_sample_fd = fds[1];
        self.ttl_word_fd = fds[2];
        self.first_sample = first_sample;
        self.edge_samples.clearRetainingCapacity();
        self.edge_words.clearRetainingCapacity();
        self.invalidate();
    }

    pub fn close(self: *Review) void {
        for ([_]*i32{ &self.samples_fd, &self.ttl_sample_fd, &self.ttl_word_fd }) |fd| {
            if (fd.* >= 0) _ = linux.close(fd.*);
            fd.* = -1;
        }
    }

    pub fn isOpen(self: *const Review) bool {
        return self.samples_fd >= 0;
    }

    /// Works towards the ring holding [want_lo, want_hi) (clipped to the recording, which
    /// ends before sample `end`), processing at most `budget` samples. True once it does.
    pub fn fill(self: *Review, want_lo_in: i64, want_hi_in: i64, end: i64, budget: usize) !bool {
        if (!self.isOpen()) return false;
        const want_hi = std.math.clamp(want_hi_in, self.first_sample, end);
        const want_lo = std.math.clamp(want_lo_in, self.first_sample, want_hi);
        if (want_hi - want_lo > @as(i64, @intCast(self.cap))) return error.WindowTooLong;
        // Nothing useful held (empty, or apart from what is wanted): start afresh there.
        if (self.hi == self.lo or want_hi < self.lo or want_lo > self.hi) {
            self.lo = want_lo;
            self.hi = want_lo;
            self.feed_at = null;
        }
        if (self.hi < want_hi) {
            const n: i64 = @min(@as(i64, @intCast(budget)), want_hi - self.hi);
            try self.process(self.hi, self.hi + n, self.feed_at != self.hi);
            self.hi += n;
            self.feed_at = self.hi;
            if (self.hi - self.lo > @as(i64, @intCast(self.cap))) self.lo = self.hi - @as(i64, @intCast(self.cap));
        } else if (self.lo > want_lo) {
            const n: i64 = @min(@as(i64, @intCast(budget)), self.lo - want_lo);
            try self.process(self.lo - n, self.lo, true);
            self.feed_at = self.lo;
            self.lo -= n;
            if (self.hi - self.lo > @as(i64, @intCast(self.cap))) self.hi = self.lo + @as(i64, @intCast(self.cap));
        }
        return self.lo <= want_lo and self.hi >= want_hi;
    }

    /// True if the ring holds all of [lo, hi) (clipped to the recording).
    pub fn holds(self: *const Review, lo: i64, hi: i64, end: i64) bool {
        const h = std.math.clamp(hi, self.first_sample, end);
        const l = std.math.clamp(lo, self.first_sample, h);
        return self.hi > self.lo and self.lo <= l and self.hi >= h;
    }

    /// How long the filters are run before a stretch that starts afresh: longer for low
    /// corners, 1 s at most.
    fn leadIn(self: *const Review) i64 {
        var slowest: f64 = 300;
        for (self.feed.slots[0..self.feed.num_slots]) |*s| {
            if (s.cfg.low_hz > 0) slowest = @min(slowest, s.cfg.low_hz);
        }
        return @intFromFloat(std.math.clamp(3.0 / slowest, 0.05, 1.0) * self.fs);
    }

    /// Reads [a, b) from the file, through the feed, into the ring. `fresh`: the feed does
    /// not continue from before `a`, so it is restarted and run over a lead-in first.
    fn process(self: *Review, a: i64, b: i64, fresh: bool) !void {
        try self.readEdges();
        var at = a;
        if (fresh) {
            self.feed.restart();
            at = @max(self.first_sample, a - self.leadIn());
        }
        const width = self.feed.width;
        const mask = self.cap - 1;
        while (at < b) {
            const n: usize = @intCast(@min(@as(i64, chunk), b - at));
            const samples = self.read_buf[0 .. n * self.nch];
            const bytes = std.mem.sliceAsBytes(samples);
            const offset: u64 = @intCast((at - self.first_sample) * @as(i64, @intCast(self.nch * 2)));
            var got: usize = 0;
            while (got < bytes.len) {
                const rc = linux.pread(self.samples_fd, bytes.ptr + got, bytes.len - got, @intCast(offset + got));
                if (linux.errno(rc) != .SUCCESS) return error.ReadFailed;
                if (rc == 0) return error.RecordingTooShort;
                got += rc;
            }
            self.words(at, self.ttl_buf[0..n]);
            const rows = try self.feed.rows(self.gpa, at, samples, self.ttl_buf[0..n]);
            // The lead-in is filtered but not kept.
            if (at + @as(i64, @intCast(n)) > a) {
                const skip: usize = if (at < a) @intCast(a - at) else 0;
                for (skip..n) |i| {
                    const pos: usize = @intCast(@as(u64, @bitCast(at + @as(i64, @intCast(i)))) & mask);
                    @memcpy(self.ring[pos * width ..][0..width], rows[i * width ..][0..width]);
                }
            }
            at += @intCast(n);
        }
    }

    /// Reads the TTL edges written since the last look.
    fn readEdges(self: *Review) !void {
        while (true) {
            var s: [512]i64 = undefined;
            var w: [512]u16 = undefined;
            const have = self.edge_samples.items.len;
            const rs = linux.pread(self.ttl_sample_fd, std.mem.asBytes(&s), @sizeOf(@TypeOf(s)), @intCast(have * 8));
            const rw = linux.pread(self.ttl_word_fd, std.mem.asBytes(&w), @sizeOf(@TypeOf(w)), @intCast(have * 2));
            if (linux.errno(rs) != .SUCCESS or linux.errno(rw) != .SUCCESS) return;
            const n = @min(rs / 8, rw / 2);
            if (n == 0) return;
            try self.edge_samples.appendSlice(self.gpa, s[0..n]);
            try self.edge_words.appendSlice(self.gpa, w[0..n]);
            if (n < s.len) return;
        }
    }

    /// The digital input word of each sample from `first` on, from the edges.
    fn words(self: *const Review, first: i64, out: []u16) void {
        const es = self.edge_samples.items;
        const ew = self.edge_words.items;
        // The last edge at or before `first`.
        var lo: usize = 0;
        var hi: usize = es.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (es[mid] <= first) lo = mid + 1 else hi = mid;
        }
        var next = lo; // the first edge after `first`
        var word: u16 = if (lo > 0) ew[lo - 1] else 0;
        for (out, 0..) |*o, i| {
            const n = first + @as(i64, @intCast(i));
            while (next < es.len and es[next] <= n) : (next += 1) word = ew[next];
            o.* = word;
        }
    }
};

const testing = std.testing;

test "review reads a recording back through the feed, in pieces, in any order" {
    const gpa = testing.allocator;
    var layout: types.Layout = .{ .sample_rate = 30000, .hw_clock_hz = 50e6 };
    layout.headstages[0] = .{ .slot = 0, .chip = "RHD2132", .num_channels = 2, .first_channel = 0, .has_bno = false };
    layout.num_headstages = 1;
    layout.num_electrodes = 2;
    var set = panels.default(&layout);
    // Row 1 as acquired, row 2 through 300 Hz to 6 kHz; and a lane for TTL line 2.
    set.items[0].filtered = true;
    set.items[0].raw_rows.set(0, true);
    set.items[1] = set.items[0];
    set.items[1].kind = .ttl;
    set.items[1].rows = 1;
    set.items[1].ttl_lines[0] = 2;
    set.len = 2;

    // A recording of 40,000 samples starting at sample 5000: channel 1 counts, channel 2
    // is a 1 kHz sine on an offset; TTL line 2 is high from 20,000 to 20,300.
    const first: i64 = 5000;
    const total = 40000;
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buf, "/tmp/oez-review-test-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(dir, 0o700);
    defer {
        inline for (.{ "samples.i16", "ttl_sample.i64", "ttl_word.u16" }) |name| {
            var b: [96:0]u8 = undefined;
            _ = linux.unlink(std.fmt.bufPrintSentinel(&b, "{s}/{s}", .{ dir, name }, 0) catch unreachable);
        }
        _ = linux.rmdir(dir);
    }
    {
        const data = try gpa.alloc(i16, total * 2);
        defer gpa.free(data);
        for (0..total) |i| {
            data[2 * i] = @intCast(@mod(first + @as(i64, @intCast(i)), 30000));
            data[2 * i + 1] = @intFromFloat(5000.0 + 1000.0 * @sin(2.0 * std.math.pi * 1000.0 * @as(f64, @floatFromInt(i)) / 30000.0));
        }
        const es = [_]i64{ first, 20000, 20300 };
        const ew = [_]u16{ 0, 2, 0 };
        inline for (.{ "samples.i16", "ttl_sample.i64", "ttl_word.u16" }, .{ std.mem.sliceAsBytes(data), std.mem.asBytes(&es), std.mem.asBytes(&ew) }) |name, bytes| {
            var b: [96:0]u8 = undefined;
            const path = try std.fmt.bufPrintSentinel(&b, "{s}/{s}", .{ dir, name }, 0);
            const fd: i32 = @intCast(linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600));
            var done: usize = 0;
            while (done < bytes.len) done += linux.write(fd, bytes.ptr + done, bytes.len - done);
            _ = linux.close(fd);
        }
    }

    const cap = 16384;
    var probe = set;
    var live = try Feed.init(gpa, &layout, &probe, 64);
    defer live.deinit(gpa);
    const ring = try gpa.alloc(i16, cap * live.width);
    defer gpa.free(ring);
    @memset(ring, 0);
    var rv = try Review.init(gpa, &layout, &set, ring, cap);
    defer rv.deinit();
    try testing.expectEqual(live.width, rv.feed.width);
    try rv.open(dir, first);
    const end = first + total;
    const width = rv.feed.width;
    const at = struct {
        fn f(r: []const i16, w: usize, sample: i64, col: usize) i16 {
            return r[@as(usize, @intCast(@mod(sample, cap))) * w + col];
        }
    }.f;

    // A window in the middle, a quarter second at a time.
    var calls: usize = 0;
    while (!try rv.fill(18000, 24000, end, 2000)) calls += 1;
    try testing.expect(calls >= 2);
    try testing.expect(rv.holds(18000, 24000, end));
    // Column 0, 1: as acquired. Column 2: row 1 again (shown raw). Column 3: row 2
    // filtered: the offset gone, the sine there. Column 4: the lane.
    for ([_]i64{ 18000, 19999, 20000, 23999 }) |s| {
        try testing.expectEqual(@as(i16, @intCast(@mod(s, 30000))), at(ring, width, s, 0));
        try testing.expectEqual(at(ring, width, s, 0), at(ring, width, s, 2));
    }
    var peak: i32 = 0;
    var s: i64 = 18000;
    while (s < 24000) : (s += 1) peak = @max(peak, @as(i32, @intCast(@abs(at(ring, width, s, 3)))));
    try testing.expect(peak > 900 and peak < 1100); // settled from the first sample shown
    try testing.expect(at(ring, width, 19999, 4) < 0 and at(ring, width, 20000, 4) > 0 and at(ring, width, 20299, 4) > 0 and at(ring, width, 20300, 4) < 0);

    // Panning back a little fills only what is new, and keeps the rest.
    try testing.expect(try rv.fill(17000, 23000, end, 100000));
    try testing.expectEqual(17000, rv.lo);
    try testing.expectEqual(24000, rv.hi);
    try testing.expectEqual(@as(i16, 17000), at(ring, width, 17000, 0));
    // A jump elsewhere starts afresh; the start and the end of the recording clip.
    try testing.expect(try rv.fill(0, 8000, end, 100000));
    try testing.expectEqual(first, rv.lo);
    try testing.expect(try rv.fill(end - 3000, end + 9000, end, 100000));
    try testing.expectEqual(end, rv.hi);
    try testing.expectEqual(@as(i16, @intCast(@mod(end - 1, 30000))), at(ring, width, end - 1, 0));
    // A change of the panels' filters drops what is held.
    set.items[0].raw_rows.set(1, true);
    try rv.follow(&set);
    try testing.expect(!rv.holds(end - 3000, end, end));
    try testing.expect(try rv.fill(end - 3000, end, end, 100000));
    try testing.expectEqual(at(ring, width, end - 10, 1), at(ring, width, end - 10, 3));
}
