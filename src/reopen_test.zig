//! The reopen after a read error, end to end on the simulator (no window, no board): the
//! simulator fails with a read error; the recording is closed with the reason; the source
//! is opened again (once "gone", once failing, then for good) as `reopen.Reopen` says; a
//! second recording starts in the same session before acquisition does; and both folders
//! are read back against a copy of every block the ring carried. Both are also verified
//! with tools/dimna_read.py when python3 with numpy can be run.
//!
//! The acquisition thread reports the read error with `log.err`, which the test runner
//! counts as a failure of the test; so the scenario runs in a child process (as the
//! recorder's write-failure test does), whose exit status is the result, and the parent
//! then runs the reference reader on what it left.
//!
//! Files go to /tmp/dimna-reopen-test-<pid>/ and are removed afterwards.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const types = @import("types.zig");
const record = @import("record.zig");
const os = @import("os.zig");
const Sim = @import("sim.zig").Sim;
const BlockRing = @import("ring.zig").BlockRing;
const Acquisition = @import("acquisition.zig").Acquisition;
const Reopen = @import("reopen.zig").Reopen;
const IndexRecord = record.IndexRecord;

const wait_limit_ms = 10_000;

/// What the ring carried, block by block, as a reader saw it: the samples of each run.
const Seen = struct {
    /// Interleaved samples, [n][nch].
    data: std.ArrayList(i16) = .empty,
    first: ?i64 = null,
    next: i64 = 0,
    contiguous: bool = true,

    fn add(self: *Seen, gpa: std.mem.Allocator, b: *const types.Block) !void {
        if (b.len == 0) return;
        if (self.first == null) {
            self.first = b.first_sample;
        } else if (b.first_sample != self.next) self.contiguous = false;
        self.next = b.first_sample + @as(i64, @intCast(b.len));
        try self.data.appendSlice(gpa, b.samples());
    }
    fn deinit(self: *Seen, gpa: std.mem.Allocator) void {
        self.data.deinit(gpa);
    }
};

fn drain(ring: *BlockRing, me: usize, seen: *Seen) !void {
    while (ring.readSlot(me)) |b| {
        try seen.add(testing.allocator, b);
        ring.release(me);
    }
}

fn readFile(dir: []const u8, name: []const u8) ![]u8 {
    var buf: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name });
    return Io.Dir.cwd().readFileAlloc(testing.io, p, testing.allocator, .limited(1 << 30));
}

/// The recording in `dir` holds exactly `seen`'s samples, from sample `seen.first`, as one
/// gap-free stream whose index records point at the right bytes; returns its meta.toml.
fn expectRecording(dir: []const u8, seen: *const Seen, nch: usize) ![]u8 {
    const raw = try readFile(dir, "samples.i16");
    defer testing.allocator.free(raw);
    try testing.expectEqual(seen.data.items.len * 2, raw.len);
    for (seen.data.items, 0..) |v, k| {
        const got = std.mem.readInt(i16, raw[k * 2 ..][0..2], .little);
        if (got != v) {
            std.debug.print("{s}: value {d} (sample {d}, channel {d}) is {d}, not {d}\n", .{ dir, k, k / nch, k % nch, got, v });
            return error.TestUnexpectedResult;
        }
    }
    const index = try readFile(dir, "index.bin");
    defer testing.allocator.free(index);
    try testing.expectEqual(0, index.len % IndexRecord.size);
    var next = seen.first.?;
    var offset: u64 = 0;
    for (0..index.len / IndexRecord.size) |k| {
        const ir = IndexRecord.decode(index[k * IndexRecord.size ..][0..IndexRecord.size]);
        try testing.expectEqual(next, ir.first_sample);
        try testing.expectEqual(offset, ir.byte_offset);
        try testing.expectEqual(0, ir.flags);
        const bytes = raw[offset..][0 .. ir.n_samples * nch * 2];
        try testing.expectEqual(std.hash.Crc32.hash(bytes), ir.crc32);
        next += ir.n_samples;
        offset += bytes.len;
    }
    try testing.expectEqual(raw.len, offset);
    return readFile(dir, "meta.toml");
}

/// tools/dimna_read.py on `dir` must say nothing is wrong. Null: it could not be run here.
fn dimnaRead(dir: []const u8) !?bool {
    Io.Dir.cwd().access(testing.io, "tools/dimna_read.py", .{}) catch return null;
    const res = std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "python3", "-I", "tools/dimna_read.py", dir },
    }) catch return null;
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    if (std.mem.indexOf(u8, res.stderr, "No module named") != null) return null;
    std.debug.print("dimna_read.py {s}:\n{s}{s}", .{ dir, res.stdout, res.stderr });
    return res.term.success() and std.mem.indexOf(u8, res.stdout, "PROBLEM") == null and
        std.mem.indexOf(u8, res.stdout, "complete") != null;
}

test "a read error: the recording is closed with the reason, the source opened again, and every sample is in one of two folders" {
    const io = testing.io;
    var root_buf: [300]u8 = undefined;
    var tmp_buf: [200]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "{s}/dimna-reopen-test-{d}", .{ os.tempDir(&tmp_buf), os.getpid() });
    Io.Dir.cwd().deleteTree(io, root) catch {};
    defer Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root);
    var ebuf: [160]u8 = undefined;
    const err_path = try std.fmt.bufPrintSentinel(&ebuf, "{s}/child-stderr.txt", .{root}, 0);
    var sbuf: [160]u8 = undefined;
    const sessions = try std.fmt.bufPrint(&sbuf, "{s}/sessions", .{root});
    try runInChild(sessions, err_path);

    // ---- as the reference reader sees them: the session's two folders ----
    var dir = try Io.Dir.cwd().openDir(io, sessions, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    // The session folder, and the `current` link to it.
    var name_buf: [64]u8 = undefined;
    var name: ?[]const u8 = null;
    var entries: usize = 0;
    while (try it.next(io)) |e| {
        entries += 1;
        if (e.kind == .directory) name = try std.fmt.bufPrint(&name_buf, "{s}", .{e.name});
    }
    try testing.expectEqual(2, entries);
    const session_name = name orelse return error.NoSession;
    var ran = true;
    for ([_][]const u8{ "ephys", "ephys_2" }) |sub| {
        var pbuf: [256]u8 = undefined;
        const p = try std.fmt.bufPrint(&pbuf, "{s}/{s}/{s}", .{ sessions, session_name, sub });
        if (try dimnaRead(p)) |ok| try testing.expect(ok) else ran = false;
    }
    if (!ran) std.debug.print("reopen test: tools/dimna_read.py not run (no python3 with numpy, or not run from the source folder)\n", .{});
}

/// Runs `scenario(root)` in a child process with its stderr in `err_path`; fails if it does
/// (and shows that stderr).
fn runInChild(root: []const u8, err_path: [:0]const u8) !void {
    // Windows has no fork; the test is skipped there until it starts a second process.
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const c = std.c;
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const fd = c.open(err_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o600));
        if (fd >= 0) _ = c.dup2(fd, 2);
        scenario(root) catch |e| {
            std.debug.print("reopen test: {t}\n", .{e});
            c._exit(1);
        };
        c._exit(0);
    }
    var status: c_int = 0;
    const t0 = Io.Clock.awake.now(testing.io);
    while (true) {
        const w = c.waitpid(pid, &status, c.W.NOHANG);
        if (w < 0) return error.WaitFailed;
        if (w == pid) break;
        if (t0.untilNow(testing.io, .awake).toMilliseconds() > 3 * wait_limit_ms) {
            _ = c.kill(pid, .KILL);
            _ = c.waitpid(pid, &status, 0);
            return error.ScenarioHung;
        }
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    const st: u32 = @bitCast(status);
    if (!c.W.IFEXITED(st) or c.W.EXITSTATUS(st) != 0) {
        if (Io.Dir.cwd().readFileAlloc(testing.io, err_path, testing.allocator, .limited(1 << 20))) |text| {
            defer testing.allocator.free(text);
            std.debug.print("{s}", .{text});
        } else |_| {}
        std.debug.print("reopen test: the scenario failed (status {x}; its stderr is above)\n", .{st});
        return error.TestUnexpectedResult;
    }
}

fn scenario(root: []const u8) !void {
    const gpa = testing.allocator;
    const io = testing.io;

    var sim = try Sim.init(gpa, io, &.{16});
    defer sim.deinit();
    var settings: types.Settings = .{};
    settings.acquire_adc = true;
    try sim.applySettings(settings);
    // The read error 0.3 s into the first run; the board is then "gone" at the first look,
    // and the first real attempt fails.
    sim.fail_at_s = 0.3;
    sim.fail_times = 1;
    sim.reopen_absent = 1;
    sim.reopen_failures = 1;
    const layout = sim.layout();
    const nch = layout.numChannels();

    var ring = try BlockRing.init(gpa, 2048, nch, settings.block_samples);
    defer ring.deinit(gpa);
    const me = ring.addConsumer().?;
    var health: types.Health = .{};
    var acq: Acquisition = .{ .io = io, .source = .{ .sim = &sim }, .ring = &ring, .health = &health, .scratch = try .init(gpa, nch, settings.block_samples), .keep_awake = false };
    defer acq.scratch.deinit(gpa);
    const info: record.Info = .{ .layout = layout, .settings = settings, .gateware = @splat(0), .board_id = 0, .cable_delay = @splat(0), .board_kind = "simulated", .session = true };

    var rec1 = try record.Recorder.create(gpa, io, &ring, root, info);
    try rec1.start();
    var path1_buf: [256]u8 = undefined;
    const path1 = try std.fmt.bufPrint(&path1_buf, "{s}", .{rec1.path});
    try acq.start();

    // ---- the first run, until the read error ----
    var before: Seen = .{};
    defer before.deinit(gpa);
    const t0 = Io.Clock.awake.now(io);
    while (!acq.done.load(.acquire)) {
        try drain(&ring, me, &before);
        if (t0.untilNow(io, .awake).toMilliseconds() > wait_limit_ms) return error.NoReadError;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try drain(&ring, me, &before);
    try testing.expectEqual(@as(?anyerror, error.SimulatedReadError), acq.failure);

    // ---- closed with the reason, at once ----
    rec1.setStopReason("acquisition stopped by a read error (SimulatedReadError)");
    const sum1 = rec1.finish();
    try testing.expectEqual(@as(?anyerror, null), sum1.failure);

    // ---- opened again as the policy says ----
    var rp: Reopen = .init(.{ .delays_ms = &.{ 20, 20, 20 }, .absent_poll_ms = 20 }, 0);
    const clock0 = Io.Clock.awake.now(io).nanoseconds;
    rp.ended(acq.failure.?, 0);
    var rec2: ?*record.Recorder = null;
    var outcomes: [8]?anyerror = @splat(null);
    var n_outcomes: usize = 0;
    while (rp.state != .running) {
        try testing.expect(rp.state != .gave_up);
        const now = Io.Clock.awake.now(io).nanoseconds - clock0;
        if (rp.due(now)) {
            const outcome = acq.reopenSource(settings, layout);
            if (outcome) |_| {
                // The new recording first, so it has the first block of the new run.
                const session = std.fs.path.dirname(path1).?;
                var next = info;
                next.continue_in = session;
                next.start_text = "after a read error (SimulatedReadError); continues ephys";
                next.continues = .{ .path = path1, .end_sample = sum1.end_sample, .last_wall_ns = sum1.last_wall_ns };
                rec2 = try record.Recorder.create(gpa, io, &ring, root, next);
                try rec2.?.start();
                try acq.start();
            } else |e| {
                outcomes[n_outcomes] = e;
                n_outcomes += 1;
            }
            rp.result(outcome, now);
        }
        if (Io.Clock.awake.now(io).nanoseconds - clock0 > wait_limit_ms * std.time.ns_per_ms) return error.NeverReopened;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(2, n_outcomes);
    try testing.expectEqual(@as(?anyerror, error.BoardAbsent), outcomes[0]);
    try testing.expectEqual(@as(?anyerror, error.SimulatedOpenError), outcomes[1]);
    try testing.expectEqual(3, sim.reopens);
    try testing.expectEqual(1, rp.restarts);
    // The absent board did not use an attempt: one failure, one success.
    try testing.expectEqual(2, rp.attempt);

    // ---- the second run, past the point where the first failed (the fault was for one
    // run only), then a clean stop ----
    var after: Seen = .{};
    defer after.deinit(gpa);
    const t1 = Io.Clock.awake.now(io);
    while (t1.untilNow(io, .awake).toMilliseconds() < 600) {
        try testing.expect(!acq.done.load(.acquire));
        try drain(&ring, me, &after);
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    acq.join();
    try drain(&ring, me, &after);
    const sum2 = rec2.?.finish();
    try testing.expectEqual(@as(?anyerror, null), sum2.failure);

    // ---- what the ring carried ----
    try testing.expect(before.contiguous and after.contiguous);
    try testing.expectEqual(@as(?i64, 0), before.first);
    // Numbering starts again with the new run: hence a new folder.
    try testing.expectEqual(@as(?i64, 0), after.first);
    try testing.expect(before.data.items.len >= 8000 * nch);
    try testing.expect(after.data.items.len >= 12000 * nch);
    try testing.expectEqual(before.data.items.len / nch, sum1.samples);
    try testing.expectEqual(after.data.items.len / nch, sum2.samples);

    // ---- on disk: each folder exactly its run ----
    var path2_buf: [256]u8 = undefined;
    const path2 = try std.fmt.bufPrint(&path2_buf, "{s}_2", .{path1});
    try testing.expect(std.mem.endsWith(u8, path1, "/ephys"));
    const meta1 = try expectRecording(path1, &before, nch);
    defer gpa.free(meta1);
    const meta2 = try expectRecording(path2, &after, nch);
    defer gpa.free(meta2);
    try testing.expect(std.mem.indexOf(u8, meta1, "\nreason = \"acquisition stopped by a read error (SimulatedReadError)\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, meta1, "\n[final]\n") != null);
    try testing.expect(std.mem.indexOf(u8, meta2, "\n[final]\n") != null);
    try testing.expect(std.mem.indexOf(u8, meta2, "\nreason") == null);
    // The second names the first, where it ended, and about how long was not acquired:
    // the read error, then the 20 ms waits before each of the three attempts.
    var cont_buf: [512]u8 = undefined;
    const cont = try std.fmt.bufPrint(&cont_buf, "\ncontinues = \"{s}\"\ncontinues_end_sample = {d}\ngap_estimate_s = ", .{ path1, sum1.samples });
    const at = std.mem.indexOf(u8, meta2, cont) orelse {
        std.debug.print("meta.toml of the second recording:\n{s}", .{meta2});
        return error.NoContinuesKeys;
    };
    try testing.expect(std.mem.indexOf(u8, meta1, "continues") == null);
    const gap_text = std.mem.sliceTo(meta2[at + cont.len ..], '\n');
    const gap = try std.fmt.parseFloat(f64, gap_text);
    try testing.expect(gap >= 0.06 and gap < 2.0);
    const ev1 = try readFile(path1, "events.tsv");
    defer gpa.free(ev1);
    const ev2 = try readFile(path2, "events.tsv");
    defer gpa.free(ev2);
    var stop_line_buf: [128]u8 = undefined;
    const stop_line = try std.fmt.bufPrint(&stop_line_buf, "\n{d}\tstop\tacquisition stopped by a read error (SimulatedReadError)\n", .{sum1.samples});
    try testing.expect(std.mem.indexOf(u8, ev1, stop_line) != null);
    try testing.expect(std.mem.startsWith(u8, ev2, "sample\tkind\ttext\n0\tstart\tafter a read error (SimulatedReadError); continues ephys\n"));
}
