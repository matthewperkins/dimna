//! The operating system's calls that have no portable form in `std` (or none without an
//! `Io`): the monotonic clock, sleeps, thread priority, memory locking, free disk space,
//! zeroed pages, swapping a link, the process id, and files by descriptor.
//!
//! One implementation per system, chosen at compile time; there is no indirect call. The
//! rest of the program calls these and never the system itself: in Zig 0.17.1 most raw
//! Linux calls also compile for macOS and then do the wrong thing there, so a raw call
//! left elsewhere would not be caught by the compiler. The test at the end of this file
//! catches it instead.
//!
//! Each function does exactly what its call site did before it was moved here; callers
//! keep their own logic and log lines. The hot ones (clock, sleep, positional read,
//! unmapping) are `inline`, so a caller makes the system call itself, as before.

const std = @import("std");
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .linux => @import("os_linux.zig"),
    else => @compileError("dimna has no os layer for this system yet"),
};

/// An error number (`.SUCCESS` when there was none), as the system reports it.
pub const E = impl.E;
/// A file descriptor.
pub const Fd = impl.Fd;
pub const Pid = impl.Pid;

/// Nanoseconds on the monotonic clock `Io.Clock.awake` reads (`CLOCK_MONOTONIC` on Linux).
/// Needs no `Io`.
pub inline fn nowNs() i128 {
    return impl.nowNs();
}

/// Sleeps `ns` nanoseconds; a signal does not cut it short (the sleep is resumed for the
/// time left).
pub inline fn sleepNs(ns: u64) void {
    impl.sleepNs(ns);
}

/// Sleeps up to `ns` nanoseconds, once: a signal ends it early.
pub inline fn sleepNsOnce(ns: u64) void {
    impl.sleepNsOnce(ns);
}

/// Real-time scheduling (`SCHED_FIFO` at `priority`) for the calling thread.
pub fn setThreadRealtime(priority: i32) E {
    return impl.setThreadRealtime(priority);
}

/// Idle scheduling (`SCHED_IDLE`) for the calling thread: only what nothing else wants.
pub fn setThreadIdle() E {
    return impl.setThreadIdle();
}

/// Locks the process's current and future pages in RAM. False if refused.
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

/// Gives back `len` bytes (whole pages) from `ptr` of memory from `mapZeroed`; any whole
/// pages of it, not only all of it.
pub inline fn unmap(ptr: [*]align(std.heap.page_size_min) const u8, len: usize) void {
    impl.unmap(ptr, len);
}

/// Makes `name` in the folder `dir` a symbolic link to `target`, replacing what was there
/// in one step: the link is made as `tmp_name` (removed first) and renamed over `name`.
/// False if it could not be made.
pub fn swapLink(dir: Fd, target: [*:0]const u8, tmp_name: [*:0]const u8, name: [*:0]const u8) bool {
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
pub inline fn pread(fd: Fd, ptr: [*]u8, len: usize, offset: i64) ?usize {
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
