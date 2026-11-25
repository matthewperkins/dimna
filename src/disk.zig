//! The free space on the disk a recording goes to: how fast a recording of a layout fills
//! it, how long until it is full, and when that is too little to start or calls for an
//! alarm. Shared by the display (`src/gui/session.zig`) and `dimna-headless`.
//!
//! The last `reserve_bytes` of the disk count as full in every figure of time left, and a
//! recording is not started with less than that free (the owner, 2026-11-25).

const std = @import("std");
const types = @import("types.zig");
const record = @import("record.zig");
const os = @import("os.zig");

/// Free space that counts as none. `DIMNA_TEST_DISK_RESERVE_GB` may raise it (for
/// testing), never lower it (`reserveFrom`).
pub const reserve_bytes: f64 = 10e9;

/// Time left on the disk below which there is an alarm, each once until acknowledged and
/// raised again only below the next; below `warn_s` a warning stays.
pub const alarm_s = [_]f64{ 2 * 3600, 3600, 30 * 60, 5 * 60, 60 };
pub const warn_s = 2 * 3600;

/// The reserve: `reserve_bytes`, or `test_gb` GB when that is more.
pub fn reserveFrom(test_gb: ?f64) f64 {
    const gb = test_gb orelse return reserve_bytes;
    if (!std.math.isFinite(gb)) return reserve_bytes;
    return @max(reserve_bytes, gb * 1e9);
}

/// How many of `alarm_s` a time left of `seconds` is below (0: none).
pub fn level(seconds: f64) usize {
    var n: usize = 0;
    for (alarm_s) |limit| {
        if (seconds < limit) n += 1;
    }
    return n;
}

/// The recorder's chunk length (`chunk_seconds` in record.zig): one index record each.
const chunk_seconds = 0.1;

/// Bytes a recording of `layout` writes per second: every channel as int16 at the sample
/// rate, and an index record a chunk. TTL changes (10 bytes each) and the small text files
/// are left out.
pub fn bytesPerSecond(layout: types.Layout) f64 {
    const nch: f64 = @floatFromInt(layout.numChannels());
    const chunk_samples = @max(1, @floor(layout.sample_rate * chunk_seconds));
    return nch * 2 * layout.sample_rate + record.IndexRecord.size * layout.sample_rate / chunk_samples;
}

/// How long until the disk is full, and the free bytes now.
pub const Left = struct { seconds: f64, free_bytes: u64 };

/// From `free_bytes` free and a recording writing `rate` bytes per second.
pub fn leftAt(free_bytes: u64, reserve: f64, rate: f64) ?Left {
    if (!(rate > 0)) return null;
    const free: f64 = @floatFromInt(free_bytes);
    return .{ .seconds = @max(0, free - reserve) / rate, .free_bytes = free_bytes };
}

/// Whether a recording may start with `free_bytes` free: not with less than the reserve,
/// and not when it will need (`needed_bytes`, if its length is known) more than the free
/// space less the reserve.
pub const Start = enum { ok, too_little_free, too_long };

pub fn startCheck(free_bytes: ?u64, reserve: f64, needed_bytes: ?f64) Start {
    const free: f64 = @floatFromInt(free_bytes orelse return .ok);
    if (free < reserve) return .too_little_free;
    if (needed_bytes) |n| if (n > free - reserve) return .too_long;
    return .ok;
}

/// How long until the disk a recording is written to is full, from how fast its free space
/// has been falling over the last few minutes (the cameras may write to the same disk) or
/// the recorder's own rate, whichever is faster. Looked at every `period_s` while
/// recording; `left` is null until there is a rate to go by.
///
/// btrfs (the rig's /home): free space moves only when a transaction commits (every 120 s
/// there), so the window is 5 minutes and the recorder's rate is the floor; with
/// compression the recorder's rate overstates, and the falling free space is the truth.
/// btrfs can refuse writes for want of metadata space before the free space reaches 0, so
/// the last `reserve_bytes` count as full.
pub const DiskWatch = struct {
    /// Free bytes and recorder bytes, every `period_s`: the newest `n` of them.
    t: [n]f64 = undefined,
    free: [n]f64 = undefined,
    own: [n]f64 = undefined,
    len: usize = 0,
    next_s: f64 = 0,
    /// Free space that counts as none (`reserveFrom`).
    reserve: f64 = reserve_bytes,

    pub const period_s = 5;
    const n = 61; // five minutes of history

    /// Forgets what it saw (a new recording).
    pub fn reset(self: *DiskWatch) void {
        self.* = .{ .reserve = self.reserve };
    }

    /// Whether it is time for another look (`add`) at `now_s`.
    pub fn due(self: *const DiskWatch, now_s: f64) bool {
        return now_s >= self.next_s;
    }

    /// One look: at `now_s`, `free_bytes` free on the disk and `written` bytes written by
    /// the recorder so far.
    pub fn add(self: *DiskWatch, now_s: f64, free_bytes: u64, written: u64) void {
        if (self.len == n) {
            std.mem.copyForwards(f64, self.t[0 .. n - 1], self.t[1..]);
            std.mem.copyForwards(f64, self.free[0 .. n - 1], self.free[1..]);
            std.mem.copyForwards(f64, self.own[0 .. n - 1], self.own[1..]);
            self.len -= 1;
        }
        self.t[self.len] = now_s;
        self.free[self.len] = @floatFromInt(free_bytes);
        self.own[self.len] = @floatFromInt(written);
        self.len += 1;
        self.next_s = now_s + period_s;
    }

    /// Seconds until full at the fastest of the two rates and `floor_rate` (the rate the
    /// layout writes at, `bytesPerSecond`; 0 for none), and the free bytes now. With a
    /// floor, there is a figure from the first look.
    pub fn left(self: *const DiskWatch, floor_rate: f64) ?Left {
        if (self.len == 0) return null;
        var rate = @max(0, floor_rate);
        if (self.len >= 2) {
            const dt = self.t[self.len - 1] - self.t[0];
            if (dt > 0) {
                const falling = (self.free[0] - self.free[self.len - 1]) / dt;
                const own = (self.own[self.len - 1] - self.own[0]) / dt;
                rate = @max(rate, @max(falling, own));
            }
        }
        const free = self.free[self.len - 1];
        if (rate <= 0) return null;
        return .{ .seconds = @max(0, free - self.reserve) / rate, .free_bytes = @intFromFloat(free) };
    }
};

/// The thresholds of `alarm_s` passed, each raised once: `crossed` is true when the time
/// left has fallen below one more of them than last raised. When the disk gets more room
/// (files deleted, cameras stopped) it is raised again on the next fall.
pub const Raised = struct {
    seen: usize = 0,

    pub fn crossed(self: *Raised, left: ?Left) bool {
        const now = if (left) |l| level(l.seconds) else 0;
        self.seen = @min(self.seen, now);
        if (now <= self.seen) return false;
        self.seen = now;
        return true;
    }
};

/// Free bytes (for an unprivileged user) on the filesystem holding `path`, or null.
pub fn freeBytes(path: []const u8) ?u64 {
    var z: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len == 0 or path.len >= z.len) return null;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    return os.freeBytes(&z);
}

/// The same for the nearest folder of `path` that exists (the recordings' folder is made
/// by the first recording), or null.
pub fn freeBytesNear(path: []const u8) ?u64 {
    var p = path;
    while (p.len > 0) {
        if (freeBytes(p)) |free| return free;
        p = std.fs.path.dirname(p) orelse return null;
    }
    return null;
}

/// "about 8 h 20 min", "about 12 min", "about 40 s", in English (the headless program's
/// lines; the display has its own, in the user's language).
pub fn formatLeft(buf: []u8, seconds: f64) []const u8 {
    const s = @max(0, seconds);
    if (s >= 3600) {
        const total_min: u64 = @intFromFloat(@round(s / 60));
        return std.fmt.bufPrint(buf, "about {d} h {d} min", .{ total_min / 60, total_min % 60 }) catch "";
    }
    if (s >= 90) return std.fmt.bufPrint(buf, "about {d:.0} min", .{s / 60}) catch "";
    return std.fmt.bufPrint(buf, "about {d:.0} s", .{s}) catch "";
}

const testing = std.testing;

test "bytesPerSecond: a dimna-headless --sim recording's file sizes" {
    // `dimna-headless --sim 32,16 --seconds 10 --record DIR` (48 channels at 30 kHz) wrote
    // 300032 samples: samples.i16 28803072 bytes, index.bin 4800 (100 chunks); TTL 510 B.
    var l: types.Layout = .{ .sample_rate = 30000, .hw_clock_hz = 50e6, .num_electrodes = 48 };
    const samples: f64 = 300032;
    const written: f64 = 28803072 + 4800;
    const predicted = bytesPerSecond(l) * samples / l.sample_rate;
    // Within the index's rounding (one chunk) and the TTL files.
    try testing.expectApproxEqAbs(written, predicted, 48 + 510);
    try testing.expectApproxEqAbs(@as(f64, 48 * 2 * 30000 + 480), bytesPerSecond(l), 1e-6);
    // AUX and ADC count; so does the rate.
    l.num_aux = 6;
    l.num_adc = 8;
    l.sample_rate = 20000;
    try testing.expectApproxEqAbs(@as(f64, 62 * 2 * 20000 + 480), bytesPerSecond(l), 1e-6);
}

test "disk time left: the faster of the free space falling and the recorder's rate, less the reserve" {
    var d: DiskWatch = .{};
    try testing.expect(d.left(0) == null);
    // Free space falls 10 MB/s (cameras too); the recorder writes 3 MB/s.
    var t: f64 = 0;
    while (t <= 60) : (t += DiskWatch.period_s) d.add(t, @intFromFloat(105e9 - 10e6 * t), @intFromFloat(3e6 * t));
    const l = d.left(0).?;
    try testing.expectApproxEqRel(@as(f64, (105e9 - 10e6 * 60 - reserve_bytes) / 10e6), l.seconds, 1e-9);
    // Free space that has not moved (btrfs has not committed yet): the recorder's rate.
    var e: DiskWatch = .{};
    e.add(0, 50e9, 0);
    e.add(5, 50e9, 15e6);
    try testing.expectApproxEqRel(@as(f64, (50e9 - reserve_bytes) / 3e6), e.left(0).?.seconds, 1e-9);
    // Within the reserve: no time left.
    var f: DiskWatch = .{};
    f.add(0, 4e9, 0);
    f.add(5, 4e9, 15e6);
    try testing.expectEqual(@as(f64, 0), f.left(0).?.seconds);
}

test "the disk window keeps the last five minutes" {
    var d: DiskWatch = .{};
    var t: f64 = 0;
    // Ten minutes: free space fell fast in the first five, not at all in the last five.
    while (t <= 600) : (t += DiskWatch.period_s) d.add(t, if (t < 300) @intFromFloat(100e9 - 100e6 * t) else @intFromFloat(70e9), @intFromFloat(1e6 * t));
    try testing.expectEqual(@as(f64, 300), d.t[0]);
    try testing.expectApproxEqRel(@as(f64, (70e9 - reserve_bytes) / 1e6), d.left(0).?.seconds, 1e-9);
}

test "disk time left with the layout's rate as a floor: a figure from the first look" {
    var d: DiskWatch = .{};
    try testing.expect(d.left(3e6) == null);
    d.add(0, 50e9, 0);
    try testing.expectApproxEqRel(@as(f64, (50e9 - reserve_bytes) / 3e6), d.left(3e6).?.seconds, 1e-9);
    try testing.expect(d.left(0) == null);
    // Faster than the floor: the faster rate; slower: the floor.
    d.add(5, 50e9 - 50e6, 50e6);
    try testing.expectApproxEqRel(@as(f64, (50e9 - 50e6 - reserve_bytes) / 10e6), d.left(3e6).?.seconds, 1e-9);
    try testing.expectApproxEqRel(@as(f64, (50e9 - 50e6 - reserve_bytes) / 20e6), d.left(20e6).?.seconds, 1e-9);
}

test "the reserve is 10 GB, raised for testing but never lowered" {
    try testing.expectEqual(@as(f64, 10e9), reserveFrom(null));
    try testing.expectEqual(@as(f64, 10e9), reserveFrom(2));
    try testing.expectEqual(@as(f64, 10e9), reserveFrom(-5));
    try testing.expectEqual(@as(f64, 10e9), reserveFrom(std.math.nan(f64)));
    try testing.expectEqual(@as(f64, 50e9), reserveFrom(50));
    try testing.expectEqual(reserve_bytes, (DiskWatch{}).reserve);
}

test "starting a recording: refused under the reserve, or when its length will not fit" {
    try testing.expectEqual(Start.too_little_free, startCheck(9_999_999_999, 10e9, null));
    try testing.expectEqual(Start.ok, startCheck(10_000_000_000, 10e9, null));
    try testing.expectEqual(Start.ok, startCheck(87e9, 10e9, null));
    // Free space unknown: not refused (the recorder says if it cannot write).
    try testing.expectEqual(Start.ok, startCheck(null, 10e9, 1e12));
    // A length: 77 GB fits in 87 GB free, 77.1 does not.
    try testing.expectEqual(Start.ok, startCheck(87e9, 10e9, 77e9));
    try testing.expectEqual(Start.too_long, startCheck(87e9, 10e9, 77.1e9));
    try testing.expectEqual(Start.too_little_free, startCheck(5e9, 10e9, 1));
}

test "disk alarms: at 2 h, 1 h, 30 min, 5 min and 1 min, each once; again after room was made" {
    try testing.expectEqual(@as(usize, 0), level(2 * 3600));
    try testing.expectEqual(@as(usize, 1), level(2 * 3600 - 1));
    try testing.expectEqual(@as(usize, 2), level(3599));
    try testing.expectEqual(@as(usize, 3), level(29 * 60));
    try testing.expectEqual(@as(usize, 4), level(4 * 60));
    try testing.expectEqual(@as(usize, 5), level(59));
    var r: Raised = .{};
    const at = struct {
        fn f(s: f64) ?Left {
            return .{ .seconds = s, .free_bytes = 20e9 };
        }
    }.f;
    try testing.expect(!r.crossed(at(3 * 3600)));
    try testing.expect(!r.crossed(null));
    try testing.expect(r.crossed(at(7000)));
    try testing.expect(!r.crossed(at(6000)));
    try testing.expect(r.crossed(at(3000)));
    try testing.expect(r.crossed(at(100)));
    try testing.expect(!r.crossed(at(90)));
    try testing.expect(r.crossed(at(30)));
    try testing.expect(!r.crossed(at(0)));
    // Room made: back over 2 h, then the next fall raises again.
    try testing.expect(!r.crossed(at(3 * 3600)));
    try testing.expect(r.crossed(at(7000)));
}

test "time left in English: hours and minutes, minutes, seconds" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("about 8 h 20 min", formatLeft(&buf, 8 * 3600 + 20 * 60 + 10));
    try testing.expectEqualStrings("about 1 h 50 min", formatLeft(&buf, 110 * 60));
    try testing.expectEqualStrings("about 1 h 0 min", formatLeft(&buf, 3600));
    try testing.expectEqualStrings("about 12 min", formatLeft(&buf, 12 * 60));
    try testing.expectEqualStrings("about 40 s", formatLeft(&buf, 40));
    try testing.expectEqualStrings("about 0 s", formatLeft(&buf, -3));
}

test "freeBytes reads the free space of a real folder, and refuses a missing one" {
    try testing.expect(freeBytes("/") != null);
    try testing.expect(freeBytes("/no/such/folder/here") == null);
    try testing.expect(freeBytes("") == null);
    // The nearest folder that exists.
    try testing.expect(freeBytesNear("/no/such/folder/here") != null);
    try testing.expect(freeBytesNear("") == null);
}
