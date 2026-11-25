//! Thin wrapper over liboni. A context is used by one thread at a time: it is opened by the
//! thread that owns the board and handed with it to the acquisition thread, never shared.

const std = @import("std");
const c = @import("c");
const log = std.log.scoped(.oni);

pub const Device = c.oni_device_t;

pub const Error = error{OniFailed};
pub const OpenError = error{
    /// libonidriver_ft600.so could not be loaded.
    DriverNotFound,
    /// No board answered.
    NoBoard,
    /// The driver refused the board's USB chip: its FT600 is not configured as this driver
    /// needs (FIFO mode "600", optional features off; `oni_usb.zig`, as upstream's driver).
    /// Said upstream to mean gateware older than 2.0.0; that link is not shown by any code here.
    BadController,
};

/// The last failing liboni return code on this thread.
threadlocal var last_rc: c_int = 0;

pub fn lastError() c_int {
    return last_rc;
}
/// After `Context.open` failed with `error.NoBoard`: true if the driver found no board on
/// the bus at all (`ONI_EDEVID`, from both drivers), as against one it could not open.
pub fn lastOpenFoundNoBoard() bool {
    return last_rc == c.ONI_EDEVID;
}
pub fn errorStr(rc: c_int) []const u8 {
    return std.mem.span(c.oni_error_str(rc));
}

fn check(rc: c_int) Error!c_int {
    if (rc < 0) {
        last_rc = rc;
        return error.OniFailed;
    }
    return rc;
}

pub const opt = struct {
    pub const device_table = c.ONI_OPT_DEVICETABLE;
    pub const num_devices = c.ONI_OPT_NUMDEVICES;
    pub const running = c.ONI_OPT_RUNNING;
    pub const reset = c.ONI_OPT_RESET;
    pub const sys_clk_hz = c.ONI_OPT_SYSCLKHZ;
    pub const acq_clk_hz = c.ONI_OPT_ACQCLKHZ;
    pub const reset_acq_counter = c.ONI_OPT_RESETACQCOUNTER;
    pub const block_read_size = c.ONI_OPT_BLOCKREADSIZE;
};

pub fn libraryVersion() [3]c_int {
    var v: [3]c_int = undefined;
    c.oni_version(&v[0], &v[1], &v[2]);
    return v;
}

/// Point liboni's driver loader at `dir` (tried before the default dlopen() search path).
pub fn setDriverSearchDir(dir: [:0]const u8) void {
    c.oni_set_driver_search_dir(dir.ptr);
}

pub const DriverInfo = struct {
    name: []const u8,
    version: [3]c_int,
    pre_release: ?[]const u8,
};

pub const Context = struct {
    ctx: c.oni_ctx,

    pub fn open(driver: [:0]const u8, host_idx: c_int) OpenError!Context {
        const ctx = c.oni_create_ctx(driver.ptr) orelse return error.DriverNotFound;
        const rc = c.oni_init_ctx(ctx, host_idx);
        if (rc != c.ONI_ESUCCESS) {
            last_rc = rc;
            _ = c.oni_destroy_ctx(ctx);
            return if (rc == c.ONI_EBADCONTROLLER) error.BadController else error.NoBoard;
        }
        return .{ .ctx = ctx };
    }

    pub fn deinit(self: *Context) void {
        _ = c.oni_destroy_ctx(self.ctx);
        self.* = undefined;
    }

    pub fn driverInfo(self: *const Context) ?DriverInfo {
        const i: *const c.oni_driver_info_t = c.oni_get_driver_info(self.ctx) orelse return null;
        return .{
            .name = if (i.name) |n| std.mem.span(n) else "",
            .version = .{ i.major, i.minor, i.patch },
            .pre_release = if (i.pre_release) |p| std.mem.span(p) else null,
        };
    }

    pub fn readReg(self: *const Context, dev: u32, addr: u32) Error!u32 {
        var v: u32 = 0;
        _ = try check(c.oni_read_reg(self.ctx, dev, addr, &v));
        return v;
    }
    pub fn writeReg(self: *const Context, dev: u32, addr: u32, val: u32) Error!void {
        _ = try check(c.oni_write_reg(self.ctx, dev, addr, val));
    }
    pub fn writeRegMask(self: *const Context, dev: u32, addr: u32, val: u32, mask: u32) Error!void {
        const cur = try self.readReg(dev, addr);
        try self.writeReg(dev, addr, (cur & ~mask) | (val & mask));
    }

    pub fn getOptU32(self: *const Context, option: c_int) Error!u32 {
        var v: u32 = 0;
        var sz: usize = @sizeOf(u32);
        _ = try check(c.oni_get_opt(self.ctx, option, &v, &sz));
        return v;
    }
    pub fn setOptU32(self: *const Context, option: c_int, v: u32) Error!void {
        _ = try check(c.oni_set_opt(self.ctx, option, &v, @sizeOf(u32)));
    }
    pub fn getDriverOptU32(self: *const Context, option: c_int) Error!u32 {
        var v: u32 = 0;
        var sz: usize = @sizeOf(u32);
        _ = try check(c.oni_get_driver_opt(self.ctx, option, &v, &sz));
        return v;
    }

    /// Fills `buf` with the device table; returns the filled part.
    pub fn deviceTable(self: *const Context, buf: []Device) Error![]Device {
        const n = @min(try self.getOptU32(opt.num_devices), buf.len);
        var sz: usize = n * @sizeOf(Device);
        _ = try check(c.oni_get_opt(self.ctx, opt.device_table, buf.ptr, &sz));
        return buf[0..n];
    }

    /// Blocking read of the next frame of the data stream.
    pub fn readFrame(self: *const Context) Error!Frame {
        var f: [*c]c.oni_frame_t = null;
        _ = try check(c.oni_read_frame(self.ctx, &f));
        return .{ .f = f orelse return error.OniFailed };
    }

    pub fn writeFrame(self: *const Context, dev: u32, data: []u8) Error!void {
        var f: [*c]c.oni_frame_t = null;
        const rc = c.oni_create_frame(self.ctx, &f, dev, data.ptr, data.len);
        if (rc <= 0) {
            last_rc = if (rc < 0) rc else -1;
            return error.OniFailed;
        }
        defer c.oni_destroy_frame(f);
        _ = try check(c.oni_write_frame(self.ctx, f));
    }
};

/// A frame is a view into liboni's shared read buffer; `deinit` releases it.
pub const Frame = struct {
    f: *c.oni_frame_t,

    pub fn time(self: Frame) u64 {
        return self.f.time;
    }
    pub fn devIdx(self: Frame) u32 {
        return self.f.dev_idx;
    }
    pub fn data(self: Frame) []const u8 {
        const p: [*]const u8 = @ptrCast(self.f.data);
        return p[0..self.f.data_sz];
    }
    pub fn deinit(self: Frame) void {
        c.oni_destroy_frame(self.f);
    }
};

/// Finds the first directory holding libonidriver_ft600.so: `$ONI_DRIVER_PATH` (colon
/// separated), next to the executable, `../lib` from it, `~/.local/lib`, `/usr/local/lib`.
/// Points liboni at it and returns it (in `buf`), or null to use the default search path.
pub fn configureDriverSearch(io: std.Io, env: *const std.process.Environ.Map, buf: *[std.fs.max_path_bytes:0]u8) ?[:0]const u8 {
    const lib = "libonidriver_ft600.so";
    var cands: [16][]const u8 = undefined;
    var n: usize = 0;
    var store: [4][std.fs.max_path_bytes]u8 = undefined;
    if (env.get("ONI_DRIVER_PATH")) |p| {
        var it = std.mem.tokenizeScalar(u8, p, ':');
        while (it.next()) |d| {
            if (n < 8) {
                cands[n] = d;
                n += 1;
            }
        }
    }
    if (std.process.executableDirPath(io, &store[0])) |len| {
        cands[n] = store[0][0..len];
        n += 1;
        if (std.fmt.bufPrint(&store[1], "{s}/../lib", .{store[0][0..len]})) |s| {
            cands[n] = s;
            n += 1;
        } else |_| {}
    } else |_| {}
    if (env.get("HOME")) |h| {
        if (std.fmt.bufPrint(&store[2], "{s}/.local/lib", .{h})) |s| {
            cands[n] = s;
            n += 1;
        } else |_| {}
    }
    cands[n] = "/usr/local/lib";
    n += 1;
    for (cands[0..n]) |d| {
        const path = std.fmt.bufPrint(&store[3], "{s}/{s}", .{ d, lib }) catch continue;
        std.Io.Dir.accessAbsolute(io, path, .{}) catch continue;
        const dir = std.fmt.bufPrintSentinel(buf, "{s}", .{d}, 0) catch continue;
        setDriverSearchDir(dir);
        return dir;
    }
    return null;
}
