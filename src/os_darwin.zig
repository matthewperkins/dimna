//! The macOS implementation of `os.zig`, through the C library (`std.c`) and, where it has
//! no declaration, Mach and IOKit functions declared here. See `os.zig` for what each
//! function is for; where macOS cannot do what Linux does, the comment here says what is
//! done instead.

const std = @import("std");
const c = std.c;
const Io = std.Io;
const log = std.log.scoped(.os);

pub const E = c.E;
pub const Fd = c.fd_t;
pub const Pid = c.pid_t;

/// `CLOCK_UPTIME_RAW`: the clock `Io.Clock.awake` reads on macOS (it does not advance while
/// the machine sleeps, and shares its epoch with `mach_absolute_time`).
pub fn nowNs() i128 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.UPTIME_RAW, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn sleepNs(ns: u64) void {
    var ts: c.timespec = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
    while (c.errno(c.nanosleep(&ts, &ts)) == .INTR) {}
}

pub fn sleepNsOnce(ns: u64) void {
    const ts: c.timespec = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
    _ = c.nanosleep(&ts, null);
}

// Mach's thread policies (<mach/thread_policy.h>); std.c does not declare them.
const thread_time_constraint_policy = extern struct {
    period: u32,
    computation: u32,
    constraint: u32,
    preemptible: c_int,
};
const THREAD_TIME_CONSTRAINT_POLICY: c_uint = 2;
const THREAD_TIME_CONSTRAINT_POLICY_COUNT: c_uint = @sizeOf(thread_time_constraint_policy) / @sizeOf(c_uint);
const KERN_INVALID_ARGUMENT: c.kern_return_t = 4;
const KERN_NO_ACCESS: c.kern_return_t = 8;
extern "c" fn thread_policy_set(thread: c.mach_port_t, flavor: c_uint, policy: *anyopaque, count: c_uint) c.kern_return_t;
extern "c" fn thread_policy_get(thread: c.mach_port_t, flavor: c_uint, policy: *anyopaque, count: *c_uint, get_default: *c_int) c.kern_return_t;
extern "c" fn pthread_mach_thread_np(thread: c.pthread_t) c.mach_port_t;

/// What the acquisition thread asks of the scheduler, in microseconds. It reads one block
/// every 1 to 2 ms (a USB transfer of 4 to 8 KiB, sometimes two, with the pacing sleep in
/// `oni_usb.readStream` between them) and spends a fraction of a millisecond on it: on the
/// rig the whole headless program used 5.8 s of CPU in 60 s (about 0.1 ms per millisecond,
/// all threads together). So: a period of 1 ms; its work done within that millisecond
/// (constraint 1 ms); up to 0.5 ms of computation in it, several times what a block takes,
/// so that the thread does not overrun what it declared (macOS demotes a real-time thread
/// that keeps doing so); preemptible, since most of a block's time is spent waiting on the
/// USB transfer. On the M4 (macOS 27) the kernel raises any computation below half the
/// constraint to half of it (0.25 ms asked, 0.5 ms reported), and refuses one below 50 µs
/// or above 50 ms (KERN_INVALID_ARGUMENT: 40 µs and 60 ms were refused); hence 0.5 ms here,
/// what the thread would get anyway.
const rt_period_us = 1000;
const rt_computation_us = 500;
const rt_constraint_us = 1000;

fn machUnits(us: u64) u32 {
    var tb: c.mach_timebase_info_data = undefined;
    _ = c.mach_timebase_info(&tb);
    return @intCast(us * 1000 * tb.denom / tb.numer);
}

/// macOS has no `SCHED_FIFO` for an ordinary process. The calling thread gets the
/// user-interactive QoS class (it then stays off the efficiency cores) and a Mach
/// time-constraint policy (`rt_*_us` above). `priority` has no meaning here and is ignored.
/// `.SUCCESS` when the time-constraint policy was set; otherwise `.INVAL` or `.ACCES` (for
/// the Mach error) or the QoS call's error, and the thread keeps what it got.
pub fn setThreadRealtime(priority: i32) E {
    _ = priority;
    const qos = c.pthread_set_qos_class_self_np(.USER_INTERACTIVE, 0);
    if (qos != 0) return @fromBackingInt(@intCast(qos));
    var policy: thread_time_constraint_policy = .{
        .period = machUnits(rt_period_us),
        .computation = machUnits(rt_computation_us),
        .constraint = machUnits(rt_constraint_us),
        .preemptible = 1,
    };
    const kr = thread_policy_set(pthread_mach_thread_np(c.pthread_self()), THREAD_TIME_CONSTRAINT_POLICY, &policy, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    return switch (kr) {
        0 => .SUCCESS,
        KERN_INVALID_ARGUMENT => .INVAL,
        KERN_NO_ACCESS => .ACCES,
        else => .PERM,
    };
}

/// The background QoS class (macOS's lowest: efficiency cores, throttled I/O).
pub fn setThreadIdle() E {
    return @fromBackingInt(@intCast(c.pthread_set_qos_class_self_np(.BACKGROUND, 0)));
}

/// macOS has no `mlockall`; nothing is locked. (`mlock` of a given range exists: what to
/// lock instead, the ring, is for the board's step.)
pub fn lockMemory() bool {
    return false;
}

// struct statfs on 64-bit macOS (<sys/mount.h>, 64-bit inodes); std.c does not declare it.
const Statfs = extern struct {
    bsize: u32,
    iosize: i32,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    owner: c.uid_t,
    type: u32,
    flags: u32,
    fssubtype: u32,
    fstypename: [16]u8,
    mntonname: [1024]u8,
    mntfromname: [1024]u8,
    flags_ext: u32,
    reserved: [7]u32,
};
comptime {
    std.debug.assert(@sizeOf(Statfs) == 2168 and @offsetOf(Statfs, "bavail") == 24);
}
extern "c" fn statfs(path: [*:0]const u8, buf: *Statfs) c_int;

pub fn freeBytes(path: [*:0]const u8) ?u64 {
    var st: Statfs = undefined;
    if (c.errno(statfs(path, &st)) != .SUCCESS) return null;
    return st.bavail * @as(u64, st.bsize);
}

pub fn mapZeroed(size: usize) ?[*]align(std.heap.page_size_min) u8 {
    const p = c.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (p == c.MAP_FAILED) return null;
    return @ptrCast(@alignCast(p));
}

pub fn unmap(ptr: [*]const u8, len: usize) void {
    // Not checked for alignment, as on Linux: the system refuses an unaligned address.
    _ = c.munmap(@ptrFromInt(@intFromPtr(ptr)), len);
}

pub fn swapLink(dir: Fd, target: [*:0]const u8, tmp_name: [*:0]const u8, name: [*:0]const u8) bool {
    _ = c.unlinkat(dir, tmp_name, 0);
    return c.errno(c.symlinkat(target, dir, tmp_name)) == .SUCCESS and
        c.errno(c.renameat(dir, tmp_name, dir, name)) == .SUCCESS;
}

pub fn getpid() Pid {
    return c.getpid();
}

pub fn openRead(path: [*:0]const u8) ?Fd {
    const rc = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (c.errno(rc) != .SUCCESS) return null;
    return rc;
}

pub fn pread(fd: Fd, ptr: [*]u8, len: usize, offset: i64) ?usize {
    const rc = c.pread(fd, ptr, len, offset);
    if (c.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

pub fn openAppend(path: [*:0]const u8, mode: u32) ?Fd {
    const rc = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c_uint, mode));
    if (c.errno(rc) != .SUCCESS) return null;
    return rc;
}

pub fn write(fd: Fd, bytes: []const u8) ?usize {
    const rc = c.write(fd, bytes.ptr, bytes.len);
    if (c.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

pub fn close(fd: Fd) void {
    _ = c.close(fd);
}

pub fn mkdir(path: [*:0]const u8, mode: u32) bool {
    return c.errno(c.mkdir(path, @intCast(mode))) == .SUCCESS;
}

/// `fsync` on macOS hands the data to the drive but does not make the drive write its
/// cache; `F_FULLFSYNC` does. Where the file system or the device refuses `F_FULLFSYNC`
/// (`ENOTSUP`, the same number as `EOPNOTSUPP` here; `ENOTTY`; `ENODEV`, as /dev/null
/// does; `EINVAL`), a plain `fsync` is done instead, which is all such a file can have.
/// Other errors are errors. Unlike `file.sync`, the call is not a cancellation point of
/// `io` (nothing cancels the recorder's thread).
pub fn syncToDisk(io: Io, file: Io.File) Io.File.SyncError!void {
    while (true) {
        switch (c.errno(c.fcntl(file.handle, c.F.FULLFSYNC))) {
            .SUCCESS => return,
            .INTR => continue,
            .OPNOTSUPP, .NOTTY, .NODEV, .INVAL => return file.sync(io),
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .DQUOT => return error.DiskQuota,
            else => |e| return std.posix.unexpectedErrno(e),
        }
    }
}

// IOKit's power assertions (<IOKit/pwr_mgt/IOPMLib.h>) and the CoreFoundation strings they
// take. The frameworks are linked for macOS targets in build.zig.
const CFStringRef = *opaque {};
const kCFStringEncodingUTF8: u32 = 0x08000100;
const kIOPMAssertionLevelOn: u32 = 255;
extern "c" fn CFStringCreateWithCString(alloc: ?*anyopaque, s: [*:0]const u8, encoding: u32) ?CFStringRef;
extern "c" fn CFRelease(cf: *anyopaque) void;
extern "c" fn IOPMAssertionCreateWithName(assertion_type: CFStringRef, level: u32, name: CFStringRef, id: *u32) c_int;
extern "c" fn IOPMAssertionRelease(id: u32) c_int;

/// A power assertion held, or none (id 0, which IOKit never hands out).
pub const Awake = struct {
    id: u32 = 0,
};

/// `PreventUserIdleSystemSleep`: the machine does not sleep for being idle while it is
/// held (a closed lid, a low battery or the user choosing Sleep still put it to sleep).
/// The system drops it by itself when the process ends, also when it is killed.
pub fn keepAwake() Awake {
    const kind = CFStringCreateWithCString(null, "PreventUserIdleSystemSleep", kCFStringEncodingUTF8) orelse return failed();
    defer CFRelease(kind);
    const name = CFStringCreateWithCString(null, "dimna is acquiring", kCFStringEncodingUTF8) orelse return failed();
    defer CFRelease(name);
    var id: u32 = 0;
    if (IOPMAssertionCreateWithName(kind, kIOPMAssertionLevelOn, name, &id) != 0 or id == 0) return failed();
    return .{ .id = id };
}

fn failed() Awake {
    log.warn("could not keep the machine awake (IOPMAssertionCreateWithName failed): it may sleep when idle", .{});
    return .{};
}

pub fn allowSleep(awake: *Awake) void {
    if (awake.id == 0) return;
    _ = IOPMAssertionRelease(awake.id);
    awake.id = 0;
}

const testing = std.testing;

/// What the system reports for the calling thread: its QoS class, and its time-constraint
/// policy (null while it has the default policy).
const ThreadReport = struct {
    qos: c.qos_class_t,
    time_constraint: ?thread_time_constraint_policy,

    fn now() !ThreadReport {
        var qos: c.qos_class_t = undefined;
        var rel: c_int = 0;
        if (c.pthread_get_qos_class_np(c.pthread_self(), &qos, &rel) != 0) return error.QosQueryFailed;
        var policy: thread_time_constraint_policy = undefined;
        var count: c_uint = THREAD_TIME_CONSTRAINT_POLICY_COUNT;
        var get_default: c_int = 0;
        if (thread_policy_get(pthread_mach_thread_np(c.pthread_self()), THREAD_TIME_CONSTRAINT_POLICY, &policy, &count, &get_default) != 0)
            return error.PolicyQueryFailed;
        return .{ .qos = qos, .time_constraint = if (get_default != 0) null else policy };
    }
};

fn onThread(comptime f: fn () anyerror!void) !void {
    var result: anyerror!void = {};
    const t = try std.Thread.spawn(.{}, struct {
        fn run(out: *anyerror!void) void {
            out.* = f();
        }
    }.run, .{&result});
    t.join();
    return result;
}

test "setThreadRealtime: the thread then has the time-constraint policy asked for" {
    try onThread(struct {
        fn f() !void {
            const before = try ThreadReport.now();
            try testing.expect(before.time_constraint == null);
            try testing.expectEqual(E.SUCCESS, setThreadRealtime(70));
            const after = try ThreadReport.now();
            const tc = after.time_constraint orelse return error.NoTimeConstraintPolicy;
            try testing.expectEqual(machUnits(rt_period_us), tc.period);
            try testing.expectEqual(machUnits(rt_computation_us), tc.computation);
            try testing.expectEqual(machUnits(rt_constraint_us), tc.constraint);
            try testing.expectEqual(@as(c_int, 1), tc.preemptible);
            // A real-time thread is outside the QoS classes: macOS reports none for it.
            try testing.expectEqual(c.qos_class_t.UNSPECIFIED, after.qos);
        }
    }.f);
}

test "setThreadIdle: the thread then has the background QoS class" {
    try onThread(struct {
        fn f() !void {
            try testing.expect((try ThreadReport.now()).qos != .BACKGROUND);
            try testing.expectEqual(E.SUCCESS, setThreadIdle());
            const after = try ThreadReport.now();
            try testing.expectEqual(c.qos_class_t.BACKGROUND, after.qos);
            try testing.expect(after.time_constraint == null);
        }
    }.f);
}

test "freeBytes: the figure statfs gives, for a folder that exists; null for one that does not" {
    const free = freeBytes("/") orelse return error.NoFigure;
    try testing.expect(free > 0);
    try testing.expectEqual(@as(?u64, null), freeBytes("/no/such/folder/dimna"));
}

test "syncToDisk: a file whose device refuses F_FULLFSYNC gets fsync instead" {
    // (A regular file takes F_FULLFSYNC: every recorder test syncs through it.)
    const io = testing.io;
    var dev_null = try Io.Dir.openFileAbsolute(io, "/dev/null", .{ .mode = .write_only });
    defer dev_null.close(io);
    // /dev/null refuses F_FULLFSYNC (ENODEV) but takes fsync.
    try testing.expectEqual(E.NODEV, c.errno(c.fcntl(dev_null.handle, c.F.FULLFSYNC)));
    try syncToDisk(io, dev_null);
}
