//! The Linux implementation of `os.zig`: the raw calls the rest of the program used to make
//! itself, moved here unchanged (same calls, flags, modes and retry loops). See `os.zig`
//! for what each function is for.

const std = @import("std");
const linux = std.os.linux;

pub const E = linux.E;
pub const Fd = linux.fd_t;
pub const Pid = linux.pid_t;

pub fn nowNs() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn sleepNs(ns: u64) void {
    var ts: linux.timespec = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
    while (linux.errno(linux.nanosleep(&ts, &ts)) == .INTR) {}
}

pub fn sleepNsOnce(ns: u64) void {
    const ts: linux.timespec = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
    _ = linux.nanosleep(&ts, null);
}

pub fn setThreadRealtime(priority: i32) E {
    return linux.errno(linux.sched_setscheduler(0, .{ .mode = .FIFO }, &.{ .priority = priority }));
}

pub fn realtimeLimit() ?i32 {
    var lim: linux.rlimit = undefined;
    if (linux.errno(linux.getrlimit(.RTPRIO, &lim)) != .SUCCESS) return null;
    return @intCast(@min(lim.cur, 99));
}

pub fn setThreadIdle() E {
    return linux.errno(linux.sched_setscheduler(0, .{ .mode = .IDLE }, &.{ .priority = 0 }));
}

pub fn lockMemory() bool {
    const rc = linux.mlockall(.{ .CURRENT = true, .FUTURE = true });
    return linux.errno(rc) == .SUCCESS;
}

pub fn freeBytes(path: [*:0]const u8) ?u64 {
    // struct statfs on 64-bit Linux.
    const Statfs = extern struct {
        type: i64,
        bsize: i64,
        blocks: u64,
        bfree: u64,
        bavail: u64,
        files: u64,
        ffree: u64,
        fsid: [2]i32,
        namelen: i64,
        frsize: i64,
        flags: i64,
        spare: [4]i64,
    };
    var st: Statfs = undefined;
    const rc = linux.syscall2(.statfs, @intFromPtr(path), @intFromPtr(&st));
    if (linux.errno(rc) != .SUCCESS) return null;
    return st.bavail * @as(u64, @intCast(st.bsize));
}

pub fn mapZeroed(size: usize) ?[*]align(std.heap.page_size_min) u8 {
    const rc = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(rc);
    return ptr;
}

pub fn unmap(ptr: [*]const u8, len: usize) void {
    _ = linux.munmap(ptr, len);
}

pub fn swapLink(dir: Fd, target: [*:0]const u8, tmp_name: [*:0]const u8, name: [*:0]const u8) bool {
    _ = linux.unlinkat(dir, tmp_name, 0);
    return linux.errno(linux.symlinkat(target, dir, tmp_name)) == .SUCCESS and
        linux.errno(linux.renameat(dir, tmp_name, dir, name)) == .SUCCESS;
}

pub fn getpid() Pid {
    return linux.getpid();
}

pub fn openRead(path: [*:0]const u8) ?Fd {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

pub fn pread(fd: Fd, ptr: [*]u8, len: usize, offset: i64) ?usize {
    const rc = linux.pread(fd, ptr, len, offset);
    if (linux.errno(rc) != .SUCCESS) return null;
    return rc;
}

pub fn openAppend(path: [*:0]const u8, mode: u32) ?Fd {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, mode);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

pub fn write(fd: Fd, bytes: []const u8) ?usize {
    const rc = linux.write(fd, bytes.ptr, bytes.len);
    if (linux.errno(rc) != .SUCCESS) return null;
    return rc;
}

pub fn close(fd: Fd) void {
    _ = linux.close(fd);
}

pub fn mkdir(path: [*:0]const u8, mode: u32) bool {
    return linux.errno(linux.mkdir(path, mode)) == .SUCCESS;
}
