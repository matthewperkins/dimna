//! The macOS backend of `gpu.zig`, for now a stand-in: Metal is the next step of the port.
//! It has the fields and functions the callers use, so that the GUI compiles and its tests
//! run on the Mac (they build a `Gpu` as `undefined` and set `hist_cap`), but `init` fails
//! and nothing else does anything. Metal is not linked.

const std = @import("std");
const font = @import("font.zig");
const decimate = @import("dimna").decimate;
const gpu = @import("gpu.zig");
const log = std.log.scoped(.gpu);

/// What a window hands the GPU (`Window.gpuTarget`).
pub const Target = struct {
    /// The window's CAMetalLayer.
    layer: *anyopaque,
    /// Where `Gpu.draw` puts the frame's drawable (an id<CAMetalDrawable>, not
    /// retained for the window) before it calls `before_present`, and null again
    /// after presenting. The window's `beforePresent(tag)` reads it to attach its
    /// report of when the frame reached the screen.
    drawable: *?*anyopaque,
};

pub const Gpu = struct {
    gpa: std.mem.Allocator,
    hist: []i16 = &.{},
    hist_cap: usize = 0,
    nch: usize = 0,
    dec: decimate.Ring = .{},
    rev: []i16 = &.{},
    rev_cap: usize = 0,
    rev_cols: []u32 = &.{},
    row_gains: []f32 = &.{},
    wait_render: bool = false,
    last_render_ns: u64 = 0,

    /// Fails: the GPU is not ported to macOS yet.
    pub fn init(gpa: std.mem.Allocator, target: Target, mode: gpu.PresentMode, share: ?*const Gpu) !Gpu {
        _ = .{ gpa, target, mode, share };
        log.err("the GPU is not ported to macOS yet (Metal is the next step of the port)", .{});
        return error.GpuNotPorted;
    }

    pub fn deinit(self: *Gpu) void {
        self.* = undefined;
    }

    pub fn resize(self: *Gpu, width: u32, height: u32) !void {
        _ = .{ self, width, height };
        return error.GpuNotPorted;
    }

    pub fn unsized(self: *const Gpu) bool {
        _ = self;
        return true;
    }

    pub fn pixelSize(self: *const Gpu) gpu.Size {
        _ = self;
        return .{ .width = 0, .height = 0 };
    }

    pub fn draw(
        self: *Gpu,
        panels: []const gpu.PanelDraw,
        fills: []const gpu.Fill,
        text: []const font.Vertex,
        context: anytype,
        comptime before_present: fn (@TypeOf(context)) void,
    ) !gpu.DrawResult {
        _ = .{ self, panels, fills, text, before_present };
        return error.GpuNotPorted;
    }

    pub fn createText(self: *Gpu, atlas: []const u8, size: u32, max_vertices: usize) !void {
        _ = .{ self, atlas, size, max_vertices };
        return error.GpuNotPorted;
    }

    pub fn textFont(self: *Gpu, f: *const font.Font) void {
        _ = .{ self, f };
    }

    pub fn createHistory(self: *Gpu, nch: usize, want_samples: usize, least_samples: usize, bucket_samples: usize) !void {
        _ = .{ self, nch, want_samples, least_samples, bucket_samples };
        return error.GpuNotPorted;
    }

    pub fn createReview(self: *Gpu) !void {
        _ = self;
        return error.GpuNotPorted;
    }

    pub fn destroyReview(self: *Gpu) void {
        _ = self;
    }

    pub fn writeSamples(self: *Gpu, first: i64, samples: []const i16) void {
        _ = .{ self, first, samples };
    }
};
