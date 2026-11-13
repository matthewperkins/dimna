//! What can change this program's behaviour from outside, besides the command line and the
//! config file: every environment variable the GUI reads. They are read once, at start-up,
//! into an `Env` that is handed to the parts that use them.
//!
//!   OEZ_APP_ID            the windows' class ("oez", "oez-control", "oez-tiles" by default).
//!                         Test runs give their own, so compositor rules for the real
//!                         windows do not apply to them.
//!   OEZ_KEY_DEBUG         log every key event (window.zig).
//!   OEZ_FRAME_DEBUG       1: explain frames that land late, and time the GPU per frame;
//!                         2: also one line per frame (pacing.zig).
//!   OEZ_NO_TITLE          do not put the latency in the window's title.
//!   OEZ_CONTROL_CLICKS    scripted clicks in the control window, "SECONDS:X,Y;..." (control.zig).
//!   OEZ_TILE_CLICKS       scripted input in the tile window, "SECONDS:X,Y[,ACTION];..." (tiles.zig).
//!   OEZ_TEST_RING_SECONDS the acquisition ring's length in seconds instead of 30, for
//!                         testing what happens when it fills.
//!   OEZ_TEST_RECORD_FAIL_AFTER   make the recorder fail after this many samples.
//!   OEZ_TEST_RECORD_STALL        "SAMPLES,MS": make it stall once, for testing the alarms.
//!   HOME, XDG_STATE_HOME  where "~/" in record_dir points, and where notes.log goes
//!                         ($XDG_STATE_HOME/oez, default ~/.local/state/oez).
//!
//! Read elsewhere, because they belong to something else: XDG_CONFIG_HOME and HOME for the
//! config file's place (main.zig, from the process's environment map); OEZ_USB_TRACE and
//! OEZ_USB_PACE in the board driver (src/ft600.zig, src/oni_usb.zig), which the headless
//! tool uses too; WAYLAND_DISPLAY and the rest that the libraries read themselves.
//! OEZ_CONTROL_LAYOUT_OUT is read only by a test.

const std = @import("std");

pub const Env = struct {
    app_id: []const u8 = "oez",
    key_debug: bool = false,
    /// 0: off; 1: late frames and GPU times; 2: also one line per frame.
    frame_debug: u8 = 0,
    no_title: bool = false,
    control_clicks: []const u8 = "",
    tile_clicks: []const u8 = "",
    ring_seconds: f64 = 30,
    record_test: RecordTest = .{},
    home: []const u8 = ".",
    /// "" when not set.
    state_home: []const u8 = "",

    /// Faults to make in the recorder, for testing the alarms.
    pub const RecordTest = struct {
        fail_after: ?u64 = null,
        stall_after: ?u64 = null,
        stall_ms: u32 = 0,
    };

    /// Reads the environment. A value that does not parse leaves its default.
    pub fn read() Env {
        var e: Env = .{};
        if (get("OEZ_APP_ID")) |v| e.app_id = v;
        e.key_debug = get("OEZ_KEY_DEBUG") != null;
        if (get("OEZ_FRAME_DEBUG")) |v| e.frame_debug = if (v.len > 0 and v[0] == '2') 2 else 1;
        e.no_title = get("OEZ_NO_TITLE") != null;
        if (get("OEZ_CONTROL_CLICKS")) |v| e.control_clicks = v;
        if (get("OEZ_TILE_CLICKS")) |v| e.tile_clicks = v;
        if (get("OEZ_TEST_RING_SECONDS")) |v| e.ring_seconds = std.fmt.parseFloat(f64, v) catch 30.0;
        if (get("OEZ_TEST_RECORD_FAIL_AFTER")) |v| e.record_test.fail_after = std.fmt.parseInt(u64, v, 10) catch null;
        if (get("OEZ_TEST_RECORD_STALL")) |v| {
            var it = std.mem.tokenizeScalar(u8, v, ',');
            e.record_test.stall_after = std.fmt.parseInt(u64, it.next() orelse "", 10) catch null;
            e.record_test.stall_ms = std.fmt.parseInt(u32, it.next() orelse "", 10) catch 0;
        }
        if (get("HOME")) |v| e.home = v;
        if (get("XDG_STATE_HOME")) |v| e.state_home = v;
        return e;
    }

    fn get(name: [*:0]const u8) ?[]const u8 {
        return if (std.c.getenv(name)) |v| std.mem.span(v) else null;
    }
};
