//! The overview: the pyramid store (`pyramid.zig`) kept up to date while a recording runs,
//! so the display can draw the min and max per pixel column of any stretch, up to hours,
//! in about a millisecond.
//!
//! Two threads. The display thread owns the store: it adds the live feed's history rows
//! (`add`), and once per frame (`turn`) notices a change of the panels, takes finished
//! buckets in, and asks for the next hole. A backfill thread at `SCHED_IDLE` owns a
//! `pyramid.Backfill`, which reads the recording's files read-only and makes the buckets
//! of a hole: one step (at most 2 s of samples) per request, then a 10 ms pause. Between
//! them, two single-producer single-consumer queues (`events.Spsc`) and a futex word to
//! wake the thread; no lock the display thread could wait on.
//!
//! Holes are what the store lacks of [first sample, `file_end`): the recording's start
//! before the display's rows came (or before `begin`), blocks the display missed, and the
//! whole slots part after the panels change. The hole that overlaps what the view shows
//! (`want`) goes first, else the newest.
//!
//! Nothing here touches acquisition or the recorder. If something fails (the recording
//! cannot be opened or read, no memory), a warning is logged once and the overview goes
//! inactive for the rest of the recording; nothing else is affected.

const std = @import("std");
const types = @import("types.zig");
const panels = @import("panels.zig");
const pyramid = @import("pyramid.zig");
const events = @import("events.zig");
const clock = @import("clock.zig");
const Atomic = std.atomic.Value;
const linux = std.os.linux;
const log = std.log.scoped(.overview);

/// A hole for the thread: make the buckets of its newest end (`Backfill.step`).
const Hole = struct {
    parts: pyramid.Parts,
    lo: i64,
    hi: i64,
    /// The recording's flushed length when asked (the step reads nothing past it).
    end: i64,
};

const Request = union(enum) {
    hole: Hole,
    /// The panels changed; the store's slots part is at `generation` now.
    follow: struct { set: panels.Set, generation: u32 },
};

const Result = union(enum) {
    buckets: pyramid.Buckets,
    /// No whole bucket of the hole is in the file yet.
    none,
    /// The file is shorter than the `end` it was asked with: refused, asked again later.
    short,
};

/// What both threads see. On the heap, so it stays put while the `Overview` moves.
const Shared = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    layout: types.Layout,
    /// The panels and slots generation the thread starts with.
    set: panels.Set,
    generation: u32,
    dir_buf: [std.fs.max_path_bytes]u8 = undefined,
    dir_len: usize = 0,
    first_sample: i64,
    requests: events.Spsc(Request, 8) = .{},
    results: events.Spsc(Result, 8) = .{},
    /// Bumped (and futex-woken) for every request and for `stop`.
    wake: Atomic(u32) = .init(0),
    stop: Atomic(bool) = .init(false),
    /// Set by the thread when it could not go on (it has stopped); `failure` says why.
    failed: Atomic(bool) = .init(false),
    failure: anyerror = error.Unexpected,
    /// `Backfill.step` calls made.
    steps: Atomic(u64) = .init(0),

    fn poke(self: *Shared) void {
        _ = self.wake.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.wake.raw, 1);
    }

    fn fail(self: *Shared, e: anyerror) void {
        self.failure = e;
        self.failed.store(true, .release);
    }
};

/// The backfill thread.
fn run(sh: *Shared) void {
    // Idle priority: it gets only what nothing else wants. Not fatal if refused.
    const rc = linux.sched_setscheduler(0, .{ .mode = .IDLE }, &.{ .priority = 0 });
    if (linux.errno(rc) != .SUCCESS) log.warn("backfill thread: could not get SCHED_IDLE (errno {t})", .{linux.errno(rc)});
    var bf = pyramid.Backfill.init(sh.gpa, &sh.layout, &sh.set, sh.generation) catch |e| return sh.fail(e);
    defer bf.deinit();
    bf.open(sh.dir_buf[0..sh.dir_len], sh.first_sample) catch |e| return sh.fail(e);
    while (!sh.stop.load(.acquire)) {
        const seen = sh.wake.load(.acquire);
        const req = sh.requests.pop() orelse {
            // Nothing to do: sleep until poked (or a while, whichever is first).
            sh.io.futexWaitTimeout(u32, &sh.wake.raw, seen, .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } }) catch {};
            continue;
        };
        switch (req) {
            .follow => |f| bf.follow(&f.set, f.generation) catch |e| return sh.fail(e),
            .hole => |h| {
                const made = bf.step(h.parts, h.lo, h.hi, h.end);
                _ = sh.steps.fetchAdd(1, .monotonic);
                const r: Result = if (made) |m| (if (m) |b| .{ .buckets = b } else .none) else |e| switch (e) {
                    error.RecordingTooShort => .short,
                    else => return sh.fail(e),
                };
                if (!sh.results.push(r)) {
                    // Cannot happen (one hole is asked at a time); never leak.
                    var x = r;
                    if (x == .buckets) x.buckets.deinit(sh.gpa);
                }
                sh.io.sleep(.fromMilliseconds(10), .awake) catch {};
            },
        }
    }
}

fn signatureOf(set: *const panels.Set) u64 {
    var h: u64 = set.len;
    for (set.items[0..set.len]) |*p| h = h *% 0x9E3779B97F4A7C15 +% p.signalSignature();
    return h;
}

fn overlap(a: pyramid.Range, b: pyramid.Range) ?pyramid.Range {
    const lo = @max(a.lo, b.lo);
    const hi = @min(a.hi, b.hi);
    return if (lo < hi) .{ .lo = lo, .hi = hi } else null;
}

pub const Overview = struct {
    /// Must be thread-safe: buckets are made on the backfill thread and freed here.
    gpa: std.mem.Allocator,
    io: std.Io,
    layout: types.Layout,
    budget: usize,
    store: ?pyramid.Store = null,
    shared: ?*Shared = null,
    thread: ?std.Thread = null,
    first_sample: i64 = 0,
    /// The flushed length the last `turn` was given.
    file_end: i64 = 0,
    /// What the store's slots part was made for.
    signature: u64 = 0,
    /// The hole asked for and not answered yet (one at a time).
    in_flight: ?Hole = null,
    /// A change of the panels the thread has not been told of (its queue was full).
    follow_pending: bool = false,
    /// After a refused (file too short) or empty answer: ask nothing before this time
    /// (empty: or until `file_end` moves past `paused_end`).
    pause_until: i128 = 0,
    paused_end: ?i64 = null,
    /// How long to wait before asking again after a refused or empty step.
    retry_ns: i128 = std.time.ns_per_s,
    warned_short: bool = false,
    stats: Stats = .{},

    pub const Stats = struct {
        requests: u64 = 0,
        /// Results taken into the store, and results refused by it (made for panels that
        /// have changed since; their hole is asked for again).
        accepted: u64 = 0,
        refused: u64 = 0,
        /// Steps that found no whole bucket, and steps refused because the file was short.
        empty: u64 = 0,
        short: u64 = 0,
        /// Level-0 buckets made with the raw part (accepted or not).
        raw_buckets: u64 = 0,
        /// `add` calls whose rows did not have the store's width (left as holes).
        skipped_adds: u64 = 0,
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, layout: *const types.Layout, budget_bytes: usize) !Overview {
        return .{ .gpa = gpa, .io = io, .layout = layout.*, .budget = budget_bytes };
    }

    /// Stops the thread.
    pub fn deinit(self: *Overview) void {
        self.end();
    }

    /// A recording has started: its folder, its first sample. Starts the store and the
    /// backfill thread. `set` and `width` as the live feed has them.
    pub fn begin(self: *Overview, dir: []const u8, first_sample: i64, set: *const panels.Set, width: usize) !void {
        self.end();
        const nch = self.layout.numChannels();
        if (width < nch) return error.BadWidth;
        if (dir.len > std.fs.max_path_bytes) return error.NameTooLong;
        var store = try pyramid.Store.init(self.gpa, width, nch, self.budget);
        errdefer store.deinit();
        const sh = try self.gpa.create(Shared);
        errdefer self.gpa.destroy(sh);
        sh.* = .{
            .gpa = self.gpa,
            .io = self.io,
            .layout = self.layout,
            .set = set.*,
            .generation = store.generation,
            .first_sample = first_sample,
        };
        @memcpy(sh.dir_buf[0..dir.len], dir);
        sh.dir_len = dir.len;
        const thread = try std.Thread.spawn(.{}, run, .{sh});
        thread.setName(self.io, "overview") catch {};
        self.* = .{
            .gpa = self.gpa,
            .io = self.io,
            .layout = self.layout,
            .budget = self.budget,
            .retry_ns = self.retry_ns,
            .store = store,
            .shared = sh,
            .thread = thread,
            .first_sample = first_sample,
            .signature = signatureOf(set),
        };
    }

    /// The recording has ended (or review must let go): thread stopped, store freed. The
    /// thread finishes the step it is in (at most 2 s of samples) first.
    pub fn end(self: *Overview) void {
        if (self.shared) |sh| {
            sh.stop.store(true, .release);
            sh.poke();
            if (self.thread) |t| t.join();
            while (sh.results.pop()) |r| {
                var x = r;
                if (x == .buckets) x.buckets.deinit(self.gpa);
            }
            self.gpa.destroy(sh);
        }
        if (self.store) |*s| s.deinit();
        self.store = null;
        self.shared = null;
        self.thread = null;
        self.in_flight = null;
        self.follow_pending = false;
        self.paused_end = null;
        self.pause_until = 0;
    }

    pub fn active(self: *const Overview) bool {
        return self.shared != null;
    }

    fn fail(self: *Overview, what: []const u8, e: anyerror) void {
        log.warn("overview off for this recording: {s}: {t}", .{ what, e });
        self.end();
    }

    /// Live history rows from the display's feed, with their TTL words (one per row).
    /// Display thread. Rows of another width than the store's (the panels changed and
    /// `turn` has not seen it yet) are left out: they become a hole, filled later.
    pub fn add(self: *Overview, first: i64, rows: []const i16, ttl: []const u16) void {
        const s = if (self.store) |*st| st else return;
        const n = if (ttl.len != 0) ttl.len else rows.len / s.width;
        if (rows.len != n * s.width) {
            self.stats.skipped_adds += 1;
            return;
        }
        s.add(first, rows, ttl) catch |e| switch (e) {
            error.NegativeSample => {},
            else => self.fail("adding rows", e),
        };
    }

    /// Once per frame, display thread. Notices that the panels' signals changed
    /// (signature or width): drops the slots part and tells the thread. Takes finished
    /// buckets from the thread into the store. If the thread is idle and holes remain in
    /// [first_sample, file_end), asks for the next one: a hole that overlaps `want` first
    /// (what the view is showing), else the newest. `hold`: the recorder is behind; ask
    /// for nothing this turn.
    ///
    /// `set` and `width` must be those of the feed whose rows `add` is given from now on.
    /// `file_end` must be a flushed length: the recorder's count of samples written. If
    /// the file turns out shorter (the count ran ahead of the file, or a wrong count), the
    /// step that reads past its end fails with `error.RecordingTooShort` in the thread:
    /// that step is refused (nothing is put, a warning is logged the first time), and
    /// nothing is asked for `retry_ns`; then the hole is asked for again.
    pub fn turn(self: *Overview, set: *const panels.Set, width: usize, file_end: i64, want: ?pyramid.Range, hold: bool) void {
        const sh = self.shared orelse return;
        if (sh.failed.load(.acquire)) return self.fail("backfill", sh.failure);
        const store = &self.store.?;
        self.file_end = file_end;

        // The panels changed: the slots part is made again, by the thread for what is
        // past, by `add` from now on.
        const sig = signatureOf(set);
        if (sig != self.signature or width != store.width) {
            if (width < store.nch) return self.fail("panels", error.BadWidth);
            _ = store.resetSlots(width) catch |e| return self.fail("panels", e);
            self.signature = sig;
            self.follow_pending = true;
        }
        if (self.follow_pending) {
            if (sh.requests.push(.{ .follow = .{ .set = set.*, .generation = store.generation } })) {
                self.follow_pending = false;
                sh.poke();
            }
        }

        // Finished work.
        while (sh.results.pop()) |r| {
            self.in_flight = null;
            switch (r) {
                .buckets => |b_| {
                    var b = b_;
                    defer b.deinit(self.gpa);
                    if (b.parts.has(.raw)) self.stats.raw_buckets += b.count;
                    if (store.put(&b)) |_| {
                        self.stats.accepted += 1;
                    } else |e| switch (e) {
                        error.Stale, error.WrongWidth => {
                            // Made for the panels as they were: the hole stays, asked again.
                            // Made for the panels as they are and still the wrong width:
                            // `width` does not belong to `set`.
                            if (b.generation == store.generation) return self.fail("backfill width", e);
                            self.stats.refused += 1;
                        },
                        else => return self.fail("taking buckets", e),
                    }
                },
                .none => {
                    self.stats.empty += 1;
                    self.pause_until = clock.nowNs() + self.retry_ns;
                    self.paused_end = file_end;
                },
                .short => {
                    self.stats.short += 1;
                    if (!self.warned_short) log.warn("recording file shorter than its count of samples written; backfill retried later", .{});
                    self.warned_short = true;
                    self.pause_until = clock.nowNs() + self.retry_ns;
                    self.paused_end = null;
                },
            }
        }

        // The next hole.
        if (hold or self.in_flight != null or self.follow_pending) return;
        if (clock.nowNs() < self.pause_until) {
            const moved = if (self.paused_end) |e| file_end != e else false;
            if (!moved) return;
        }
        const h = self.next(want) orelse return;
        if (sh.requests.push(.{ .hole = h })) {
            self.in_flight = h;
            self.stats.requests += 1;
            sh.poke();
        }
    }

    /// The hole to ask for: within `want` if a hole overlaps it (the newest such), else
    /// the newest; for both parts where both lack it.
    fn next(self: *const Overview, want: ?pyramid.Range) ?Hole {
        const store = &self.store.?;
        var buf: [2][64]pyramid.Range = undefined;
        const lists = [2][]pyramid.Range{
            store.holes(.raw, self.first_sample, self.file_end, &buf[0]),
            store.holes(.slots, self.first_sample, self.file_end, &buf[1]),
        };
        var pick: ?pyramid.Range = null;
        var part: usize = 0;
        if (want) |w| {
            for (lists, 0..) |list, p| {
                for (list) |h| {
                    const o = overlap(h, w) orelse continue;
                    if (pick == null or o.hi > pick.?.hi) {
                        pick = o;
                        part = p;
                    }
                }
            }
        }
        if (pick == null) {
            for (lists, 0..) |list, p| {
                if (list.len > 0 and (pick == null or list[0].hi > pick.?.hi)) {
                    pick = list[0];
                    part = p;
                }
            }
        }
        var r = pick orelse return null;
        // Where the other part lacks it too: both at once (the newest such stretch).
        var both: ?pyramid.Range = null;
        for (lists[1 - part]) |h| {
            const o = overlap(h, r) orelse continue;
            if (both == null or o.hi > both.?.hi) both = o;
        }
        if (both) |b| r = b;
        return .{
            .parts = if (both != null) .both else if (part == 0) .raw else .slots,
            .lo = r.lo,
            .hi = r.hi,
            .end = self.file_end,
        };
    }

    /// As `Store.columns`. False while not active.
    pub fn columns(self: *const Overview, lo: i64, hi: i64, cols: usize, history_columns: []const usize, out: []pyramid.Pair) bool {
        const s = if (self.store) |*st| st else return false;
        return s.columns(lo, hi, cols, history_columns, out);
    }

    /// Holes remain in [first_sample, file_end) (for a "building" badge).
    pub fn building(self: *const Overview) bool {
        const s = if (self.store) |*st| st else return false;
        var buf: [1]pyramid.Range = undefined;
        return s.holes(.raw, self.first_sample, self.file_end, &buf).len > 0 or
            s.holes(.slots, self.first_sample, self.file_end, &buf).len > 0;
    }

    pub fn bytes(self: *const Overview) usize {
        const s = if (self.store) |*st| st else return 0;
        return s.bytes();
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Feed = @import("feed.zig").Feed;

const test_nch = 5;

fn testLayout() types.Layout {
    var layout: types.Layout = .{ .sample_rate = 30000, .hw_clock_hz = 50e6 };
    layout.headstages[0] = .{ .slot = 0, .chip = "RHD2132", .num_channels = 4, .first_channel = 0, .has_bno = false };
    layout.num_headstages = 1;
    layout.num_electrodes = 4;
    layout.num_adc = 1;
    return layout;
}

/// Band-passed 300 Hz to 6 kHz, row 3 as acquired, referenced to rows 1, 2 and 4,
/// subtracted from rows 1 to 3; and a panel of two TTL lanes (lines 1 and 4).
fn testSet(layout: *const types.Layout) panels.Set {
    var set = panels.default(layout, .scroll);
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
    return set;
}

fn feedWidth(layout: *const types.Layout, set: *const panels.Set) !usize {
    var probe = set.*;
    var f = try Feed.init(testing.allocator, layout, &probe, 64, 64);
    defer f.deinit(testing.allocator);
    return f.width;
}

/// A recording in a temporary folder: `total` samples from `first`, written up to
/// `written` (the rest can be written later, `writeRest`).
const TestRec = struct {
    gpa: std.mem.Allocator,
    dir_buf: [80:0]u8 = undefined,
    dir_len: usize = 0,
    first: i64,
    end: i64,
    data: []i16,
    words: []u16,

    fn dir(self: *const TestRec) [:0]const u8 {
        return self.dir_buf[0..self.dir_len :0];
    }

    fn init(gpa: std.mem.Allocator, tag: []const u8, first: i64, total: usize, written: usize) !TestRec {
        var self: TestRec = .{
            .gpa = gpa,
            .first = first,
            .end = first + @as(i64, @intCast(total)),
            .data = try gpa.alloc(i16, total * test_nch),
            .words = undefined,
        };
        errdefer gpa.free(self.data);
        self.words = try gpa.alloc(u16, total);
        errdefer gpa.free(self.words);
        for (0..total) |i| {
            const s = first + @as(i64, @intCast(i));
            const t = @as(f64, @floatFromInt(s)) / 30000.0;
            const common = 2000.0 * @sin(2.0 * std.math.pi * 50.0 * t);
            var z: u64 = @as(u64, @bitCast(s)) *% 0x9E3779B97F4A7C15;
            for (0..4) |c| {
                z = (z ^ (z >> 29)) *% 0xBF58476D1CE4E5B9 +% c;
                const cf: f64 = @floatFromInt(c);
                const own = 600.0 * @sin(2.0 * std.math.pi * (900.0 + 130.0 * cf) * t) + 1000.0 * cf;
                const noise: f64 = @floatFromInt(@as(i64, @intCast((z >> 40) % 301)) - 150);
                self.data[i * test_nch + c] = @intFromFloat(@round(common + own + noise));
            }
            self.data[i * test_nch + 4] = @intCast(@mod(s, 20000) - 10000);
            var w: u16 = if (@mod(@divFloor(s, 210), 2) == 1) 1 else 0;
            if (@mod(s, 9001) < 300) w |= 8;
            self.words[i] = w;
        }
        const d = try std.fmt.bufPrintSentinel(&self.dir_buf, "/tmp/dimna-overview-test-{d}-{s}", .{ linux.getpid(), tag }, 0);
        self.dir_len = d.len;
        _ = linux.mkdir(self.dir(), 0o700);
        try self.write(written);
        return self;
    }

    /// Writes the files with the first `n` samples.
    fn write(self: *TestRec, n: usize) !void {
        var es: std.ArrayList(i64) = .empty;
        defer es.deinit(self.gpa);
        var ew: std.ArrayList(u16) = .empty;
        defer ew.deinit(self.gpa);
        for (self.words[0..n], 0..) |w, i| {
            if (i == 0 or w != self.words[i - 1]) {
                try es.append(self.gpa, self.first + @as(i64, @intCast(i)));
                try ew.append(self.gpa, w);
            }
        }
        inline for (
            .{ "samples.i16", "ttl_sample.i64", "ttl_word.u16" },
            .{ std.mem.sliceAsBytes(self.data[0 .. n * test_nch]), std.mem.sliceAsBytes(es.items), std.mem.sliceAsBytes(ew.items) },
        ) |name, bytes_| {
            var b: [128:0]u8 = undefined;
            const path = try std.fmt.bufPrintSentinel(&b, "{s}/{s}", .{ self.dir(), name }, 0);
            const fd: i32 = @intCast(linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600));
            defer _ = linux.close(fd);
            var done: usize = 0;
            while (done < bytes_.len) done += linux.write(fd, bytes_.ptr + done, bytes_.len - done);
        }
    }

    fn deinit(self: *TestRec) void {
        inline for (.{ "samples.i16", "ttl_sample.i64", "ttl_word.u16" }) |name| {
            var b: [128:0]u8 = undefined;
            _ = linux.unlink(std.fmt.bufPrintSentinel(&b, "{s}/{s}", .{ self.dir(), name }, 0) catch unreachable);
        }
        _ = linux.rmdir(self.dir());
        self.gpa.free(self.data);
        self.gpa.free(self.words);
    }
};

/// The live feed: runs over the whole recording in blocks of 256, handing each block's
/// rows to `sink` (a store, an overview, or both).
const LiveFeed = struct {
    feed: Feed,
    rec: *const TestRec,
    at: usize = 0,

    fn init(layout: *const types.Layout, set: *const panels.Set, rec: *const TestRec) !LiveFeed {
        var probe = set.*;
        return .{ .feed = try Feed.init(testing.allocator, layout, &probe, 4096, 256), .rec = rec };
    }

    fn deinit(self: *LiveFeed) void {
        self.feed.deinit(testing.allocator);
    }

    fn done(self: *const LiveFeed) bool {
        return self.at >= self.rec.words.len;
    }

    /// The next block: its first sample, rows and words.
    fn next(self: *LiveFeed) !struct { first: i64, rows: []const i16, words: []const u16 } {
        const n: usize = @min(256, self.rec.words.len - self.at);
        const s = self.rec.first + @as(i64, @intCast(self.at));
        const words = self.rec.words[self.at..][0..n];
        const rows = try self.feed.rows(s, self.rec.data[self.at * test_nch ..][0 .. n * test_nch], words);
        self.at += n;
        return .{ .first = s, .rows = rows, .words = words };
    }
};

/// A store filled live from the recording's start through a feed with `set`.
fn liveStore(layout: *const types.Layout, set: *const panels.Set, rec: *const TestRec) !pyramid.Store {
    var lf = try LiveFeed.init(layout, set, rec);
    defer lf.deinit();
    var store = try pyramid.Store.init(testing.allocator, lf.feed.width, test_nch, std.math.maxInt(usize));
    errdefer store.deinit();
    while (!lf.done()) {
        const b = try lf.next();
        try store.add(b.first, b.rows, b.words);
    }
    return store;
}

fn expectSameStore(want: *const pyramid.Store, got: *const pyramid.Store) !void {
    const raw = want.compare(got, .raw);
    try testing.expect(raw.same_chunks);
    try testing.expect(raw.same_ttl);
    try testing.expectEqual(0, raw.differ);
    const slots = want.compare(got, .slots);
    try testing.expect(slots.same_chunks);
    // Exact: each step's lead-in (0.05 s at a 300 Hz corner) settles the filters far
    // below one LSB (as in pyramid.zig's backfill test).
    try testing.expectEqual(0, slots.worst);
}

/// Time limits: a hang fails the test instead of hanging the run.
fn deadline(seconds: i128) i128 {
    return clock.nowNs() + seconds * std.time.ns_per_s;
}

fn nap() void {
    testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
}

test "rows from the middle on, the rest backfilled through the thread: equal to a store filled live from the start" {
    const gpa = testing.allocator;
    const layout = testLayout();
    const set = testSet(&layout);
    const width = try feedWidth(&layout, &set);
    // 7 s from sample 5000 (mid-bucket).
    var rec = try TestRec.init(gpa, "middle", 5000, 210_000, 210_000);
    defer rec.deinit();
    var want = try liveStore(&layout, &set, &rec);
    defer want.deinit();

    var ov = try Overview.init(gpa, testing.io, &layout, std.math.maxInt(usize));
    defer ov.deinit();
    // The display's feed has run from the start; the overview begins 3.5 s in (not on a
    // bucket boundary) and from then on gets every block, while the file grows.
    var lf = try LiveFeed.init(&layout, &set, &rec);
    defer lf.deinit();
    while (lf.at < 105_017) _ = try lf.next();
    try ov.begin(rec.dir(), rec.first, &set, width);
    try testing.expect(ov.active());
    const until = deadline(60);
    while (!lf.done() or ov.building()) {
        if (clock.nowNs() > until) return error.Timeout;
        if (!lf.done()) {
            const b = try lf.next();
            ov.add(b.first, b.rows, b.words);
        }
        ov.turn(&set, width, rec.first + @as(i64, @intCast(lf.at)), null, false);
        nap();
    }
    try testing.expect(ov.active());
    try testing.expect(ov.stats.requests >= 2 and ov.stats.accepted >= 2);
    try testing.expectEqual(0, ov.stats.refused);
    try expectSameStore(&want, &ov.store.?);
    // The overview answers for the whole recording, live part and backfilled part.
    var out: [100 * 2]pyramid.Pair = undefined;
    try testing.expect(ov.columns(rec.first, rec.end, 100, &.{ 0, width - 1 }, &out));
    try testing.expect(ov.bytes() > 0);
}

test "the hole the view shows is filled before a newer one" {
    const gpa = testing.allocator;
    const layout = testLayout();
    const set = testSet(&layout);
    const width = try feedWidth(&layout, &set);
    var rec = try TestRec.init(gpa, "want", 5000, 240_000, 240_000);
    defer rec.deinit();
    var want_store = try liveStore(&layout, &set, &rec);
    defer want_store.deinit();

    var ov = try Overview.init(gpa, testing.io, &layout, std.math.maxInt(usize));
    defer ov.deinit();
    try ov.begin(rec.dir(), rec.first, &set, width);
    // Rows for [2 s, 4 s) and [6 s, 8 s): holes [0, 2 s) (older) and [4 s, 6 s) (newer).
    var lf = try LiveFeed.init(&layout, &set, &rec);
    defer lf.deinit();
    const s2 = rec.first + 60_000;
    const s4 = rec.first + 120_000;
    const s6 = rec.first + 180_000;
    while (!lf.done()) {
        const b = try lf.next();
        if ((b.first >= s2 and b.first < s4) or b.first >= s6) ov.add(b.first, b.rows, b.words);
    }
    // (The blocks are 256 long and the edges not multiples of it: the holes end where
    // the first block at or after each edge begins.)
    var hb: [4]pyramid.Range = undefined;
    const before = ov.store.?.holes(.raw, rec.first, rec.end, &hb);
    try testing.expectEqual(2, before.len);
    const newer = before[0];
    try testing.expect(newer.lo >= s4 and newer.hi >= s6);
    // The view shows a stretch inside the older hole.
    const view: pyramid.Range = .{ .lo = rec.first + 15_000, .hi = rec.first + 45_000 };
    var out: [100 * 2]pyramid.Pair = undefined;
    const until = deadline(60);
    var view_done = false;
    // (`building` knows `file_end` from the first `turn`.)
    ov.turn(&set, width, rec.end, view, false);
    try testing.expect(ov.building());
    while (ov.building()) {
        if (clock.nowNs() > until) return error.Timeout;
        ov.turn(&set, width, rec.end, view, false);
        if (!view_done and ov.columns(view.lo, view.hi, 100, &.{ 0, width - 1 }, &out)) {
            view_done = true;
            // The newer hole has not been touched yet.
            var nb: [4]pyramid.Range = undefined;
            var found = false;
            for (ov.store.?.holes(.raw, rec.first, rec.end, &nb)) |h| found = found or std.meta.eql(h, newer);
            try testing.expect(found);
        }
        nap();
    }
    try testing.expect(view_done);
    try expectSameStore(&want_store, &ov.store.?);
}

test "a change of the panels mid-backfill: the slots part made again, the raw part not redone" {
    const gpa = testing.allocator;
    const layout = testLayout();
    const set_a = testSet(&layout);
    // B: a third lane, and other corners.
    var set_b = set_a;
    set_b.items[1].rows = 3;
    set_b.items[1].ttl_lines[2] = 2;
    set_b.items[0].filter.low_hz = 500;
    set_b.items[0].filter.high_hz = 3000;
    const width_a = try feedWidth(&layout, &set_a);
    const width_b = try feedWidth(&layout, &set_b);
    try testing.expectEqual(width_a + 1, width_b);
    var rec = try TestRec.init(gpa, "change", 5000, 210_040, 210_040); // ends on a bucket boundary
    defer rec.deinit();
    var want = try liveStore(&layout, &set_b, &rec);
    defer want.deinit();

    var ov = try Overview.init(gpa, testing.io, &layout, std.math.maxInt(usize));
    defer ov.deinit();
    try ov.begin(rec.dir(), rec.first, &set_a, width_a);
    // Live rows (panels A) for the second half: a raw hole of 3.5 s (two steps).
    var lf = try LiveFeed.init(&layout, &set_a, &rec);
    defer lf.deinit();
    const mid = rec.first + 105_000;
    while (!lf.done()) {
        const b = try lf.next();
        if (b.first >= mid) ov.add(b.first, b.rows, b.words);
    }
    var hb: [2]pyramid.Range = undefined;
    const raw_hole = ov.store.?.holes(.raw, rec.first, rec.end, &hb)[0];
    // Panels A until the first result is in.
    const until = deadline(60);
    while (ov.stats.accepted == 0) {
        if (clock.nowNs() > until) return error.Timeout;
        ov.turn(&set_a, width_a, rec.end, null, false);
        nap();
    }
    try testing.expect(ov.building());
    // Then B: the slots part goes, raw stays.
    while (ov.building()) {
        if (clock.nowNs() > until) return error.Timeout;
        ov.turn(&set_b, width_b, rec.end, null, false);
        nap();
    }
    try testing.expectEqual(width_b, ov.store.?.width);
    try expectSameStore(&want, &ov.store.?);
    // Raw buckets made: the raw hole's, plus at most the one step that was under way when
    // the panels changed (made for A, refused, asked again), plus a bucket at each end.
    const hole_buckets: u64 = @intCast(@divFloor(raw_hole.hi - raw_hole.lo, pyramid.bucket) + 2);
    const one_step: u64 = @intCast(@divFloor(60_000, pyramid.bucket));
    try testing.expect(ov.stats.raw_buckets >= hole_buckets - 2);
    try testing.expect(ov.stats.raw_buckets <= hole_buckets + one_step);
    try testing.expect(ov.stats.refused <= 1);
}

test "hold asks for nothing; end during a request neither leaks nor hangs" {
    const gpa = testing.allocator;
    const layout = testLayout();
    const set = testSet(&layout);
    const width = try feedWidth(&layout, &set);
    var rec = try TestRec.init(gpa, "hold", 5000, 120_000, 120_000);
    defer rec.deinit();
    var ov = try Overview.init(gpa, testing.io, &layout, std.math.maxInt(usize));
    defer ov.deinit();

    // Held: no request, no step, for a while.
    try ov.begin(rec.dir(), rec.first, &set, width);
    const t0 = clock.nowNs();
    while (clock.nowNs() < t0 + 300 * std.time.ns_per_ms) {
        ov.turn(&set, width, rec.end, null, true);
        nap();
    }
    try testing.expectEqual(0, ov.stats.requests);
    try testing.expectEqual(0, ov.shared.?.steps.load(.monotonic));
    try testing.expect(ov.building());
    // Released: a request. Ended at once, while the thread works on it.
    ov.turn(&set, width, rec.end, null, false);
    try testing.expectEqual(1, ov.stats.requests);
    try endWithin(&ov, 10);
    try testing.expect(!ov.active());
    var out: [10]pyramid.Pair = undefined;
    try testing.expect(!ov.columns(rec.first, rec.end, 10, &.{0}, &out));

    // Again, ended with the finished buckets still in the queue, never taken: freed.
    try ov.begin(rec.dir(), rec.first, &set, width);
    ov.turn(&set, width, rec.end, null, false);
    const until = deadline(30);
    while (ov.shared.?.steps.load(.monotonic) == 0) {
        if (clock.nowNs() > until) return error.Timeout;
        nap();
    }
    try endWithin(&ov, 10);
    try testing.expect(!ov.active());
}

/// `ov.end()` on another thread, failing (not hanging) if it takes over `seconds`.
fn endWithin(ov: *Overview, seconds: i128) !void {
    const Ctx = struct {
        ov: *Overview,
        done: Atomic(bool) = .init(false),
        fn f(c: *@This()) void {
            c.ov.end();
            c.done.store(true, .release);
        }
    };
    var ctx: Ctx = .{ .ov = ov };
    const t = try std.Thread.spawn(.{}, Ctx.f, .{&ctx});
    const until = deadline(seconds);
    while (!ctx.done.load(.acquire)) {
        if (clock.nowNs() > until) {
            t.detach();
            return error.Timeout;
        }
        nap();
    }
    t.join();
}

test "no recording folder: inactive, logged; a file shorter than file_end: retried, then filled" {
    const gpa = testing.allocator;
    const layout = testLayout();
    const set = testSet(&layout);
    const width = try feedWidth(&layout, &set);
    var ov = try Overview.init(gpa, testing.io, &layout, std.math.maxInt(usize));
    defer ov.deinit();

    // A folder that is not there (removed before the thread got to it).
    var gone_buf: [80]u8 = undefined;
    const gone = try std.fmt.bufPrint(&gone_buf, "/tmp/dimna-overview-test-{d}-gone", .{linux.getpid()});
    try ov.begin(gone, 5000, &set, width);
    var until = deadline(30);
    while (ov.active()) {
        if (clock.nowNs() > until) return error.Timeout;
        ov.turn(&set, width, 100_000, null, false);
        nap();
    }
    try testing.expect(!ov.building());
    try testing.expectEqual(0, ov.bytes());
    const zeros: [16]i16 = @splat(0);
    ov.add(5000, &zeros, &.{});
    ov.turn(&set, width, 100_000, null, false);

    // Samples written up to 3 s, the recorder's count says 6 s.
    var rec = try TestRec.init(gpa, "short", 5000, 180_024, 90_000); // ends on a bucket boundary
    defer rec.deinit();
    var want = try liveStore(&layout, &set, &rec);
    defer want.deinit();
    ov.retry_ns = 100 * std.time.ns_per_ms;
    try ov.begin(rec.dir(), rec.first, &set, width);
    until = deadline(30);
    while (ov.stats.short < 3) {
        if (clock.nowNs() > until) return error.Timeout;
        ov.turn(&set, width, rec.end, null, false);
        nap();
    }
    try testing.expect(ov.active());
    try testing.expect(ov.building());
    try testing.expectEqual(0, ov.stats.accepted);
    // The rest reaches the file: the next try succeeds, and the rest follows.
    try rec.write(180_024);
    while (ov.building()) {
        if (clock.nowNs() > until) return error.Timeout;
        ov.turn(&set, width, rec.end, null, false);
        nap();
    }
    try testing.expect(ov.active());
    try expectSameStore(&want, &ov.store.?);
}
