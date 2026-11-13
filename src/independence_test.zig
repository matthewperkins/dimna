//! The promise an experimenter relies on without looking: what the display does (filters,
//! common average reference, hidden and unfiltered rows, spike detection, the slope trigger,
//! the audio monitor) never changes what is recorded.
//!
//! One deterministic stream (every sample a pure function of its sample number and channel,
//! the TTL word a function of the sample number) is recorded twice: once with a "display
//! side" running flat out on its own thread beside the recorder, doing to every block it
//! gets what the GUI does, and once without it. Both recordings must be byte for byte what
//! the producer generated, and their index records must agree in everything but wall time.
//!
//! The display side reads through a `ring.LossyReader`, as the GUI does, so it never holds
//! the producer back; if it is slow it sees fewer blocks than were produced, and the blocks
//! it missed are counted as lost.

const std = @import("std");
const types = @import("types.zig");
const ring_mod = @import("ring.zig");
const record = @import("record.zig");
const panels = @import("panels.zig");
const feed_mod = @import("feed.zig");
const spikes = @import("spikes.zig");
const slope = @import("slope.zig");
const audio = @import("audio.zig");
const toml = @import("toml.zig");
const Block = types.Block;
const BlockRing = ring_mod.BlockRing;
const Io = std.Io;
const Atomic = std.atomic.Value;
const testing = std.testing;

const fs = 30000.0;
const per_headstage = 16;
const n_electrodes = 2 * per_headstage;
const n_adc = 2;
const nch = n_electrodes + n_adc;
const block_samples = 32;
const n_blocks = 6000;
const total_samples = n_blocks * block_samples;
const ring_slots = 64;

fn testLayout() types.Layout {
    var l: types.Layout = .{ .sample_rate = fs, .hw_clock_hz = 50e6 };
    l.headstages[0] = .{ .slot = 0, .chip = "RHD2216", .num_channels = per_headstage, .first_channel = 0, .has_bno = false };
    l.headstages[1] = .{ .slot = 2, .chip = "RHD2216", .num_channels = per_headstage, .first_channel = per_headstage, .has_bno = false };
    l.num_headstages = 2;
    l.num_electrodes = n_electrodes;
    l.num_adc = n_adc;
    return l;
}

/// Sample `n` of channel `ch`, in integers only: hashed noise, a shared 50 Hz triangle (for
/// the reference and the band to take out), spikes on two channels in three, and ramps on
/// the ADC channels.
fn sampleValue(n: i64, ch: usize) i16 {
    if (ch >= n_electrodes) return @intCast(@mod(n * @as(i64, @intCast(ch - n_electrodes + 1)), 20000) - 10000);
    var h: u64 = @as(u64, @bitCast(n)) *% 0x9E3779B97F4A7C15 ^ (@as(u64, ch) +% 1) *% 0xBF58476D1CE4E5B9;
    h ^= h >> 31;
    h *%= 0x94D049BB133111EB;
    h ^= h >> 29;
    var v: i32 = @as(i32, @intCast(h & 0xff)) - 128;
    const p: i32 = @intCast(@mod(n, 600));
    v += if (p < 300) @divTrunc(p * 20, 3) - 1000 else 1000 - @divTrunc((p - 300) * 20, 3);
    if (ch % 3 != 2) {
        const d = @mod(n + @as(i64, @intCast(ch)) * 97, 3001);
        if (d < 6) v -= 1500 else if (d < 16) v += 600;
    }
    return @intCast(v);
}

/// TTL line 1: 10 ms high every 100 ms; line 2: a 10 Hz square wave; line 3: brief pulses.
fn ttlWord(n: i64) u16 {
    var w: u16 = @intFromBool(@mod(n, 3000) < 300);
    w |= @as(u16, @intCast(@mod(@divFloor(n, 1500), 2))) << 1;
    w |= @as(u16, @intFromBool(@mod(n, 7919) < 5)) << 2;
    return w;
}

fn produce(ring: *BlockRing, io: Io) void {
    var b: usize = 0;
    while (b < n_blocks) {
        // Only the recorder can make this wait (it gates the ring); the display side cannot.
        const blk = ring.writeSlot() orelse {
            std.Thread.yield() catch {};
            continue;
        };
        const first: i64 = @intCast(b * block_samples);
        blk.first_sample = first;
        blk.len = block_samples;
        for (0..block_samples) |s| {
            const n = first + @as(i64, @intCast(s));
            for (0..nch) |ch| blk.data[s * nch + ch] = sampleValue(n, ch);
            blk.ttl[s] = ttlWord(n);
            blk.hw_time[s] = @as(u64, @intCast(n)) * 1667;
        }
        blk.acquired_ns = Io.Clock.awake.now(io).nanoseconds;
        ring.commit();
        b += 1;
    }
}

const panel_config =
    \\[ttl]
    \\line1 = "camera"
    \\line2 = "laser"
    \\[[panel]]
    \\name = "Port A"
    \\source = "A1"
    \\rect = [0, 0, 0.5, 0.8]
    \\band = [300, 6000]
    \\raw_rows = [3, 4]
    \\raw_scale = 2000
    \\hide = [5, 6]
    \\car_ref = [1, 2, 3, 7, 8, 9]
    \\car_subtract = [1, 2, 4, 10, 11]
    \\tint = 2
    \\[[panel]]
    \\name = "Port B"
    \\source = "B1"
    \\rect = [0.5, 0, 0.5, 0.8]
    \\band = [10, 0]
    \\car = true
    \\mode = "triggered"
    \\trigger_channel = 3
    \\[[panel]]
    \\source = "adc"
    \\rect = [0, 0.8, 1, 0.1]
    \\[[panel]]
    \\source = "ttl"
    \\rect = [0, 0.9, 1, 0.1]
    \\lines = [1, 2, 3]
;

const Triggers = struct {
    count: u64 = 0,
    pub fn push(self: *Triggers, t0: i64) void {
        _ = t0;
        self.count += 1;
    }
};

/// What the GUI does to the blocks it reads, on a thread of its own.
const Display = struct {
    gpa: std.mem.Allocator,
    ring: *BlockRing,
    reader: *ring_mod.LossyReader,
    layout: *const types.Layout,
    stop: *Atomic(bool),
    seen: u64 = 0,
    syncs: u64 = 0,
    waves: u64 = 0,
    triggers: u64 = 0,
    audio_frames: u64 = 0,
    failure: ?anyerror = null,

    fn run(self: *Display) void {
        self.loop() catch |e| {
            self.failure = e;
        };
    }

    fn loop(self: *Display) !void {
        const gpa = self.gpa;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        var set = try panels.fromConfig(try toml.parse(arena_state.allocator(), panel_config), self.layout);

        const hist_cap = 1 << 15;
        var feed = try feed_mod.Feed.init(gpa, self.layout, &set, hist_cap);
        defer feed.deinit(gpa);
        const hist = try gpa.alloc(i16, hist_cap * feed.width);
        defer gpa.free(hist);
        @memset(hist, 0);

        var det = try spikes.Detector.init(gpa, fs, n_electrodes);
        defer det.deinit();
        var car: spikes.Car = .{};
        var ref_b: [per_headstage]u32 = undefined;
        for (0..per_headstage) |k| {
            car.group_of[k] = 0;
            car.group_of[per_headstage + k] = 1;
            car.ref[0][k] = @intCast(k);
            car.ref[1][k] = @intCast(per_headstage + k);
            ref_b[k] = @intCast(per_headstage + k);
        }
        car.ref_len[0] = per_headstage;
        car.ref_len[1] = per_headstage;

        // Port B's slope trigger: its row 3, referenced to the port's mean.
        var trig: slope.Slope = .init(fs, .{});
        var sink: Triggers = .{};

        var mon: audio.Monitor = .init(gpa, fs);
        defer mon.deinit();
        var listen: audio.Settings = .{ .num_channels = 2 };
        listen.channels[0] = 1;
        listen.channels[1] = per_headstage + 2;
        for (0..per_headstage) |k| {
            listen.car_ref[0][k] = @intCast(k);
            listen.car_ref[1][k] = @intCast(per_headstage + k);
        }
        listen.car_len[0] = per_headstage;
        listen.car_len[1] = per_headstage;
        var sound: std.ArrayList(f32) = .empty;
        defer sound.deinit(gpa);

        var blk = try Block.init(gpa, nch, block_samples);
        defer blk.deinit(gpa);
        while (true) {
            // Read before looking for a block: once it is set, every block is committed.
            const finished = self.stop.load(.acquire);
            if (!self.reader.next(&blk)) {
                if (finished) break;
                std.atomic.spinLoopHint();
                continue;
            }
            self.seen += 1;
            const samples = blk.samples();
            const ttl = blk.ttl[0..blk.len];
            const rows = try feed.rows(gpa, blk.first_sample, samples, ttl);
            for (0..blk.len) |i| {
                const pos: usize = @intCast(@as(u64, @bitCast(blk.first_sample + @as(i64, @intCast(i)))) & (hist_cap - 1));
                @memcpy(hist[pos * feed.width ..][0..feed.width], rows[i * feed.width ..][0..feed.width]);
            }
            // Part-way through, and again and again: other corners, another reference,
            // another hidden row, the second panel's reference off and on.
            if (self.seen % 300 == 0) {
                const a = &set.items[0];
                a.band_low_hz = if (a.band_low_hz == 300) 600 else 300;
                a.car_ref.set(6, !a.car_ref.has(6));
                a.hidden.set(11, !a.hidden.has(11));
                set.items[1].setCar(!set.items[1].carActive());
                if (try feed.sync(gpa, &set, 8192, hist, hist_cap)) self.syncs += 1;
            }
            try det.feed(blk.first_sample, samples, nch, &car);
            trig.feed(blk.first_sample, samples, nch, per_headstage + 2, &ref_b, &sink);
            sound.clearRetainingCapacity();
            try mon.process(&listen, samples, nch, &sound);
            self.audio_frames += sound.items.len / 2;
        }
        for (det.units) |*u| self.waves += u.wave_count;
        self.triggers = sink.count;
    }
};

const Run = struct {
    path: []u8,
    summary: record.Recorder.Summary,
    seen: u64 = 0,
    lost: u64 = 0,
    syncs: u64 = 0,
    waves: u64 = 0,
    triggers: u64 = 0,
    audio_frames: u64 = 0,
};

/// Records the stream into a new folder under `root`, with or without the display side.
fn recordOnce(gpa: std.mem.Allocator, io: Io, root: []const u8, with_display: bool) !Run {
    const layout = testLayout();
    var ring = try BlockRing.init(gpa, ring_slots, nch, block_samples);
    defer ring.deinit(gpa);
    const rec = try record.Recorder.create(gpa, io, &ring, root, .{
        .layout = layout,
        .settings = .{},
        .gateware = @splat(0),
        .board_id = 0,
        .cable_delay = @splat(0),
        .board_kind = "independence test",
    });
    var rec_open = true;
    errdefer if (rec_open) {
        _ = rec.finish();
    };
    const path = try gpa.dupe(u8, rec.path);
    errdefer gpa.free(path);
    try rec.start();

    var stop: Atomic(bool) = .init(false);
    // Before the producer starts, so it is offered every block.
    var reader: ring_mod.LossyReader = .init(&ring);
    var display: Display = .{ .gpa = gpa, .ring = &ring, .reader = &reader, .layout = &layout, .stop = &stop };
    const display_thread: ?std.Thread = if (with_display) try std.Thread.spawn(.{}, Display.run, .{&display}) else null;
    errdefer if (display_thread) |t| {
        stop.store(true, .release);
        t.join();
    };

    const producer = try std.Thread.spawn(.{}, produce, .{ &ring, io });
    producer.join();
    stop.store(true, .release);
    if (display_thread) |t| t.join();

    // Every block into the recording before it is closed (a stop ends it at the head).
    while (ring.position(rec.consumer) != ring.headPosition() and !rec.done.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
    const summary = rec.finish();
    rec_open = false;
    if (display.failure) |e| return e;
    return .{
        .path = path,
        .summary = summary,
        .seen = display.seen,
        .lost = reader.lost,
        .syncs = display.syncs,
        .waves = display.waves,
        .triggers = display.triggers,
        .audio_frames = display.audio_frames,
    };
}

fn readFile(gpa: std.mem.Allocator, io: Io, dir: []const u8, name: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name });
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20));
}

/// Fails, saying where, unless `got` is byte for byte `want`.
fn expectSameBytes(what: []const u8, want: []const u8, got: []const u8) !void {
    const n = @min(want.len, got.len);
    for (want[0..n], got[0..n], 0..) |a, b, i| {
        if (a != b) {
            std.debug.print("{s}: first difference at byte {d} (expected 0x{x:0>2}, got 0x{x:0>2})\n", .{ what, i, a, b });
            return error.TestUnexpectedResult;
        }
    }
    if (want.len != got.len) {
        std.debug.print("{s}: {d} bytes, expected {d}\n", .{ what, got.len, want.len });
        return error.TestUnexpectedResult;
    }
}

const Edges = struct { samples: []u8, words: []u8 };

/// What the producer generated, as the recorder's files would hold it.
fn expectedFiles(gpa: std.mem.Allocator) !struct { samples: []u8, edges: Edges } {
    const samples = try gpa.alloc(u8, total_samples * nch * 2);
    errdefer gpa.free(samples);
    var edge_s: std.ArrayList(u8) = .empty;
    errdefer edge_s.deinit(gpa);
    var edge_w: std.ArrayList(u8) = .empty;
    errdefer edge_w.deinit(gpa);
    var last: ?u16 = null;
    for (0..total_samples) |s| {
        const n: i64 = @intCast(s);
        for (0..nch) |ch| std.mem.writeInt(i16, samples[(s * nch + ch) * 2 ..][0..2], sampleValue(n, ch), .little);
        const w = ttlWord(n);
        if (last == null or last.? != w) {
            last = w;
            var b8: [8]u8 = undefined;
            std.mem.writeInt(i64, &b8, n, .little);
            try edge_s.appendSlice(gpa, &b8);
            var b2: [2]u8 = undefined;
            std.mem.writeInt(u16, &b2, w, .little);
            try edge_w.appendSlice(gpa, &b2);
        }
    }
    return .{ .samples = samples, .edges = .{ .samples = try edge_s.toOwnedSlice(gpa), .words = try edge_w.toOwnedSlice(gpa) } };
}

test "display processing never changes what is recorded" {
    const gpa = testing.allocator;
    const io = testing.io;
    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "/tmp/oez-independence-test-{d}", .{std.os.linux.getpid()});
    defer Io.Dir.cwd().deleteTree(io, base) catch {};
    var with_root_buf: [96]u8 = undefined;
    var without_root_buf: [96]u8 = undefined;
    const with_root = try std.fmt.bufPrint(&with_root_buf, "{s}/with-display", .{base});
    const without_root = try std.fmt.bufPrint(&without_root_buf, "{s}/without-display", .{base});

    const with = try recordOnce(gpa, io, with_root, true);
    defer gpa.free(with.path);
    const without = try recordOnce(gpa, io, without_root, false);
    defer gpa.free(without.path);

    // Both recordings are complete and whole.
    for ([_]*const Run{ &with, &without }) |r| {
        try testing.expectEqual(null, r.summary.failure);
        try testing.expectEqual(@as(u64, total_samples), r.summary.samples);
        try testing.expectEqual(@as(u64, 0), r.summary.gaps);
    }

    // The display side did its work: it saw blocks (and lost the rest, never held the
    // producer back), changed its panels part-way, found spikes, triggered, made sound.
    errdefer std.debug.print("display side: saw {d} of {d} blocks, lost {d}; {d} panel changes, {d} spike waveforms, {d} slope triggers, {d} audio frames\n", .{ with.seen, n_blocks, with.lost, with.syncs, with.waves, with.triggers, with.audio_frames });
    try testing.expect(with.seen > 0);
    try testing.expect(with.seen <= n_blocks);
    try testing.expectEqual(@as(u64, n_blocks), with.seen + with.lost);
    try testing.expect(with.syncs > 0);
    try testing.expect(with.waves > 0);
    try testing.expect(with.triggers > 0);
    try testing.expectEqual(with.seen * block_samples, with.audio_frames);
    try testing.expectEqual(@as(u64, 0), without.seen);

    // The data files: identical to each other and to what was generated.
    const want = try expectedFiles(gpa);
    defer {
        gpa.free(want.samples);
        gpa.free(want.edges.samples);
        gpa.free(want.edges.words);
    }
    const files = [_][]const u8{ "samples.i16", "ttl_sample.i64", "ttl_word.u16", "events.tsv", "index.bin" };
    var got: [2][files.len][]u8 = undefined;
    var loaded: usize = 0;
    defer for (got[0..loaded]) |set| for (set) |f| gpa.free(f);
    for ([_][]const u8{ with.path, without.path }, 0..) |p, k| {
        var n: usize = 0;
        errdefer for (got[k][0..n]) |f| gpa.free(f);
        for (files, 0..) |name, i| {
            got[k][i] = try readFile(gpa, io, p, name);
            n += 1;
        }
        loaded += 1;
    }
    try expectSameBytes("samples.i16 with the display side vs generated", want.samples, got[0][0]);
    try expectSameBytes("samples.i16 without the display side vs generated", want.samples, got[1][0]);
    try expectSameBytes("ttl_sample.i64 with the display side vs generated", want.edges.samples, got[0][1]);
    try expectSameBytes("ttl_sample.i64 without the display side vs generated", want.edges.samples, got[1][1]);
    try expectSameBytes("ttl_word.u16 with the display side vs generated", want.edges.words, got[0][2]);
    try expectSameBytes("ttl_word.u16 without the display side vs generated", want.edges.words, got[1][2]);
    try expectSameBytes("events.tsv with vs without the display side", got[1][3], got[0][3]);
    try testing.expect(want.edges.samples.len / 8 > 100);

    // The index records agree in everything except wall time, and describe the samples.
    const ia = got[0][4];
    const ib = got[1][4];
    const rs = record.IndexRecord.size;
    try testing.expectEqual(ia.len, ib.len);
    try testing.expect(ia.len > 0 and ia.len % rs == 0);
    var covered: u64 = 0;
    var next_first: i64 = 0;
    var offset: u64 = 0;
    var k: usize = 0;
    while (k < ia.len) : (k += rs) {
        const a = ia[k..][0..rs];
        const b = ib[k..][0..rs];
        // Bytes 24..32 are the wall time.
        try expectSameBytes("index record (before wall time)", a[0..24], b[0..24]);
        try expectSameBytes("index record (after wall time)", a[32..rs], b[32..rs]);
        const first = std.mem.readInt(i64, a[0..8], .little);
        const n = std.mem.readInt(u32, a[8..12], .little);
        try testing.expectEqual(next_first, first);
        try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, a[12..16], .little));
        try testing.expectEqual(offset, std.mem.readInt(u64, a[16..24], .little));
        try testing.expectEqual(@as(u64, @intCast(first)) * 1667, std.mem.readInt(u64, a[32..40], .little));
        const bytes = want.samples[offset..][0 .. n * nch * 2];
        try testing.expectEqual(std.hash.Crc32.hash(bytes), std.mem.readInt(u32, a[40..44], .little));
        next_first = first + n;
        offset += bytes.len;
        covered += n;
    }
    try testing.expectEqual(@as(u64, total_samples), covered);
}
