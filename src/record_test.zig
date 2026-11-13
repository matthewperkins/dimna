//! Tests of the recorder (`record.zig`) against its own files: a producer thread of the
//! test's own fills the ring with blocks whose every value is a function of (sample number,
//! channel), the recorder writes them, and the recording is read back and checked: index
//! records against samples.i16 (CRC, offsets, gap flags), every sample, every TTL change,
//! events.tsv and the [final] table of meta.toml.
//!
//! Files go to /tmp/oez-record-test-<pid>/<test>/ and are removed afterwards.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Atomic = std.atomic.Value;
const types = @import("types.zig");
const record = @import("record.zig");
const events = @import("events.zig");
const BlockRing = @import("ring.zig").BlockRing;
const Recorder = record.Recorder;
const IndexRecord = record.IndexRecord;

/// 4 electrodes and 1 ADC channel.
const nch = 5;
/// Block capacity in the ring.
const bs = 32;
const ring_slots = 64;
const rate = 30000.0;
/// Give up on any wait after this long (a hang fails the test instead of the suite).
const wait_limit_ms = 10_000;

// ---- the stream: everything is a function of the sample number ----

fn sampleValue(s: i64, ch: usize) i16 {
    const x: u64 = @bitCast(s);
    const h = (x *% 0x9E3779B97F4A7C15) ^ ((@as(u64, ch) + 1) *% 0xC2B2AE3D27D4EB4F);
    return @bitCast(@as(u16, @truncate(h >> 29)));
}

/// Changes every 37 samples, through 0, 3, 6, 9, 12.
fn ttlWord(s: i64) u16 {
    return @intCast(@mod(@divFloor(s, 37), 5) * 3);
}

/// A 50 MHz board clock at 30 kHz.
fn hwTime(s: i64) u64 {
    return @intCast(1_000_000 + @divFloor(s * 5000, 3));
}

fn fill(b: *types.Block, first: i64, len: usize) void {
    b.first_sample = first;
    b.len = len;
    for (0..len) |i| {
        const s = first + @as(i64, @intCast(i));
        for (0..nch) |ch| b.data[i * nch + ch] = sampleValue(s, ch);
        b.hw_time[i] = hwTime(s);
        b.ttl[i] = ttlWord(s);
    }
    b.acquired_ns = Io.Clock.awake.now(testing.io).nanoseconds;
}

/// Commits one block of `len` samples from sample `first`, waiting (with a limit) while a
/// reader still holds the slot.
fn produce(ring: *BlockRing, first: i64, len: usize) !void {
    const t0 = Io.Clock.awake.now(testing.io);
    const b = while (true) {
        if (ring.writeSlot()) |b| break b;
        if (t0.untilNow(testing.io, .awake).toMilliseconds() > wait_limit_ms) return error.ProducerHeldUp;
        try testing.io.sleep(.fromMicroseconds(100), .awake);
    };
    fill(b, first, len);
    ring.commit();
}

/// A producer on its own thread: full blocks, the block at ring position p holding samples
/// from `base + p * bs`, one block every `pause_us` or so.
const Producer = struct {
    ring: *BlockRing,
    base: i64,
    pause_us: i64 = 200,
    stop: Atomic(bool) = .init(false),
    /// While set, every `writeSlot()` that returns null is counted.
    count_nulls: Atomic(bool) = .init(false),
    nulls: Atomic(u64) = .init(0),
    /// While `hold` is set the producer commits nothing; `held` says it has noticed.
    hold: Atomic(bool) = .init(false),
    held: Atomic(bool) = .init(false),

    fn run(self: *Producer) void {
        while (!self.stop.load(.acquire)) {
            if (self.hold.load(.acquire)) {
                self.held.store(true, .release);
                testing.io.sleep(.fromMicroseconds(self.pause_us), .awake) catch {};
                continue;
            }
            self.held.store(false, .release);
            const p = self.ring.headPosition();
            if (self.ring.writeSlot()) |b| {
                fill(b, self.sampleAt(p), bs);
                self.ring.commit();
            } else if (self.count_nulls.load(.acquire)) {
                _ = self.nulls.fetchAdd(1, .monotonic);
            }
            testing.io.sleep(.fromMicroseconds(self.pause_us), .awake) catch {};
        }
    }

    fn sampleAt(self: *const Producer, pos: usize) i64 {
        return self.base + @as(i64, @intCast(pos)) * bs;
    }

    /// Stops the producer between two blocks (it stays alive, committing nothing).
    fn holdOn(self: *Producer) !void {
        self.hold.store(true, .release);
        const t0 = Io.Clock.awake.now(testing.io);
        while (!self.held.load(.acquire)) {
            if (t0.untilNow(testing.io, .awake).toMilliseconds() > wait_limit_ms) return error.ProducerStuck;
            try testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
    fn letGo(self: *Producer) void {
        self.hold.store(false, .release);
    }

    /// Waits until the producer has committed `n` more blocks.
    fn waitBlocks(self: *const Producer, n: usize) !void {
        const from = self.ring.headPosition();
        const t0 = Io.Clock.awake.now(testing.io);
        while (self.ring.headPosition() -% from < n) {
            if (t0.untilNow(testing.io, .awake).toMilliseconds() > wait_limit_ms) return error.ProducerStuck;
            try testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
};

fn testInfo() record.Info {
    var l: types.Layout = .{ .sample_rate = rate, .hw_clock_hz = 50e6 };
    l.headstages[0] = .{ .slot = 0, .chip = "RHD2132", .num_channels = 4, .first_channel = 0, .has_bno = false };
    l.num_headstages = 1;
    l.num_electrodes = 4;
    l.num_adc = 1;
    return .{ .layout = l, .settings = .{}, .gateware = .{ 2, 0, 0, 0 }, .board_id = 0x100, .cable_delay = @splat(0), .board_kind = "test" };
}

// ---- the temporary folder ----

const TmpRoot = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    fn init(name: []const u8) !TmpRoot {
        var t: TmpRoot = .{};
        const p = try std.fmt.bufPrint(&t.buf, "/tmp/oez-record-test-{d}/{s}", .{ std.os.linux.getpid(), name });
        t.len = p.len;
        Io.Dir.cwd().deleteTree(testing.io, p) catch {};
        try Io.Dir.cwd().createDirPath(testing.io, p);
        return t;
    }
    fn path(self: *const TmpRoot) []const u8 {
        return self.buf[0..self.len];
    }
    fn deinit(self: *const TmpRoot) void {
        Io.Dir.cwd().deleteTree(testing.io, self.path()) catch {};
        // The per-process parent, once the last test's folder is gone (fails while others remain).
        var pbuf: [64]u8 = undefined;
        const parent = std.fmt.bufPrintSentinel(&pbuf, "/tmp/oez-record-test-{d}", .{std.os.linux.getpid()}, 0) catch return;
        _ = std.os.linux.rmdir(parent);
    }
};

// ---- waiting for the recorder ----

/// Waits until the recorder has released every committed block, then a little longer.
fn caughtUp(r: *Recorder) !void {
    const t0 = Io.Clock.awake.now(testing.io);
    while (r.backlog() != 0) {
        if (t0.untilNow(testing.io, .awake).toMilliseconds() > wait_limit_ms) return error.RecorderHung;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.io.sleep(.fromMilliseconds(20), .awake);
}

fn waitDone(r: *Recorder) !void {
    const t0 = Io.Clock.awake.now(testing.io);
    while (!r.done.load(.acquire)) {
        if (t0.untilNow(testing.io, .awake).toMilliseconds() > wait_limit_ms) return error.RecorderHung;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Stops the recorder (with a time limit on its thread) and frees it.
fn stop(r: *Recorder) !Recorder.Summary {
    r.requestStop();
    try waitDone(r);
    return r.finish();
}

// ---- reading a recording back ----

const Recording = struct {
    gpa: std.mem.Allocator,
    index: []IndexRecord,
    raw: []u8,
    ttl_sample_bytes: []u8,
    ttl_word_bytes: []u8,
    events_text: []u8,
    meta: []u8,

    fn load(gpa: std.mem.Allocator, dir: []const u8) !Recording {
        const raw = try readFile(gpa, dir, "samples.i16");
        errdefer gpa.free(raw);
        const index_bytes = try readFile(gpa, dir, "index.bin");
        defer gpa.free(index_bytes);
        if (index_bytes.len % IndexRecord.size != 0) return failure("index.bin is {d} bytes, not whole records", .{index_bytes.len});
        const index = try gpa.alloc(IndexRecord, index_bytes.len / IndexRecord.size);
        errdefer gpa.free(index);
        for (index, 0..) |*ir, k| ir.* = IndexRecord.decode(index_bytes[k * IndexRecord.size ..][0..IndexRecord.size]);
        const ts = try readFile(gpa, dir, "ttl_sample.i64");
        errdefer gpa.free(ts);
        const tw = try readFile(gpa, dir, "ttl_word.u16");
        errdefer gpa.free(tw);
        const ev = try readFile(gpa, dir, "events.tsv");
        errdefer gpa.free(ev);
        const meta = try readFile(gpa, dir, "meta.toml");
        return .{ .gpa = gpa, .index = index, .raw = raw, .ttl_sample_bytes = ts, .ttl_word_bytes = tw, .events_text = ev, .meta = meta };
    }

    fn deinit(self: *Recording) void {
        const gpa = self.gpa;
        gpa.free(self.index);
        gpa.free(self.raw);
        gpa.free(self.ttl_sample_bytes);
        gpa.free(self.ttl_word_bytes);
        gpa.free(self.events_text);
        gpa.free(self.meta);
    }

    fn ttlCount(self: *const Recording) !usize {
        const n = self.ttl_sample_bytes.len / 8;
        if (self.ttl_sample_bytes.len % 8 != 0 or self.ttl_word_bytes.len != 2 * n)
            return failure("TTL files disagree: {d} bytes of samples, {d} bytes of words", .{ self.ttl_sample_bytes.len, self.ttl_word_bytes.len });
        return n;
    }
    fn ttlSample(self: *const Recording, k: usize) i64 {
        return std.mem.readInt(i64, self.ttl_sample_bytes[k * 8 ..][0..8], .little);
    }
    fn ttlWordAt(self: *const Recording, k: usize) u16 {
        return std.mem.readInt(u16, self.ttl_word_bytes[k * 2 ..][0..2], .little);
    }
    fn value(self: *const Recording, row: u64, ch: usize) i16 {
        const at: usize = @intCast((row * nch + ch) * 2);
        return std.mem.readInt(i16, self.raw[at..][0..2], .little);
    }

    /// `key = <integer>` in `[table]` of meta.toml, or null.
    fn metaInt(self: *const Recording, comptime table: []const u8, comptime key: []const u8) !?i64 {
        const head = "\n[" ++ table ++ "]\n";
        const at = std.mem.indexOf(u8, self.meta, head) orelse return null;
        var it = std.mem.splitScalar(u8, self.meta[at + head.len ..], '\n');
        while (it.next()) |line| {
            if (line.len > 0 and line[0] == '[') break;
            if (std.mem.startsWith(u8, line, key ++ " = ")) return try std.fmt.parseInt(i64, line[key.len + 3 ..], 10);
        }
        return null;
    }
    fn hasFinal(self: *const Recording) bool {
        return std.mem.indexOf(u8, self.meta, "\n[final]\n") != null;
    }

    /// The lines of events.tsv, without the header.
    fn eventLines(self: *const Recording, gpa: std.mem.Allocator) ![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(gpa);
        var it = std.mem.splitScalar(u8, self.events_text, '\n');
        const header = it.next() orelse "";
        if (!std.mem.eql(u8, header, "sample\tkind\ttext")) return failure("events.tsv header is '{s}'", .{header});
        while (it.next()) |line| {
            if (line.len == 0) {
                if (it.rest().len != 0) return failure("empty line in events.tsv", .{});
                break;
            }
            try list.append(gpa, line);
        }
        if (self.events_text.len > 0 and self.events_text[self.events_text.len - 1] != '\n') return failure("events.tsv does not end in a newline", .{});
        return list.toOwnedSlice(gpa);
    }
};

fn readFile(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    var buf: [256]u8 = undefined;
    const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name });
    return Io.Dir.cwd().readFileAlloc(testing.io, p, gpa, .limited(1 << 30));
}

fn failure(comptime fmt: []const u8, args: anytype) error{TestUnexpectedResult} {
    std.debug.print("recorder test: " ++ fmt ++ "\n", args);
    return error.TestUnexpectedResult;
}

const Checked = struct {
    /// Rows covered by the index, and the bytes they take from the start of samples.i16.
    rows: u64 = 0,
    bytes: u64 = 0,
    first: i64 = 0,
    /// One past the last indexed sample.
    end: i64 = 0,
    gaps: u64 = 0,
};

/// Every index record: placed right after the previous one from byte 0, inside samples.i16,
/// with a matching CRC; the gap flag set exactly when its first sample does not follow the
/// previous record; the board clock of its first sample; and every value in it equal to the
/// stream at the sample numbers the index gives.
fn checkIndexed(rec: *const Recording) !Checked {
    if (rec.index.len == 0) return failure("index.bin has no records", .{});
    var c: Checked = .{ .first = rec.index[0].first_sample };
    var prev_end: ?i64 = null;
    for (rec.index, 0..) |ir, k| {
        if (ir.n_samples == 0) return failure("chunk {d} is empty", .{k});
        if (ir.byte_offset != c.bytes) return failure("chunk {d}: byte_offset {d}, expected {d}", .{ k, ir.byte_offset, c.bytes });
        const nbytes = @as(u64, ir.n_samples) * nch * 2;
        if (ir.byte_offset + nbytes > rec.raw.len) return failure("chunk {d}: bytes {d}..{d} past the end of samples.i16 ({d})", .{ k, ir.byte_offset, ir.byte_offset + nbytes, rec.raw.len });
        const crc = std.hash.Crc32.hash(rec.raw[@intCast(ir.byte_offset)..][0..@intCast(nbytes)]);
        if (crc != ir.crc32) return failure("chunk {d}: CRC {x} in the index, {x} in samples.i16", .{ k, ir.crc32, crc });
        const gap = if (prev_end) |e| ir.first_sample != e else false;
        if (gap != (ir.flags & IndexRecord.flag_gap != 0)) return failure("chunk {d} (sample {d}): gap flag {}, but the previous chunk ended at {?d}", .{ k, ir.first_sample, ir.flags & IndexRecord.flag_gap != 0, prev_end });
        if (ir.flags & ~IndexRecord.flag_gap != 0) return failure("chunk {d}: unknown flags {x}", .{ k, ir.flags });
        if (gap) c.gaps += 1;
        if (ir.board_clock != hwTime(ir.first_sample)) return failure("chunk {d}: board clock {d}, expected {d}", .{ k, ir.board_clock, hwTime(ir.first_sample) });
        if (ir.wall_ns == 0) return failure("chunk {d}: no wall time", .{k});
        for (0..ir.n_samples) |i| {
            const s = ir.first_sample + @as(i64, @intCast(i));
            for (0..nch) |ch| {
                const got = rec.value(c.rows + i, ch);
                if (got != sampleValue(s, ch)) return failure("chunk {d}, sample {d} (row {d}), channel {d}: {d}, expected {d}", .{ k, s, c.rows + i, ch, got, sampleValue(s, ch) });
            }
        }
        c.rows += ir.n_samples;
        c.bytes += nbytes;
        prev_end = ir.first_sample + ir.n_samples;
    }
    c.end = prev_end.?;
    return c;
}

/// Every change of the TTL word over the indexed samples is in the TTL files, once, at its
/// sample, and the first entry is the word at the first sample. With `exact`, the files hold
/// nothing else; otherwise they may go on past the indexed samples (an interrupted recording).
fn checkTtl(rec: *const Recording, exact: bool) !void {
    const n = try rec.ttlCount();
    var k: usize = 0;
    var last: ?u16 = null;
    for (rec.index) |ir| {
        for (0..ir.n_samples) |i| {
            const s = ir.first_sample + @as(i64, @intCast(i));
            const w = ttlWord(s);
            if (last != null and last.? == w) continue;
            last = w;
            if (k >= n) return failure("TTL: change to {d} at sample {d} is missing (only {d} entries)", .{ w, s, n });
            if (rec.ttlSample(k) != s or rec.ttlWordAt(k) != w)
                return failure("TTL entry {d}: ({d}, {d}), expected ({d}, {d})", .{ k, rec.ttlSample(k), rec.ttlWordAt(k), s, w });
            k += 1;
        }
    }
    if (exact and k != n) return failure("TTL: {d} entries, expected {d}", .{ n, k });
    if (!exact) {
        // What is past the index must at least be in order.
        var j = k;
        while (j + 1 < n) : (j += 1) {
            if (rec.ttlSample(j + 1) <= rec.ttlSample(j)) return failure("TTL entries {d}, {d} out of order", .{ j, j + 1 });
        }
    }
}

/// A recording stopped cleanly: the index covers the whole file, TTL exact, [start] and
/// [final] agree with the files and the recorder's summary, events.tsv starts with `start`
/// at the first sample and ends with `stop` at the end.
fn checkComplete(gpa: std.mem.Allocator, rec: *const Recording, c: Checked, sum: Recorder.Summary) !void {
    if (c.bytes != rec.raw.len) return failure("index covers {d} bytes of samples.i16, the file has {d}", .{ c.bytes, rec.raw.len });
    try checkTtl(rec, true);
    if (!rec.hasFinal()) return failure("meta.toml has no [final]", .{});
    try testing.expectEqual(@as(?i64, c.first), try rec.metaInt("start", "first_sample"));
    try testing.expectEqual(@as(?i64, c.end), try rec.metaInt("final", "end_sample"));
    try testing.expectEqual(@as(?i64, @intCast(c.rows)), try rec.metaInt("final", "samples"));
    try testing.expectEqual(@as(?i64, @intCast(rec.index.len)), try rec.metaInt("final", "chunks"));
    try testing.expectEqual(@as(?i64, @intCast(c.gaps)), try rec.metaInt("final", "gaps"));
    try testing.expectEqual(@as(?i64, @intCast(try rec.ttlCount())), try rec.metaInt("final", "ttl_edges"));
    try testing.expectEqual(@as(?i64, @intCast(rec.raw.len)), try rec.metaInt("final", "bytes"));
    try testing.expectEqual(c.rows, sum.samples);
    try testing.expectEqual(@as(u64, rec.index.len), sum.chunks);
    try testing.expectEqual(c.gaps, sum.gaps);
    try testing.expectEqual(@as(u64, try rec.ttlCount()), sum.ttl_edges);
    try testing.expectEqual(@as(?anyerror, null), sum.failure);

    const lines = try rec.eventLines(gpa);
    defer gpa.free(lines);
    if (lines.len < 2) return failure("events.tsv has {d} lines", .{lines.len});
    var buf: [64]u8 = undefined;
    // One `start`, at the first sample. Not necessarily the first line: an event queued
    // before the first block arrives is written as soon as it is drained, before `start`
    // (seen in the events test; the format does not promise an order of lines).
    const start_line = try std.fmt.bufPrint(&buf, "{d}\tstart\t", .{c.first});
    var starts: usize = 0;
    for (lines) |l| {
        if (std.mem.indexOf(u8, l, "\tstart\t") != null) {
            try testing.expectEqualStrings(start_line, l);
            starts += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), starts);
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "{d}\tstop\t", .{c.end}), lines[lines.len - 1]);
}

fn dupePath(gpa: std.mem.Allocator, r: *const Recorder) ![]u8 {
    return gpa.dupe(u8, r.path);
}

// ---- the tests ----

test "recorder: a whole stream comes back exactly" {
    const gpa = testing.allocator;
    const tmp = try TmpRoot.init("whole");
    defer tmp.deinit();
    var ring = try BlockRing.init(gpa, ring_slots, nch, bs);
    defer ring.deinit(gpa);

    const r = try Recorder.create(gpa, testing.io, &ring, tmp.path(), testInfo());
    const path = try dupePath(gpa, r);
    defer gpa.free(path);
    try r.start();
    // Blocks of varying length (some empty), not aligned to chunks; the first sample is not
    // at a TTL change, so the first TTL entry is the initial state, not an edge. Paced to
    // take ~1.5 s, so the recorder syncs (and writes index records) while recording too.
    const first: i64 = 1000;
    var s: i64 = first;
    for (0..3000) |k| {
        const len: usize = if (k % 50 == 49) 0 else 1 + (k * 13) % bs;
        try produce(&ring, s, len);
        s += @intCast(len);
        try testing.io.sleep(.fromMicroseconds(400), .awake);
    }
    try caughtUp(r);
    const syncs = r.stats.syncs.load(.monotonic);
    const sum = try stop(r);

    var rec = try Recording.load(gpa, path);
    defer rec.deinit();
    const c = try checkIndexed(&rec);
    try testing.expectEqual(first, c.first);
    try testing.expectEqual(s, c.end);
    try testing.expectEqual(@as(u64, @intCast(s - first)), c.rows);
    try testing.expectEqual(@as(u64, 0), c.gaps);
    try checkComplete(gpa, &rec, c, sum);
    if (try rec.ttlCount() < 100) return failure("only {d} TTL entries", .{try rec.ttlCount()});
    // The recording synced at least once while it ran (the index was written in steps).
    if (syncs < 1) return failure("no sync while recording ({d})", .{syncs});
}

test "recorder: attached to a running stream, it starts at a block boundary and misses nothing after" {
    const gpa = testing.allocator;
    const tmp = try TmpRoot.init("attach");
    defer tmp.deinit();
    var ring = try BlockRing.init(gpa, ring_slots, nch, bs);
    defer ring.deinit(gpa);

    var prod: Producer = .{ .ring = &ring, .base = 500 };
    const t = try std.Thread.spawn(.{}, Producer.run, .{&prod});
    var joined = false;
    defer if (!joined) {
        prod.stop.store(true, .release);
        t.join();
    };
    // Running round the ring several times before anyone attaches. Held between two
    // blocks while the recorder is created, so the block it must start with is known.
    try prod.waitBlocks(3 * ring_slots);
    try prod.holdOn();
    const head_before = ring.headPosition();
    const r = try Recorder.create(gpa, testing.io, &ring, tmp.path(), testInfo());
    try testing.expectEqual(head_before, ring.headPosition());
    const path = try dupePath(gpa, r);
    defer gpa.free(path);
    try r.start();
    prod.letGo();
    try prod.waitBlocks(4 * ring_slots);
    prod.stop.store(true, .release);
    t.join();
    joined = true;
    const end_pos = ring.headPosition();
    try caughtUp(r);
    const sum = try stop(r);

    var rec = try Recording.load(gpa, path);
    defer rec.deinit();
    const c = try checkIndexed(&rec);
    // Nothing committed before `create`, and starting with the first whole block after.
    if (c.first != prod.sampleAt(head_before))
        return failure("first sample {d}; the blocks committed before create end at {d}", .{ c.first, prod.sampleAt(head_before) });
    if (@mod(c.first - prod.base, bs) != 0) return failure("first sample {d} is not at a block boundary", .{c.first});
    // Everything after: no gaps, up to the last block committed.
    try testing.expectEqual(@as(u64, 0), c.gaps);
    try testing.expectEqual(prod.sampleAt(end_pos), c.end);
    try checkComplete(gpa, &rec, c, sum);
}

test "recorder: stopped while the producer keeps going, it ends at a block boundary and lets go of the ring" {
    const gpa = testing.allocator;
    const tmp = try TmpRoot.init("stop");
    defer tmp.deinit();
    var ring = try BlockRing.init(gpa, ring_slots, nch, bs);
    defer ring.deinit(gpa);
    // Take all reader places but one (detached, so they hold nothing back): the second
    // recorder below can only attach if the first gave its place back.
    for (0..3) |_| ring.detach(ring.addConsumer().?);

    var prod: Producer = .{ .ring = &ring, .base = 0 };
    const t = try std.Thread.spawn(.{}, Producer.run, .{&prod});
    defer {
        prod.stop.store(true, .release);
        t.join();
    }

    var paths: [2][]u8 = undefined;
    var n_paths: usize = 0;
    defer for (paths[0..n_paths]) |p| gpa.free(p);
    var ends: [2]i64 = undefined;
    for (0..2) |k| {
        const r = Recorder.create(gpa, testing.io, &ring, tmp.path(), testInfo()) catch |e|
            return failure("recorder {d}: create failed: {t}", .{ k + 1, e });
        paths[k] = try dupePath(gpa, r);
        n_paths += 1;
        try r.start();
        try prod.waitBlocks(3 * ring_slots);
        // Stop while blocks keep coming; everything committed before this is recorded.
        const head_at_stop = ring.headPosition();
        r.requestStop();
        try waitDone(r);
        // Done (the thread has detached), not yet freed; then freed. Each time the producer
        // goes round the ring three times and never has to wait.
        prod.count_nulls.store(true, .release);
        try prod.waitBlocks(3 * ring_slots);
        if (prod.nulls.load(.monotonic) != 0) return failure("recorder {d}: done, but the producer waited {d} times", .{ k + 1, prod.nulls.load(.monotonic) });
        const sum = r.finish();
        try prod.waitBlocks(3 * ring_slots);
        prod.count_nulls.store(false, .release);
        if (prod.nulls.load(.monotonic) != 0) return failure("recorder {d}: finished, but the producer waited {d} times", .{ k + 1, prod.nulls.load(.monotonic) });

        var rec = try Recording.load(gpa, paths[k]);
        defer rec.deinit();
        const c = try checkIndexed(&rec);
        try testing.expectEqual(@as(u64, 0), c.gaps);
        try checkComplete(gpa, &rec, c, sum);
        if (@mod(c.first - prod.base, bs) != 0) return failure("recorder {d}: first sample {d} is not at a block boundary", .{ k + 1, c.first });
        if (@mod(c.end - prod.base, bs) != 0) return failure("recorder {d}: end sample {d} is not at a block boundary", .{ k + 1, c.end });
        if (c.end < prod.sampleAt(head_at_stop)) return failure("recorder {d}: ends at {d}, but samples up to {d} were committed before the stop", .{ k + 1, c.end, prod.sampleAt(head_at_stop) });
        if (k == 1 and c.first < ends[0]) return failure("second recording starts at {d}, before the first ended ({d})", .{ c.first, ends[0] });
        ends[k] = c.end;
    }
    if (std.mem.eql(u8, paths[0], paths[1])) return failure("both recordings in {s}", .{paths[0]});
}

test "recorder: lost blocks are flagged, and sample numbers survive" {
    const gpa = testing.allocator;
    const tmp = try TmpRoot.init("gaps");
    defer tmp.deinit();
    var ring = try BlockRing.init(gpa, ring_slots, nch, bs);
    defer ring.deinit(gpa);

    const r = try Recorder.create(gpa, testing.io, &ring, tmp.path(), testInfo());
    const path = try dupePath(gpa, r);
    defer gpa.free(path);
    try r.start();
    // 200 blocks, one block's worth of samples missing, 100 blocks, 1001 samples missing,
    // 100 blocks.
    var s: i64 = 0;
    const jumps = [_]i64{ bs, 1001 };
    var gap_at: [2]i64 = undefined; // last sample + 1 before each jump
    for (0..400) |k| {
        if (k == 200 or k == 300) {
            const j: usize = if (k == 200) 0 else 1;
            gap_at[j] = s;
            s += jumps[j];
        }
        try produce(&ring, s, bs);
        s += bs;
    }
    try caughtUp(r);
    const sum = try stop(r);

    var rec = try Recording.load(gpa, path);
    defer rec.deinit();
    const c = try checkIndexed(&rec);
    try testing.expectEqual(@as(u64, 2), c.gaps);
    try testing.expectEqual(@as(u64, 2), sum.gaps);
    try testing.expectEqual(@as(u64, 400 * bs), c.rows);
    try testing.expectEqual(s, c.end);
    // On each side of each jump: a chunk ends exactly where the samples stopped, and the
    // next one, flagged, starts where they resumed. (`checkIndexed` checked every value at
    // the sample numbers the index gives.)
    for (gap_at, jumps) |at, jump| {
        var found = false;
        for (rec.index[1..], 1..) |ir, k| {
            const prev = rec.index[k - 1];
            if (prev.first_sample + prev.n_samples == at) {
                if (ir.first_sample != at + jump or ir.flags & IndexRecord.flag_gap == 0)
                    return failure("after the samples stop at {d}: chunk at {d}, flags {d}", .{ at, ir.first_sample, ir.flags });
                found = true;
            }
        }
        if (!found) return failure("no chunk ends at {d}, where the samples stop", .{at});
    }
    try checkComplete(gpa, &rec, c, sum);
}

test "recorder: a write failure does not hold the producer, and what was indexed is intact" {
    // The recorder reports the failure with `log.err`, and the test runner counts any
    // error logged during a test as a failure of that test. So this one runs in a child
    // process, whose exit status is the result. Its stderr goes to a file, shown if it fails.
    const linux = std.os.linux;
    const tmp = try TmpRoot.init("failure");
    defer tmp.deinit();
    var ebuf: [192]u8 = undefined;
    const err_path = try std.fmt.bufPrintSentinel(&ebuf, "{s}/child-stderr.txt", .{tmp.path()}, 0);
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return failure("fork failed", .{});
    if (rc == 0) {
        const fd = linux.open(err_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
        if (linux.errno(fd) == .SUCCESS) _ = linux.dup2(@intCast(fd), 2);
        failureScenario(tmp.path()) catch |e| {
            std.debug.print("recorder test (write failure): {t}\n", .{e});
            linux.exit_group(1);
        };
        linux.exit_group(0);
    }
    const pid: linux.pid_t = @intCast(rc);
    var status: i32 = 0;
    const t0 = Io.Clock.awake.now(testing.io);
    while (true) {
        const w = linux.wait4(pid, &status, linux.W.NOHANG, null);
        if (linux.errno(w) != .SUCCESS) return failure("wait4 failed", .{});
        if (w == @as(usize, @intCast(pid))) break;
        if (t0.untilNow(testing.io, .awake).toMilliseconds() > 3 * wait_limit_ms) {
            _ = linux.kill(pid, .KILL);
            _ = linux.wait4(pid, &status, 0, null);
            return failure("the write-failure scenario hung", .{});
        }
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    const st: u32 = @bitCast(status);
    if (!linux.W.IFEXITED(st) or linux.W.EXITSTATUS(st) != 0) {
        if (Io.Dir.cwd().readFileAlloc(testing.io, err_path, testing.allocator, .limited(1 << 20))) |text| {
            defer testing.allocator.free(text);
            std.debug.print("{s}", .{text});
        } else |_| {}
        return failure("the write-failure scenario failed (status {x}; its stderr is above)", .{st});
    }
}

fn failureScenario(root: []const u8) !void {
    const gpa = testing.allocator;
    var ring = try BlockRing.init(gpa, ring_slots, nch, bs);
    defer ring.deinit(gpa);

    const r = try Recorder.create(gpa, testing.io, &ring, root, testInfo());
    const path = try dupePath(gpa, r);
    defer gpa.free(path);
    // Chunks are 94 blocks (3008 samples): two chunks are written, the third fails.
    r.test_fail_after = 6000;
    try r.start();
    var s: i64 = 0;
    for (0..200) |_| {
        try produce(&ring, s, bs);
        s += bs;
    }
    // The two chunks' index records reach the file at the next sync (about 1 s on).
    {
        var ibuf: [256]u8 = undefined;
        const ipath = try std.fmt.bufPrint(&ibuf, "{s}/index.bin", .{path});
        const t0 = Io.Clock.awake.now(testing.io);
        while ((try Io.Dir.cwd().statFile(testing.io, ipath, .{})).size < 2 * IndexRecord.size) {
            if (t0.untilNow(testing.io, .awake).toMilliseconds() > wait_limit_ms) return failure("index records never written", .{});
            try testing.io.sleep(.fromMilliseconds(5), .awake);
        }
    }
    try testing.expect(!r.done.load(.acquire));
    // The third chunk fails.
    for (0..100) |_| {
        try produce(&ring, s, bs);
        s += bs;
    }
    try waitDone(r);
    try testing.expectEqual(@as(?anyerror, error.InjectedFailure), r.failure);
    // The producer is never blocked afterwards: three times round the ring, no waiting.
    for (0..3 * ring_slots) |k| {
        const b = ring.writeSlot() orelse return failure("producer blocked after the failure, at block {d}", .{k});
        fill(b, s, bs);
        ring.commit();
        s += bs;
    }
    const sum = r.finish();
    try testing.expectEqual(@as(?anyerror, error.InjectedFailure), sum.failure);

    var rec = try Recording.load(gpa, path);
    defer rec.deinit();
    // Every index record that reached the file points at bytes in samples.i16 that match.
    const c = try checkIndexed(&rec);
    try testing.expectEqual(@as(usize, 2), rec.index.len);
    try testing.expectEqual(@as(i64, 0), c.first);
    try testing.expectEqual(@as(u64, 0), c.gaps);
    try checkTtl(&rec, false);
    if (rec.hasFinal()) return failure("a failed recording has [final]", .{});
}

test "recorder: events from both queues land in events.tsv with their samples" {
    const gpa = testing.allocator;
    const tmp = try TmpRoot.init("events");
    defer tmp.deinit();
    var ring = try BlockRing.init(gpa, ring_slots, nch, bs);
    defer ring.deinit(gpa);
    const evq = try gpa.create(events.EventQueue);
    defer gpa.destroy(evq);
    evq.* = .{};
    const notes = try gpa.create(events.EventQueue);
    defer gpa.destroy(notes);
    notes.* = .{};

    const r = try Recorder.create(gpa, testing.io, &ring, tmp.path(), testInfo());
    const path = try dupePath(gpa, r);
    defer gpa.free(path);
    r.events_in = evq;
    r.notes_in = notes;
    try testing.expect(evq.push(.init(100, "settings", "lower bandwidth {d} Hz", .{300})));
    try r.start();
    var s: i64 = 0;
    for (0..300) |k| {
        if (k == 100) try testing.expect(notes.push(.init(s, "note", "tab\there, newline\nthere", .{})));
        if (k == 150) try testing.expect(evq.push(.init(s + 5, "settings", "leds on", .{})));
        if (k == 200) try testing.expect(notes.push(.init(s, "note", "second note", .{})));
        try produce(&ring, s, bs);
        s += bs;
    }
    try caughtUp(r);
    // Pushed while stopping: still written.
    try testing.expect(notes.push(.init(s - 1, "note", "last words", .{})));
    const sum = try stop(r);

    var rec = try Recording.load(gpa, path);
    defer rec.deinit();
    const c = try checkIndexed(&rec);
    try checkComplete(gpa, &rec, c, sum);
    const lines = try rec.eventLines(gpa);
    defer gpa.free(lines);
    var b: [5][64]u8 = undefined;
    const want = [_][]const u8{
        try std.fmt.bufPrint(&b[0], "100\tsettings\tlower bandwidth 300 Hz", .{}),
        try std.fmt.bufPrint(&b[1], "{d}\tnote\ttab here, newline there", .{100 * bs}),
        try std.fmt.bufPrint(&b[2], "{d}\tsettings\tleds on", .{150 * bs + 5}),
        try std.fmt.bufPrint(&b[3], "{d}\tnote\tsecond note", .{200 * bs}),
        try std.fmt.bufPrint(&b[4], "{d}\tnote\tlast words", .{s - 1}),
    };
    for (want) |w| {
        var n: usize = 0;
        for (lines) |l| {
            if (std.mem.eql(u8, l, w)) n += 1;
        }
        if (n != 1) {
            for (lines) |l| std.debug.print("  events.tsv: {s}\n", .{l});
            return failure("'{s}' is in events.tsv {d} times", .{ w, n });
        }
    }
    // start, the five, stop.
    try testing.expectEqual(@as(usize, want.len + 2), lines.len);
}
