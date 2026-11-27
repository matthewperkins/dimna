//! The Windows implementation of `os.zig`, through kernel32 (declared here: `std` declares
//! few of these). See `os.zig` for what each function is for; where Windows cannot do what
//! Linux does, the comment here says what is done instead.
//!
//! Written and compiled on Linux for `x86_64-windows`; **not yet run on Windows**
//! (docs/plans/windows-port.md). What is assumed and not seen is marked "to check".
//!
//! Paths are UTF-8 here and UTF-16 for the system; one longer than `max_path` UTF-16 units
//! fails as a path that does not exist would.

const std = @import("std");
const log = std.log.scoped(.os);

/// The outcome of a scheduling request. Windows reports a `GetLastError` number, not an
/// errno; the callers only compare with `.SUCCESS` and print the name.
pub const E = enum { SUCCESS, PERM };
/// A file: the system's `HANDLE` as an integer, so that `-1` is "none" and a valid one is
/// `>= 0`, as the callers expect of a descriptor.
pub const Fd = isize;
pub const Pid = u32;
/// A folder as `std.Io.Dir` holds it.
pub const DirHandle = HANDLE;

const HANDLE = *anyopaque;
const BOOL = c_int;
const DWORD = u32;
const max_path = 1024;
const invalid_handle: isize = -1;

extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceFrequency(frequency: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
extern "kernel32" fn CreateWaitableTimerExW(attributes: ?*anyopaque, name: ?[*:0]const u16, flags: DWORD, access: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetWaitableTimer(timer: HANDLE, due: *const i64, period: i32, routine: ?*anyopaque, arg: ?*anyopaque, resume_system: BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetCurrentThread() callconv(.winapi) HANDLE;
extern "kernel32" fn SetThreadPriority(thread: HANDLE, priority: c_int) callconv(.winapi) BOOL;
extern "kernel32" fn GetDiskFreeSpaceExW(dir: [*:0]const u16, free_to_caller: ?*u64, total: ?*u64, free: ?*u64) callconv(.winapi) BOOL;
extern "kernel32" fn VirtualAlloc(addr: ?*anyopaque, size: usize, kind: DWORD, protect: DWORD) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualFree(addr: *anyopaque, size: usize, kind: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn VirtualQuery(addr: *const anyopaque, info: *MemoryInfo, len: usize) callconv(.winapi) usize;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, security: ?*anyopaque, disposition: DWORD, flags: DWORD, template: ?HANDLE) callconv(.winapi) isize;
extern "kernel32" fn ReadFile(file: HANDLE, buf: [*]u8, len: DWORD, read: ?*DWORD, overlapped: ?*Overlapped) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(file: HANDLE, buf: [*]const u8, len: DWORD, written: ?*DWORD, overlapped: ?*Overlapped) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CreateDirectoryW(name: [*:0]const u16, security: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn SetThreadExecutionState(flags: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (DWORD) callconv(.winapi) BOOL, add: BOOL) callconv(.winapi) BOOL;

const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: DWORD,
    offset_high: DWORD,
    event: ?HANDLE = null,
};

const MemoryInfo = extern struct {
    base: ?*anyopaque,
    allocation_base: ?*anyopaque,
    allocation_protect: DWORD,
    partition: u16,
    region_size: usize,
    state: DWORD,
    protect: DWORD,
    kind: DWORD,
};

fn wide(buf: *[max_path:0]u16, path: []const u8) ?[*:0]const u16 {
    if (path.len >= max_path) return null;
    const n = std.unicode.utf8ToUtf16Le(buf, path) catch return null;
    buf[n] = 0;
    return buf[0..n :0];
}

fn handleOf(fd: Fd) HANDLE {
    return @ptrFromInt(@as(usize, @bitCast(fd)));
}

/// The performance counter, in nanoseconds: the clock `Io.Clock.awake` reads on Windows (to
/// check). It does not advance while the machine sleeps.
pub fn nowNs() i128 {
    const S = struct {
        var per_s: i64 = 0;
    };
    // Racing threads write the same value.
    if (S.per_s == 0) _ = QueryPerformanceFrequency(&S.per_s);
    var count: i64 = 0;
    _ = QueryPerformanceCounter(&count);
    return @divFloor(@as(i128, count) * std.time.ns_per_s, S.per_s);
}

/// A timer of this thread's own, made on first use and kept: a high-resolution one
/// (Windows 10 1803 and later; about 0.5 ms at best, where an ordinary sleep is 1 to 15 ms),
/// or null where that is refused.
threadlocal var sleep_timer: ?HANDLE = null;
threadlocal var sleep_timer_tried = false;

fn sleepOnce(ns: u64) void {
    if (!sleep_timer_tried) {
        sleep_timer_tried = true;
        const high_resolution = 0x2;
        const timer_all_access = 0x1F0003;
        sleep_timer = CreateWaitableTimerExW(null, null, high_resolution, timer_all_access);
    }
    if (sleep_timer) |timer| {
        // Negative: relative, in units of 100 ns.
        const due: i64 = -@as(i64, @intCast(@max(ns / 100, 1)));
        if (SetWaitableTimer(timer, &due, 0, null, null, 0) != 0) {
            _ = WaitForSingleObject(timer, 0xFFFF_FFFF);
            return;
        }
    }
    Sleep(@intCast(@max(ns / std.time.ns_per_ms, 1)));
}

/// Windows has no signals to cut a sleep short, so the two sleeps are one.
pub fn sleepNs(ns: u64) void {
    sleepOnce(ns);
}

pub fn sleepNsOnce(ns: u64) void {
    sleepOnce(ns);
}

/// Not `SCHED_FIFO`, which Windows does not have: the highest priority of the process's
/// class (`THREAD_PRIORITY_TIME_CRITICAL`). The system may still run its own work first.
/// `priority` is ignored.
pub fn setThreadRealtime(priority: i32) E {
    _ = priority;
    const time_critical = 15;
    return if (SetThreadPriority(GetCurrentThread(), time_critical) != 0) .SUCCESS else .PERM;
}

/// Null: there is no limit to read, and `setThreadRealtime` ignores the number.
pub fn realtimeLimit() ?i32 {
    return null;
}

/// `THREAD_PRIORITY_IDLE`: the lowest priority of the process's class.
pub fn setThreadIdle() E {
    const idle = -15;
    return if (SetThreadPriority(GetCurrentThread(), idle) != 0) .SUCCESS else .PERM;
}

/// Always false: Windows has no call that locks a process's present and future pages
/// (`VirtualLock` locks named regions only; not done yet).
pub fn lockMemory() bool {
    return false;
}

/// The bytes free to this user on the disk holding the folder `path`.
pub fn freeBytes(path: [*:0]const u8) ?u64 {
    var buf: [max_path:0]u16 = undefined;
    const w = wide(&buf, std.mem.span(path)) orelse return null;
    var free: u64 = 0;
    if (GetDiskFreeSpaceExW(w, &free, null, null) == 0) return null;
    return free;
}

const mem_commit = 0x1000;
const mem_reserve = 0x2000;
const mem_decommit = 0x4000;
const mem_release = 0x8000;

pub fn mapZeroed(size: usize) ?[*]align(std.heap.page_size_min) u8 {
    const page_readwrite = 0x04;
    const p = VirtualAlloc(null, size, mem_commit | mem_reserve, page_readwrite) orelse return null;
    return @ptrCast(@alignCast(p));
}

/// A whole mapping is released. Part of one is decommitted: its memory goes back to the
/// system, but its addresses stay reserved until the process ends (Windows releases only a
/// whole mapping; 64-bit address space is not short).
pub fn unmap(ptr: [*]const u8, len: usize) void {
    const addr: *anyopaque = @ptrCast(@constCast(ptr));
    var info: MemoryInfo = undefined;
    if (VirtualQuery(addr, &info, @sizeOf(MemoryInfo)) != 0 and info.allocation_base == @as(?*anyopaque, addr)) {
        // The whole mapping if no page of it lies beyond `len`.
        var beyond: MemoryInfo = undefined;
        const end: *const anyopaque = @ptrCast(ptr + len);
        if (VirtualQuery(end, &beyond, @sizeOf(MemoryInfo)) == 0 or beyond.allocation_base != info.allocation_base) {
            _ = VirtualFree(addr, 0, mem_release);
            return;
        }
    }
    _ = VirtualFree(addr, len, mem_decommit);
}

/// Always false, for now: a symbolic link needs administrator rights or Developer Mode on
/// Windows, and what stands in for the `current` link there is not decided
/// (docs/plans/windows-port.md, the questions for the owner).
pub fn swapLink(dir: DirHandle, target: [*:0]const u8, tmp_name: [*:0]const u8, name: [*:0]const u8) bool {
    _ = .{ dir, target, tmp_name, name };
    return false;
}

pub fn getpid() Pid {
    return GetCurrentProcessId();
}

const generic_read = 0x8000_0000;
const file_append_data = 0x0004;
// Others may read, write, rename and delete the file while it is open here, as on Linux.
const share_all = 0x1 | 0x2 | 0x4;
const open_existing = 3;
const open_always = 4;
const attribute_normal = 0x80;

pub fn openRead(path: [*:0]const u8) ?Fd {
    var buf: [max_path:0]u16 = undefined;
    const w = wide(&buf, std.mem.span(path)) orelse return null;
    const h = CreateFileW(w, generic_read, share_all, null, open_existing, attribute_normal, null);
    return if (h == invalid_handle) null else h;
}

pub fn pread(fd: Fd, ptr: [*]u8, len: usize, offset: i64) ?usize {
    const at: u64 = @intCast(offset);
    var ov: Overlapped = .{ .offset = @truncate(at), .offset_high = @truncate(at >> 32) };
    var got: DWORD = 0;
    if (ReadFile(handleOf(fd), ptr, @intCast(@min(len, 0x7FFF_F000)), &got, &ov) == 0) {
        const handle_eof = 38;
        return if (GetLastError() == handle_eof) 0 else null;
    }
    return got;
}

/// `mode` is ignored: a new file takes its folder's permissions.
pub fn openAppend(path: [*:0]const u8, mode: u32) ?Fd {
    _ = mode;
    var buf: [max_path:0]u16 = undefined;
    const w = wide(&buf, std.mem.span(path)) orelse return null;
    // With append access only, every write goes to the end of the file.
    const h = CreateFileW(w, file_append_data, share_all, null, open_always, attribute_normal, null);
    return if (h == invalid_handle) null else h;
}

pub fn write(fd: Fd, bytes: []const u8) ?usize {
    var done: DWORD = 0;
    if (WriteFile(handleOf(fd), bytes.ptr, @intCast(@min(bytes.len, 0x7FFF_F000)), &done, null) == 0) return null;
    return done;
}

pub fn close(fd: Fd) void {
    _ = CloseHandle(handleOf(fd));
}

/// `mode` is ignored, as in `openAppend`.
pub fn mkdir(path: [*:0]const u8, mode: u32) bool {
    _ = mode;
    var buf: [max_path:0]u16 = undefined;
    const w = wide(&buf, std.mem.span(path)) orelse return false;
    return CreateDirectoryW(w, null) != 0;
}

/// Whether the machine is being kept awake by this process.
pub const Awake = struct { held: bool = false };

const es_continuous = 0x8000_0000;
const es_system_required = 0x0000_0001;

/// Keeps the machine from sleeping when idle (`SetThreadExecutionState`). The request
/// belongs to the calling thread and lasts while that thread lives, so `allowSleep` must
/// be called on the same thread (to check against where the callers call the two).
pub fn keepAwake() Awake {
    if (SetThreadExecutionState(es_continuous | es_system_required) == 0) {
        log.warn("could not ask Windows to stay awake; an idle machine may sleep and stop acquisition", .{});
        return .{};
    }
    return .{ .held = true };
}

pub fn allowSleep(awake: *Awake) void {
    if (!awake.held) return;
    _ = SetThreadExecutionState(es_continuous);
    awake.held = false;
}

var interrupt_handler: ?*const fn () void = null;

fn onConsoleCtrl(kind: DWORD) callconv(.winapi) BOOL {
    _ = kind;
    if (interrupt_handler) |h| h();
    // Handled: the process is not ended here. For a closed console, a logoff or a shutdown
    // Windows ends it anyway about 5 s after this returns, so it must not return before the
    // main thread has had time to close the recording.
    Sleep(4000);
    return 1;
}

/// Calls `handler` (on a thread of the system's) on Ctrl-C, Ctrl-Break, the console being
/// closed, a logoff or a shutdown: what stands in for SIGINT, SIGTERM and SIGHUP.
pub fn onInterrupt(handler: *const fn () void) void {
    interrupt_handler = handler;
    _ = SetConsoleCtrlHandler(&onConsoleCtrl, 1);
}

/// The folder for temporary files, without a trailing separator: `%TEMP%`, else the
/// current folder.
pub fn tempDir(buf: []u8) []const u8 {
    const w = std.c.getenv("TEMP") orelse return ".";
    const s = std.mem.span(w);
    if (s.len == 0 or s.len > buf.len) return ".";
    @memcpy(buf[0..s.len], s);
    return std.mem.trimEnd(u8, buf[0..s.len], "\\/");
}
