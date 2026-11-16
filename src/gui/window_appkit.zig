//! The macOS backend of `window.zig`, for now a stand-in: AppKit is the next step of the
//! port. It has what the callers use, so that the GUI compiles and its tests run on the
//! Mac, but `init` fails: no window is made, nothing connects to the window server, and
//! `dimna` ends with status 1 and the message below. AppKit is not linked.

const std = @import("std");
const window = @import("window.zig");
const Cursor = window.Cursor;
const Input = window.Input;
const Presented = window.Presented;
const Target = @import("gpu.zig").Target;
const log = std.log.scoped(.window);

/// The stand-in has no AppKit loop to run: `body` runs on the calling thread, as on Linux.
pub inline fn run(comptime body: anytype, args: anytype) @TypeOf(@call(.auto, body, args)) {
    return @call(.auto, body, args);
}

pub const Window = struct {
    width: u32 = 1280,
    height: u32 = 800,
    resized: bool = true,
    closed: bool = false,
    frame_ready: bool = true,
    presentation_clock: i64 = -1,
    input: Input = .{},

    /// Fails: windows are not ported to macOS yet.
    pub fn init(self: *Window, title: [:0]const u8, app_id: [:0]const u8, key_debug: bool) !void {
        _ = .{ title, app_id, key_debug };
        self.* = .{};
        log.err("windows are not ported to macOS yet (AppKit is the next step of the port); nothing was opened", .{});
        return error.WindowNotPorted;
    }

    pub fn deinit(self: *Window) void {
        self.* = undefined;
    }

    pub fn fullscreenOn(self: *Window, monitor: []const u8) bool {
        _ = .{ self, monitor };
        return false;
    }

    pub fn declareLowLatency(self: *Window) bool {
        _ = self;
        return false;
    }

    pub fn preferTearing(self: *Window) bool {
        _ = self;
        return false;
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        _ = .{ self, title };
    }

    pub fn gpuTarget(self: *const Window) Target {
        _ = self;
        return .{};
    }

    pub fn monitorName(self: *const Window, i: usize) ?[]const u8 {
        _ = .{ self, i };
        return null;
    }

    pub fn presentsOnNowClock(self: *const Window) bool {
        _ = self;
        return false;
    }

    pub fn pump(self: *Window, timeout_ms: i32) !void {
        _ = .{ self, timeout_ms };
    }

    pub fn takeInput(self: *Window) Input {
        const in = self.input;
        self.input.scroll_x = 0;
        self.input.scroll_y = 0;
        self.input.pinch = 1;
        self.input.num_keys = 0;
        self.input.clicks = 0;
        self.input.right_clicks = 0;
        self.input.middle_clicks = 0;
        self.input.text_len = 0;
        return in;
    }

    pub fn takePresented(self: *Window) []const Presented {
        _ = self;
        return &.{};
    }

    pub fn beforePresent(self: *Window, tag: u64) void {
        _ = tag;
        self.frame_ready = false;
    }

    pub fn setCursor(self: *Window, cursor: Cursor) void {
        _ = .{ self, cursor };
    }
};
