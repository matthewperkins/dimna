//! The recorder: a ring reader that writes the dimna recording format (v1). See `meta.toml` in
//! any recording for the layout; in short, one folder per recording:
//!
//!   samples.i16      int16 LE, sample-major [n_samples][num_channels], raw as acquired
//!   index.bin        one 48-byte LE record per chunk (~100 ms), see `IndexRecord`
//!   ttl_sample.i64   int64 LE, sample number of each TTL-input change (first entry: start)
//!   ttl_word.u16     uint16 LE, the 8-line input word from that sample on
//!   events.tsv       sample<TAB>kind<TAB>text, one line per event
//!   meta.toml        everything needed to read the above; rewritten with [final] at stop
//!
//! Crash safety: every file is append-only except meta.toml, which is replaced atomically.
//! Once a second the recorder syncs samples.i16, and only then appends that second's index
//! records, so an index record never points at data that is not on disk. A reader trusts
//! samples covered by the index (CRC-checked) and treats any tail beyond as unverified.
//!
//! The recorder never touches the board and never blocks acquisition: it reads blocks from
//! the ring, and on a write error it reports the failure and detaches from the ring.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const types = @import("types.zig");
const BlockRing = @import("ring.zig").BlockRing;
const events = @import("events.zig");
const Block = types.Block;
const Io = std.Io;
const Atomic = std.atomic.Value;
const log = std.log.scoped(.record);

pub const format_version = 1;
const native_le = builtin.cpu.arch.endian() == .little;

/// One record per chunk in index.bin. Serialized field by field, little-endian, 48 bytes.
pub const IndexRecord = struct {
    /// Board sample number of the chunk's first sample.
    first_sample: i64,
    n_samples: u32,
    /// Bit 0: the chunk does not follow the previous one (samples were lost before it).
    flags: u32,
    /// Byte offset of the chunk in samples.i16.
    byte_offset: u64,
    /// Host wall-clock time (ns since the Unix epoch) when the chunk's first block arrived.
    wall_ns: i64,
    /// Board acquisition clock at the chunk's first sample (see meta.toml board_clock_hz).
    board_clock: u64,
    /// CRC-32 (ISO-HDLC, as zlib.crc32) of the chunk's bytes in samples.i16.
    crc32: u32,

    pub const size = 48;
    pub const flag_gap: u32 = 1;

    pub fn encode(self: IndexRecord, out: *[size]u8) void {
        std.mem.writeInt(i64, out[0..8], self.first_sample, .little);
        std.mem.writeInt(u32, out[8..12], self.n_samples, .little);
        std.mem.writeInt(u32, out[12..16], self.flags, .little);
        std.mem.writeInt(u64, out[16..24], self.byte_offset, .little);
        std.mem.writeInt(i64, out[24..32], self.wall_ns, .little);
        std.mem.writeInt(u64, out[32..40], self.board_clock, .little);
        std.mem.writeInt(u32, out[40..44], self.crc32, .little);
        std.mem.writeInt(u32, out[44..48], 0, .little);
    }

    /// The inverse of `encode` (the padding word is ignored).
    pub fn decode(in: *const [size]u8) IndexRecord {
        return .{
            .first_sample = std.mem.readInt(i64, in[0..8], .little),
            .n_samples = std.mem.readInt(u32, in[8..12], .little),
            .flags = std.mem.readInt(u32, in[12..16], .little),
            .byte_offset = std.mem.readInt(u64, in[16..24], .little),
            .wall_ns = std.mem.readInt(i64, in[24..32], .little),
            .board_clock = std.mem.readInt(u64, in[32..40], .little),
            .crc32 = std.mem.readInt(u32, in[40..44], .little),
        };
    }
};

/// What goes into meta.toml besides the counts.
pub const Info = struct {
    layout: types.Layout,
    settings: types.Settings,
    gateware: [4]u32,
    board_id: u32,
    cable_delay: [4]i32,
    board_kind: []const u8 = "Open Ephys acquisition board (ECP5, FT600, ONI)",
    software: []const u8 = "dimna 0.0.0",
    /// Session layout: the files go into `<root>/<date_time>/ephys/` (so videos and notes of
    /// the same take can sit beside them), and `<root>/current` is made a link to the
    /// session folder. Otherwise the files go straight into `<root>/<date_time>/`.
    session: bool = false,
    /// What the TTL input lines are connected to ("" = not named), written to meta.toml.
    ttl_names: [8][]const u8 = @splat(""),
};

pub const Stats = struct {
    samples: Atomic(u64) = .init(0),
    chunks: Atomic(u64) = .init(0),
    gaps: Atomic(u64) = .init(0),
    ttl_edges: Atomic(u64) = .init(0),
    bytes: Atomic(u64) = .init(0),
    syncs: Atomic(u64) = .init(0),
    max_write_us: Atomic(u64) = .init(0),
    max_sync_us: Atomic(u64) = .init(0),
};

const chunk_seconds = 0.1;
const sync_ms = 1000;
const max_pending_edges = 1 << 16;

/// Makes `<root>/current` a link to the session folder `name`, replacing an older link in
/// one step (a link under a temporary name, renamed over it). Best effort: a recording is
/// not refused because the link could not be made.
fn pointCurrent(root_dir: Io.Dir, name: []const u8) void {
    const linux = std.os.linux;
    var target_buf: [128]u8 = undefined;
    const target = std.fmt.bufPrintSentinel(&target_buf, "{s}", .{name}, 0) catch return;
    _ = linux.unlinkat(root_dir.handle, ".current.new", 0);
    if (linux.errno(linux.symlinkat(target, root_dir.handle, ".current.new")) != .SUCCESS or
        linux.errno(linux.renameat(root_dir.handle, ".current.new", root_dir.handle, "current")) != .SUCCESS)
    {
        log.warn("could not point the 'current' link at {s}", .{name});
    }
}

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    io: Io,
    ring: *BlockRing,
    consumer: usize,
    info: Info,
    dir: Io.Dir,
    /// Absolute path of the recording folder.
    path: []u8,
    created_local: [40]u8 = undefined,
    created_len: usize = 0,
    samples_file: Io.File,
    index_file: Io.File,
    ttl_sample_file: Io.File,
    ttl_word_file: Io.File,
    events_file: Io.File,

    nch: usize,
    chunk_target: usize,
    /// Little-endian chunk bytes as int16, capacity `chunk_target + block capacity` samples.
    chunk: []i16,
    chunk_len: usize = 0,
    chunk_first: i64 = 0,
    chunk_clock: u64 = 0,
    chunk_wall: i64 = 0,
    chunk_flags: u32 = 0,
    next_expected: ?i64 = null,
    byte_offset: u64 = 0,
    first_sample: ?i64 = null,
    last_sample_end: i64 = 0,

    /// Index records written but not yet synced behind their samples.
    pending_index: []u8,
    pending_index_len: usize = 0,
    ttl_last: ?u16 = null,
    edge_samples: []i64,
    edge_words: []u16,
    edge_len: usize = 0,
    wall_offset_ns: i96,
    last_sync: Io.Timestamp,

    /// Events from another thread (e.g. applied settings changes), written to events.tsv.
    events_in: ?*events.EventQueue = null,
    /// Notes typed by the user (from the display thread), written to events.tsv too.
    notes_in: ?*events.EventQueue = null,

    stats: Stats = .{},
    /// For testing how failures are reported (set before `start`): fail the next write
    /// once this many samples are written; stall for `test_stall_ms` once, at
    /// `test_stall_after` samples.
    test_fail_after: ?u64 = null,
    test_stall_after: ?u64 = null,
    test_stall_ms: u32 = 0,
    /// The first sample in samples.i16, for readers on other threads (review); the lowest
    /// i64 until the first block has arrived.
    first_sample_shared: Atomic(i64) = .init(std.math.minInt(i64)),
    stop_flag: Atomic(bool) = .init(false),
    done: Atomic(bool) = .init(false),
    failure: ?anyerror = null,
    thread: ?std.Thread = null,

    /// Creates `<root>/<local date_time>/` and its files, and writes the first meta.toml.
    /// Registers a ring reader: the recording starts with the next block acquired, whether
    /// or not acquisition is already running.
    pub fn create(gpa: std.mem.Allocator, io: Io, ring: *BlockRing, root: []const u8, info: Info) !*Recorder {
        const nch = info.layout.numChannels();
        const bs = ring.slots[0].capacity;
        const self = try gpa.create(Recorder);
        errdefer gpa.destroy(self);

        var name_buf: [64]u8 = undefined;
        var created_buf: [40]u8 = undefined;
        const lt = localNow(&name_buf, &created_buf);

        try Io.Dir.cwd().createDirPath(io, root);
        var root_dir = try Io.Dir.cwd().openDir(io, root, .{});
        defer root_dir.close(io);
        // A second recording within the same second gets a suffix.
        var final_name_buf: [72]u8 = undefined;
        var final_name: []const u8 = lt.name;
        var attempt: usize = 1;
        while (true) : (attempt += 1) {
            root_dir.createDir(io, final_name, .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => {
                    final_name = try std.fmt.bufPrint(&final_name_buf, "{s}_{d}", .{ lt.name, attempt + 1 });
                    continue;
                },
                else => return e,
            };
            break;
        }
        var sub_buf: [96]u8 = undefined;
        const sub: []const u8 = if (info.session) try std.fmt.bufPrint(&sub_buf, "{s}/ephys", .{final_name}) else final_name;
        if (info.session) try root_dir.createDir(io, sub, .default_dir);
        // `iterate` gives a real descriptor (not O_PATH), which fsync needs (`syncDir`).
        var dir = try root_dir.openDir(io, sub, .{ .iterate = true });
        errdefer dir.close(io);
        const root_abs = try Io.Dir.cwd().realPathFileAlloc(io, root, gpa);
        defer gpa.free(root_abs);
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root_abs, sub });
        errdefer gpa.free(path);
        if (info.session) pointCurrent(root_dir, final_name);

        var files: [5]Io.File = undefined;
        const names = [5][]const u8{ "samples.i16", "index.bin", "ttl_sample.i64", "ttl_word.u16", "events.tsv" };
        var opened: usize = 0;
        errdefer for (files[0..opened]) |f| f.close(io);
        for (names, 0..) |n, k| {
            files[k] = try dir.createFile(io, n, .{ .exclusive = true });
            opened += 1;
        }

        const chunk_target: usize = @max(1, @as(usize, @intFromFloat(info.layout.sample_rate * chunk_seconds)));
        const chunk = try gpa.alloc(i16, (chunk_target + bs) * nch);
        errdefer gpa.free(chunk);
        const pending_index = try gpa.alloc(u8, IndexRecord.size * (sync_ms / 50 + 64));
        errdefer gpa.free(pending_index);
        const edge_samples = try gpa.alloc(i64, max_pending_edges);
        errdefer gpa.free(edge_samples);
        const edge_words = try gpa.alloc(u16, max_pending_edges);
        errdefer gpa.free(edge_words);

        self.* = .{
            .gpa = gpa,
            .io = io,
            .ring = ring,
            .consumer = undefined,
            .info = info,
            .dir = dir,
            .path = path,
            .samples_file = files[0],
            .index_file = files[1],
            .ttl_sample_file = files[2],
            .ttl_word_file = files[3],
            .events_file = files[4],
            .nch = nch,
            .chunk_target = chunk_target,
            .chunk = chunk,
            .pending_index = pending_index,
            .edge_samples = edge_samples,
            .edge_words = edge_words,
            .wall_offset_ns = Io.Clock.real.now(io).nanoseconds - Io.Clock.awake.now(io).nanoseconds,
            .last_sync = Io.Clock.awake.now(io),
        };
        @memcpy(self.created_local[0..lt.created.len], lt.created);
        self.created_len = lt.created.len;
        try self.events_file.writeStreamingAll(io, "sample\tkind\ttext\n");
        try self.writeMeta(null);
        try self.syncDir();
        // Last: once registered, the ring holds blocks for this reader.
        self.consumer = ring.addConsumer() orelse return error.TooManyRingReaders;
        log.info("recording to {s}", .{path});
        return self;
    }

    pub fn start(self: *Recorder) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        self.thread.?.setName(self.io, "recorder") catch {};
    }

    pub const Summary = struct {
        samples: u64,
        chunks: u64,
        gaps: u64,
        ttl_edges: u64,
        max_write_us: u64,
        max_sync_us: u64,
        failure: ?anyerror,
    };

    /// Asks the thread to finish without waiting for it: it records up to the last block
    /// acquired at the moment it notices, writes the last chunk, syncs and writes the final
    /// meta.toml. `done` turns true when it has; then call `finish`, which no longer waits.
    pub fn requestStop(self: *Recorder) void {
        self.stop_flag.store(true, .release);
    }

    /// Stops the recording as `requestStop` does and waits for it. Acquisition may carry
    /// on or have stopped. Then frees everything and returns the final counts.
    pub fn finish(self: *Recorder) Summary {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        self.ring.free(self.consumer);
        const st = &self.stats;
        const summary: Summary = .{
            .samples = st.samples.load(.monotonic),
            .chunks = st.chunks.load(.monotonic),
            .gaps = st.gaps.load(.monotonic),
            .ttl_edges = st.ttl_edges.load(.monotonic),
            .max_write_us = st.max_write_us.load(.monotonic),
            .max_sync_us = st.max_sync_us.load(.monotonic),
            .failure = self.failure,
        };
        defer self.gpa.destroy(self);
        self.samples_file.close(self.io);
        self.index_file.close(self.io);
        self.ttl_sample_file.close(self.io);
        self.ttl_word_file.close(self.io);
        self.events_file.close(self.io);
        self.dir.close(self.io);
        const gpa = self.gpa;
        gpa.free(self.chunk);
        gpa.free(self.pending_index);
        gpa.free(self.edge_samples);
        gpa.free(self.edge_words);
        gpa.free(self.path);
        return summary;
    }

    /// Backlog in blocks (how far the recorder is behind acquisition).
    pub fn backlog(self: *const Recorder) usize {
        return self.ring.backlog(self.consumer);
    }

    fn run(self: *Recorder) void {
        defer self.done.store(true, .release);
        self.loop() catch |e| {
            self.failure = e;
            log.err("recording FAILED ({t}); acquisition continues, recording stopped at {s}", .{ e, self.path });
            self.ring.detach(self.consumer);
            return;
        };
        // Done: stop holding blocks back (acquisition may be carrying on).
        self.ring.detach(self.consumer);
    }

    fn loop(self: *Recorder) !void {
        // Once asked to stop: the ring position the recording ends before.
        var end: ?usize = null;
        while (true) {
            if (end == null and self.stop_flag.load(.acquire)) end = self.ring.headPosition();
            var any = false;
            while (self.ring.readSlot(self.consumer)) |b| {
                if (end) |e| {
                    if (self.ring.position(self.consumer) == e) break;
                }
                try self.consume(b);
                self.ring.release(self.consumer);
                any = true;
                if (self.sinceSyncMs() >= sync_ms) try self.sync();
            }
            try self.drainEvents();
            if (end) |e| {
                if (self.ring.position(self.consumer) == e) break;
            }
            if (self.sinceSyncMs() >= sync_ms) try self.sync();
            if (!any) try self.io.sleep(.fromMilliseconds(2), .awake);
        }
        try self.flushChunk();
        try self.drainEvents();
        try self.event(self.last_sample_end, "stop", "");
        try self.sync();
        try self.writeMeta(self.last_sample_end);
        try self.syncDir();
        log.info(
            "recording closed: {d} samples in {d} chunks, {d} gaps, {d} TTL edges",
            .{
                self.stats.samples.load(.monotonic),
                self.stats.chunks.load(.monotonic),
                self.stats.gaps.load(.monotonic),
                self.stats.ttl_edges.load(.monotonic),
            },
        );
    }

    fn sinceSyncMs(self: *Recorder) i64 {
        return self.last_sync.untilNow(self.io, .awake).toMilliseconds();
    }

    fn consume(self: *Recorder, b: *const Block) !void {
        if (b.len == 0) return;
        if (self.first_sample == null) {
            self.first_sample = b.first_sample;
            self.first_sample_shared.store(b.first_sample, .release);
            try self.event(b.first_sample, "start", "");
        }
        const gap = if (self.next_expected) |e| b.first_sample != e else false;
        if (gap) {
            try self.flushChunk();
            _ = self.stats.gaps.fetchAdd(1, .monotonic);
        }
        if (self.chunk_len == 0) {
            self.chunk_first = b.first_sample;
            self.chunk_clock = b.hw_time[0];
            self.chunk_wall = @intCast(b.acquired_ns + self.wall_offset_ns);
            self.chunk_flags = if (gap) IndexRecord.flag_gap else 0;
        }
        const n = b.len * self.nch;
        const dst = self.chunk[self.chunk_len * self.nch ..][0..n];
        if (native_le) {
            @memcpy(dst, b.samples());
        } else {
            for (dst, b.samples()) |*d, s| d.* = @byteSwap(s);
        }
        self.chunk_len += b.len;
        for (b.ttl[0..b.len], 0..) |w, i| {
            if (self.ttl_last == null or self.ttl_last.? != w) {
                self.ttl_last = w;
                if (self.edge_len == max_pending_edges) try self.flushEdges();
                self.edge_samples[self.edge_len] = b.first_sample + @as(i64, @intCast(i));
                self.edge_words[self.edge_len] = w;
                self.edge_len += 1;
            }
        }
        self.next_expected = b.first_sample + @as(i64, @intCast(b.len));
        self.last_sample_end = self.next_expected.?;
        if (self.chunk_len >= self.chunk_target) try self.flushChunk();
    }

    fn flushChunk(self: *Recorder) !void {
        if (self.chunk_len == 0) return;
        const bytes = std.mem.sliceAsBytes(self.chunk[0 .. self.chunk_len * self.nch]);
        const written = self.stats.samples.load(.monotonic);
        if (self.test_fail_after) |n| {
            if (written >= n) return error.InjectedFailure;
        }
        if (self.test_stall_after) |n| {
            if (written >= n) {
                self.test_stall_after = null;
                try self.io.sleep(.fromMilliseconds(self.test_stall_ms), .awake);
            }
        }
        const t0 = Io.Clock.awake.now(self.io);
        try self.samples_file.writeStreamingAll(self.io, bytes);
        maxStore(&self.stats.max_write_us, @intCast(t0.untilNow(self.io, .awake).toMicroseconds()));
        const rec: IndexRecord = .{
            .first_sample = self.chunk_first,
            .n_samples = @intCast(self.chunk_len),
            .flags = self.chunk_flags,
            .byte_offset = self.byte_offset,
            .wall_ns = self.chunk_wall,
            .board_clock = self.chunk_clock,
            .crc32 = std.hash.Crc32.hash(bytes),
        };
        if (self.pending_index_len + IndexRecord.size > self.pending_index.len) try self.sync();
        rec.encode(self.pending_index[self.pending_index_len..][0..IndexRecord.size]);
        self.pending_index_len += IndexRecord.size;
        self.byte_offset += bytes.len;
        _ = self.stats.samples.fetchAdd(self.chunk_len, .monotonic);
        _ = self.stats.chunks.fetchAdd(1, .monotonic);
        _ = self.stats.bytes.fetchAdd(bytes.len, .monotonic);
        self.chunk_len = 0;
    }

    fn flushEdges(self: *Recorder) !void {
        if (self.edge_len == 0) return;
        const s = self.edge_samples[0..self.edge_len];
        const w = self.edge_words[0..self.edge_len];
        if (!native_le) {
            for (s) |*x| x.* = @byteSwap(x.*);
            for (w) |*x| x.* = @byteSwap(x.*);
        }
        try self.ttl_sample_file.writeStreamingAll(self.io, std.mem.sliceAsBytes(s));
        try self.ttl_word_file.writeStreamingAll(self.io, std.mem.sliceAsBytes(w));
        _ = self.stats.ttl_edges.fetchAdd(self.edge_len, .monotonic);
        self.edge_len = 0;
    }

    /// Samples to disk first, then the index records that describe them.
    fn sync(self: *Recorder) !void {
        const t0 = Io.Clock.awake.now(self.io);
        try self.samples_file.sync(self.io);
        if (self.pending_index_len > 0) {
            try self.index_file.writeStreamingAll(self.io, self.pending_index[0..self.pending_index_len]);
            self.pending_index_len = 0;
        }
        try self.flushEdges();
        try self.index_file.sync(self.io);
        try self.ttl_sample_file.sync(self.io);
        try self.ttl_word_file.sync(self.io);
        try self.events_file.sync(self.io);
        maxStore(&self.stats.max_sync_us, @intCast(t0.untilNow(self.io, .awake).toMicroseconds()));
        _ = self.stats.syncs.fetchAdd(1, .monotonic);
        self.last_sync = Io.Clock.awake.now(self.io);
    }

    fn syncDir(self: *Recorder) !void {
        const f: Io.File = .{ .handle = self.dir.handle, .flags = .{ .nonblocking = false } };
        try f.sync(self.io);
    }

    fn drainEvents(self: *Recorder) !void {
        if (self.events_in) |q| {
            while (q.pop()) |e| try self.event(e.sample, e.kind(), e.text());
        }
        if (self.notes_in) |q| {
            while (q.pop()) |e| try self.event(e.sample, e.kind(), e.text());
        }
    }

    /// Appends an event line. Tabs and newlines in `text` become spaces.
    pub fn event(self: *Recorder, sample: i64, kind: []const u8, text: []const u8) !void {
        var buf: [1024]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        try w.print("{d}\t{s}\t", .{ sample, kind });
        for (text[0..@min(text.len, 900)]) |ch| try w.writeByte(if (ch == '\t' or ch == '\n' or ch == '\r') ' ' else ch);
        try w.writeByte('\n');
        try self.events_file.writeStreamingAll(self.io, w.buffered());
    }

    fn writeMeta(self: *Recorder, final_end: ?i64) !void {
        const tmp = "meta.toml.tmp";
        var f = try self.dir.createFile(self.io, tmp, .{});
        var buf: [16 * 1024]u8 = undefined;
        var fw = f.writer(self.io, &buf);
        try writeToml(&fw.interface, self, final_end);
        try fw.interface.flush();
        try f.sync(self.io);
        f.close(self.io);
        try Io.Dir.rename(self.dir, tmp, self.dir, "meta.toml", self.io);
    }
};

fn maxStore(a: *Atomic(u64), v: u64) void {
    _ = a.fetchMax(v, .monotonic);
}

const LocalTime = struct { name: []const u8, created: []const u8 };

/// Folder name `YYYY-MM-DD_HH-MM-SS` and an RFC 3339 timestamp, both in local time.
/// The local time now, as "2026-11-12T14:03:22+01:00".
pub fn localTime(buf: *[40]u8) []const u8 {
    var name_buf: [64]u8 = undefined;
    return localNow(&name_buf, buf).created;
}

fn localNow(name_buf: []u8, created_buf: []u8) LocalTime {
    var t: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&t, &tm);
    const y = tm.tm_year + 1900;
    const mo: u32 = @intCast(tm.tm_mon + 1);
    const d: u32 = @intCast(tm.tm_mday);
    const h: u32 = @intCast(tm.tm_hour);
    const mi: u32 = @intCast(tm.tm_min);
    const s: u32 = @intCast(tm.tm_sec);
    const off_min = @divTrunc(tm.tm_gmtoff, 60);
    const sign: u8 = if (off_min < 0) '-' else '+';
    const aoff: u64 = @abs(off_min);
    return .{
        .name = std.fmt.bufPrint(name_buf, "{d}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}-{d:0>2}", .{ y, mo, d, h, mi, s }) catch unreachable,
        .created = std.fmt.bufPrint(
            created_buf,
            "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>2}:{d:0>2}",
            .{ y, mo, d, h, mi, s, sign, aoff / 60, aoff % 60 },
        ) catch unreachable,
    };
}

fn tomlStr(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

fn writeToml(w: *Io.Writer, r: *const Recorder, final_end: ?i64) !void {
    const l = &r.info.layout;
    const st = &r.info.settings;
    try w.writeAll(
        \\# dimna recording. All binary files are little-endian and append-only.
        \\#   samples.i16     int16 [n_samples][num_channels]; physical value = raw * bit_volts
        \\#   index.bin       48-byte records, one per chunk:
        \\#                   first_sample i64, n_samples u32, flags u32 (bit 0 = gap before),
        \\#                   byte_offset u64, wall_ns i64, board_clock u64, crc32 u32, pad u32
        \\#   ttl_sample.i64  sample number of each TTL-input change (first entry: initial state)
        \\#   ttl_word.u16    8-line input word from that sample on (bit k = TTL line k+1)
        \\#   events.tsv      sample<TAB>kind<TAB>text
        \\# Samples are numbered by the board; sample n is at row n - first_sample when there are
        \\# no gaps (see index.bin flags). Data past the last index record is unverified.
        \\
        \\
    );
    try w.print("format = \"dimna-recording\"\nformat_version = {d}\nbyte_order = \"little\"\n", .{format_version});
    try w.writeAll("software = ");
    try tomlStr(w, r.info.software);
    try w.print("\ncreated = {s}\n", .{r.created_local[0..r.created_len]});
    try w.print(
        "sample_rate = {f}\nboard_clock_hz = {f}\nnum_channels = {d}\nsamples_per_chunk = {d}\n",
        .{ fmtFloat(l.sample_rate), fmtFloat(l.hw_clock_hz), l.numChannels(), r.chunk_target },
    );

    try w.writeAll("\n[channels]\nname = [");
    var n: usize = 0;
    for (0..l.num_electrodes) |i| try listItem(w, &n, "CH", i + 1);
    for (0..l.num_aux) |i| try listItem(w, &n, "AUX", i + 1);
    for (0..l.num_adc) |i| try listItem(w, &n, "ADC", i + 1);
    try w.writeAll("]\nkind = [");
    for (0..l.numChannels()) |i| {
        if (i > 0) try w.writeAll(", ");
        try tomlStr(w, if (i < l.num_electrodes) "electrode" else if (i < l.num_electrodes + l.num_aux) "aux" else "adc");
    }
    try w.writeAll("]\nunits = [");
    for (0..l.numChannels()) |i| {
        if (i > 0) try w.writeAll(", ");
        try tomlStr(w, if (i < l.num_electrodes) "uV" else "V");
    }
    try w.writeAll("]\nbit_volts = [");
    for (0..l.numChannels()) |i| {
        if (i > 0) try w.writeAll(", ");
        const bv: f64 = if (i < l.num_electrodes)
            types.electrode_uv_per_bit
        else if (i < l.num_electrodes + l.num_aux)
            types.aux_v_per_bit
        else
            types.adc_v_per_bit;
        try w.print("{f}", .{fmtFloat(bv)});
    }
    try w.writeAll("]\nheadstage = [");
    for (0..l.numChannels()) |i| {
        if (i > 0) try w.writeAll(", ");
        var name: []const u8 = "";
        for (l.headstageSlice()) |h| {
            if (i >= h.first_channel and i < h.first_channel + h.num_channels) name = types.headstage_names[h.slot];
        }
        try tomlStr(w, name);
    }
    try w.writeAll("]\n# AUX values are raw - 32768, i.e. the true voltage minus 1.2255 V (as stock).\n");

    for (l.headstageSlice()) |h| {
        try w.writeAll("\n[[headstage]]\nslot = ");
        try tomlStr(w, types.headstage_names[h.slot]);
        try w.writeAll("\nchip = ");
        try tomlStr(w, h.chip);
        const half = std.mem.eql(u8, h.chip, "RHD2132") and h.num_channels == 16;
        try w.print("\nnum_channels = {d}\nfirst_channel = {d}\n", .{ h.num_channels, h.first_channel });
        if (half) try w.writeAll("# 16-channel RHD2132 headstage: channels are chip inputs 8..23.\nfirst_chip_input = 8\n");
    }

    const fw = r.info.gateware;
    try w.writeAll("\n[board]\nkind = ");
    try tomlStr(w, r.info.board_kind);
    try w.print(
        "\ngateware = \"{d}.{d}.{d}\"\nboard_id = 0x{x}\ncable_delay = [{d}, {d}, {d}, {d}]\n",
        .{
            fw[0],
            fw[1],
            fw[2],
            r.info.board_id,
            r.info.cable_delay[0],
            r.info.cable_delay[1],
            r.info.cable_delay[2],
            r.info.cable_delay[3],
        },
    );
    try w.print(
        "\n[settings]\nlower_bandwidth_hz = {f}\nupper_bandwidth_hz = {f}\ndsp_enabled = {}\ndsp_cutoff_hz = {f}\nacquire_aux = {}\nacquire_adc = {}\nfast_settle = {}\nleds = {}\nusb_block_bytes = {d}\nblock_samples = {d}\n",
        .{
            fmtFloat(st.lower_bandwidth),
            fmtFloat(st.upper_bandwidth),
            st.dsp_enabled,
            fmtFloat(st.dsp_cutoff),
            st.acquire_aux,
            st.acquire_adc,
            st.fast_settle,
            st.leds,
            st.usb_block_bytes,
            st.block_samples,
        },
    );

    try w.writeAll("\n# What the TTL input lines carry, line 1 first (\"\" = not named).\n[ttl]\nline_names = [");
    for (r.info.ttl_names, 0..) |name, i| {
        if (i > 0) try w.writeAll(", ");
        try tomlStr(w, name);
    }
    try w.writeAll("]\n");
    if (r.first_sample) |fs| try w.print("\n[start]\nfirst_sample = {d}\n", .{fs});
    if (final_end) |end| {
        var lt_name: [64]u8 = undefined;
        var lt_created: [40]u8 = undefined;
        const lt = localNow(&lt_name, &lt_created);
        const s = &r.stats;
        try w.print(
            "\n# Written at a clean stop. Absent if the recording was interrupted.\n[final]\nstopped = {s}\nend_sample = {d}\nsamples = {d}\nchunks = {d}\ngaps = {d}\nttl_edges = {d}\nbytes = {d}\n",
            .{
                lt.created,
                end,
                s.samples.load(.monotonic),
                s.chunks.load(.monotonic),
                s.gaps.load(.monotonic),
                s.ttl_edges.load(.monotonic),
                s.bytes.load(.monotonic),
            },
        );
    }
}

fn listItem(w: *Io.Writer, n: *usize, prefix: []const u8, k: usize) !void {
    if (n.* > 0) try w.writeAll(", ");
    try w.print("\"{s}{d}\"", .{ prefix, k });
    n.* += 1;
}

/// TOML needs a decimal point or exponent for floats; `{d}` of 30000.0 prints "30000".
const FmtFloat = struct {
    v: f64,
    pub fn format(self: FmtFloat, w: *Io.Writer) Io.Writer.Error!void {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{self.v}) catch unreachable;
        try w.writeAll(s);
        if (std.mem.indexOfAny(u8, s, ".eEn") == null) try w.writeAll(".0");
    }
};
fn fmtFloat(v: f64) FmtFloat {
    return .{ .v = v };
}

test "index record encodes to 48 little-endian bytes" {
    var out: [IndexRecord.size]u8 = undefined;
    (IndexRecord{
        .first_sample = -2,
        .n_samples = 3000,
        .flags = 1,
        .byte_offset = 0x0102030405060708,
        .wall_ns = 7,
        .board_clock = 9,
        .crc32 = 0xdeadbeef,
    }).encode(&out);
    try std.testing.expectEqual(@as(i64, -2), std.mem.readInt(i64, out[0..8], .little));
    try std.testing.expectEqual(@as(u8, 0x08), out[16]);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), std.mem.readInt(u32, out[40..44], .little));
}
