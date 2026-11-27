//! The operating system's calls that have no portable form in `std` (or none without an
//! `Io`): the monotonic clock, sleeps, thread priority, memory locking, free disk space,
//! zeroed pages, swapping a link, the process id, files by descriptor, syncing a file to
//! the disk, and keeping the machine awake.
//!
//! One implementation per system, chosen at compile time; there is no indirect call. The
//! rest of the program calls these and never the system itself: in Zig 0.17.1 most raw
//! Linux calls also compile for macOS and then do the wrong thing there, so a raw call
//! left elsewhere would not be caught by the compiler. The test at the end of this file
//! catches it instead.
//!
//! Each function does exactly what its call site did before it was moved here; callers
//! keep their own logic and log lines. They are small enough that the optimizer inlines
//! them (in the release build no function of this module or of `os_linux.zig` is left), so
//! a caller makes the system call itself, as before; that matters on the hot paths (the
//! clock, the pacing sleep, positional reads in review, unmapping in the overview store).

const std = @import("std");
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .linux => @import("os_linux.zig"),
    .macos => @import("os_darwin.zig"),
    .windows => @import("os_windows.zig"),
    else => @compileError("dimna has no os layer for this system yet"),
};

/// An error number (`.SUCCESS` when there was none), as the system reports it.
pub const E = impl.E;
/// A file descriptor.
pub const Fd = impl.Fd;
pub const Pid = impl.Pid;
/// A folder's handle, as `std.Io.Dir` holds it (a descriptor, except on Windows).
pub const DirHandle = if (builtin.os.tag == .windows) impl.DirHandle else Fd;

/// Nanoseconds on the monotonic clock `Io.Clock.awake` reads (`CLOCK_MONOTONIC` on Linux,
/// `CLOCK_UPTIME_RAW` on macOS). Needs no `Io`.
pub fn nowNs() i128 {
    return impl.nowNs();
}

/// Sleeps `ns` nanoseconds; a signal does not cut it short (the sleep is resumed for the
/// time left).
pub fn sleepNs(ns: u64) void {
    impl.sleepNs(ns);
}

/// Sleeps up to `ns` nanoseconds, once: a signal ends it early.
pub fn sleepNsOnce(ns: u64) void {
    impl.sleepNsOnce(ns);
}

/// Real-time scheduling (`SCHED_FIFO` at `priority`) for the calling thread. On macOS a
/// Mach time-constraint policy instead, and `priority` is ignored (`os_darwin.zig`).
pub fn setThreadRealtime(priority: i32) E {
    return impl.setThreadRealtime(priority);
}

/// The highest `SCHED_FIFO` priority the process's limit lets an unprivileged thread ask
/// for: the soft `RLIMIT_RTPRIO` (`ulimit -r`), at most 99; 0 when it allows none. Null when
/// there is no such limit or it cannot be read: on macOS, where `setThreadRealtime` ignores
/// the number.
pub fn realtimeLimit() ?i32 {
    return impl.realtimeLimit();
}

/// Idle scheduling (`SCHED_IDLE`) for the calling thread: only what nothing else wants. On
/// macOS the background QoS class.
pub fn setThreadIdle() E {
    return impl.setThreadIdle();
}

/// Locks the process's current and future pages in RAM. False if refused (always on
/// macOS and Windows, which have no such call).
pub fn lockMemory() bool {
    return impl.lockMemory();
}

/// Free bytes (for an unprivileged user) on the filesystem holding `path`, or null.
pub fn freeBytes(path: [*:0]const u8) ?u64 {
    return impl.freeBytes(path);
}

/// `size` bytes (a whole number of pages) of fresh anonymous memory, zeroed by the system
/// on first touch, or null.
pub fn mapZeroed(size: usize) ?[*]align(std.heap.page_size_min) u8 {
    return impl.mapZeroed(size);
}

/// Gives back `len` bytes from `ptr` of memory from `mapZeroed`: any whole pages of it, not
/// only all of it. `ptr` must be at a page boundary (not checked here, as before the move).
pub fn unmap(ptr: [*]const u8, len: usize) void {
    impl.unmap(ptr, len);
}

/// Makes `name` in the folder `dir` a symbolic link to `target`, replacing what was there
/// in one step: the link is made as `tmp_name` (removed first) and renamed over `name`.
/// False if it could not be made. On Windows a junction, set in place (`os_windows.zig`).
pub fn swapLink(dir: DirHandle, target: [*:0]const u8, tmp_name: [*:0]const u8, name: [*:0]const u8) bool {
    return impl.swapLink(dir, target, tmp_name, name);
}

/// The process id.
pub fn getpid() Pid {
    return impl.getpid();
}

/// Opens `path` for reading (closed on exec), or null.
pub fn openRead(path: [*:0]const u8) ?Fd {
    return impl.openRead(path);
}

/// Reads up to `len` bytes into `ptr` from `offset` in the file, without moving its
/// position. The number read (0 at the end of the file), or null on an error.
pub fn pread(fd: Fd, ptr: [*]u8, len: usize, offset: i64) ?usize {
    return impl.pread(fd, ptr, len, offset);
}

/// Opens `path` for appending (created with `mode` if missing, closed on exec), or null.
pub fn openAppend(path: [*:0]const u8, mode: u32) ?Fd {
    return impl.openAppend(path, mode);
}

/// One write of `bytes`: the number written, or null on an error.
pub fn write(fd: Fd, bytes: []const u8) ?usize {
    return impl.write(fd, bytes);
}

pub fn close(fd: Fd) void {
    impl.close(fd);
}

/// Makes the folder `path` (not its parents). False if it was not made (also when it is
/// there already).
pub fn mkdir(path: [*:0]const u8, mode: u32) bool {
    return impl.mkdir(path, mode);
}

/// Makes what was written to `file` durable: on the disk itself, not in a cache. On Linux
/// that is `file.sync(io)` (`fsync`). On macOS `fsync` does not make the drive write its
/// own cache, so it is `fcntl(F_FULLFSYNC)`, with `fsync` where that is refused.
pub fn syncToDisk(io: Io, file: Io.File) Io.File.SyncError!void {
    // Linux's is here rather than in os_linux.zig: it is the `std.Io` call, not a raw one.
    if (builtin.os.tag != .macos) return file.sync(io);
    return impl.syncToDisk(io, file);
}

/// A hold on the machine staying awake, from `keepAwake`; empty (zero bytes) on Linux.
pub const Awake = if (builtin.os.tag == .linux) struct {} else impl.Awake;

/// Keeps the machine from sleeping when idle, until `allowSleep`: macOS and Windows sleep
/// an idle machine, which would stop acquisition. Not a closed lid (the machine sleeps then
/// anyway). On Linux nothing: the program has never needed it there, and the two calls
/// compile to nothing. Logs if it could not.
pub fn keepAwake() Awake {
    if (builtin.os.tag == .linux) return .{};
    return impl.keepAwake();
}

/// Gives up what `keepAwake` got (nothing if it got nothing or was given up already).
pub fn allowSleep(awake: *Awake) void {
    if (builtin.os.tag == .linux) return;
    impl.allowSleep(awake);
}

/// Windows only (elsewhere the callers install signal handlers themselves): calls `handler`,
/// on a thread of the system's, on Ctrl-C, Ctrl-Break, the console being closed, a logoff or
/// a shutdown.
pub const onInterrupt = if (builtin.os.tag == .windows) impl.onInterrupt else {};

/// The folder for temporary files, without a trailing separator, for the tests: `/tmp`, on
/// Windows `%TEMP%`. `buf` must hold it.
pub fn tempDir(buf: []u8) []const u8 {
    if (builtin.os.tag == .windows) return impl.tempDir(buf);
    return "/tmp";
}

const testing = std.testing;
const Io = std.Io;

test "no file under src/ calls the system directly, except the Linux backends" {
    // The files that may: the Linux backends of this module, of USB and of the window.
    const exceptions = [_][]const u8{ "os_linux.zig", "usb_linux.zig", "gui/window_wayland.zig" };
    // And `record_test.zig`, once, inside its write-failure test (`fork`, `dup2`, `wait4`,
    // `kill`: what replaces them elsewhere is another step's question).
    const fork_file = "record_test.zig";
    const fork_test = "test \"recorder: a write failure does not hold the producer";
    // The spellings looked for, split so that this file does not contain them (comments
    // count too): `linux` under `os` (however `std` and its `os` are reached), std's `os`
    // given a name of its own, and posix's `system` (which is `linux` on Linux).
    const linux_ns = "os" ++ ".linux";
    const std_os = "std" ++ ".os";
    const posix_system = "posix" ++ ".system";

    const gpa = testing.allocator;
    const io = testing.io;
    // The tests run in the folder `zig build` was started in: the repository's root or one
    // below it. The sources are the `src` there or in the nearest folder above that has one
    // holding this file's Linux backend.
    var up_buf: [3 * 16 + 3]u8 = undefined;
    var src = for (0..16) |depth| {
        const p = up_buf[0 .. 3 * depth + 3];
        for (0..depth) |k| @memcpy(p[3 * k ..][0..3], "../");
        @memcpy(p[3 * depth ..], "src");
        var d = Io.Dir.cwd().openDir(io, p, .{ .iterate = true }) catch continue;
        if (d.access(io, "os_linux.zig", .{})) |_| break d else |_| d.close(io);
    } else {
        std.debug.print("no src/ holding os_linux.zig in the current folder or above it\n", .{});
        return error.TestUnexpectedResult;
    };
    defer src.close(io);
    var walker = try src.walk(gpa);
    defer walker.deinit();
    var files: usize = 0;
    var seen_backend = false;
    var seen_gui = false;
    var bad: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        files += 1;
        if (std.mem.eql(u8, entry.path, "os_linux.zig")) seen_backend = true;
        if (std.mem.eql(u8, entry.path, "gui/notes.zig")) seen_gui = true;
        const excepted = for (exceptions) |x| {
            if (std.mem.eql(u8, entry.path, x)) break true;
        } else false;
        if (excepted) continue;
        const text = try src.readFileAlloc(io, entry.path, gpa, .limited(16 << 20));
        defer gpa.free(text);
        var allowed: ?[2]usize = null;
        if (std.mem.eql(u8, entry.path, fork_file)) {
            const start = std.mem.indexOf(u8, text, fork_test) orelse {
                std.debug.print("src/{s}: its write-failure test is not there\n", .{fork_file});
                return error.TestUnexpectedResult;
            };
            allowed = .{ start, std.mem.indexOfPos(u8, text, start, "\n}\n") orelse text.len };
        }
        var uses_in_fork_test: usize = 0;
        var line_no: usize = 1;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var at: usize = 0;
        while (lines.next()) |line| : ({
            at += line.len + 1;
            line_no += 1;
        }) {
            var hit = std.mem.indexOf(u8, line, linux_ns) != null or
                std.mem.indexOf(u8, line, posix_system) != null;
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, line, pos, std_os)) |i| : (pos = i + std_os.len) {
                const after = i + std_os.len;
                // Not followed by a `.`: std's `os` given a name of its own.
                if (after >= line.len or line[after] != '.') hit = true;
            }
            if (!hit) continue;
            if (allowed) |r| {
                if (at >= r[0] and at < r[1]) {
                    uses_in_fork_test += 1;
                    continue;
                }
            }
            std.debug.print("src/{s}:{d}: calls the system directly (use os.zig): {s}\n", .{ entry.path, line_no, std.mem.trim(u8, line, " ") });
            bad += 1;
        }
        if (allowed != null and uses_in_fork_test != 1) {
            std.debug.print("src/{s}: {d} direct uses in its write-failure test, expected 1\n", .{ fork_file, uses_in_fork_test });
            bad += 1;
        }
    }
    // The walk saw the whole tree, not an empty or wrong folder.
    try testing.expect(seen_backend and seen_gui and files > 40);
    try testing.expectEqual(0, bad);
}
