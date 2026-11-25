//! What can change this program's behaviour from outside, besides the command line and the
//! config file: every environment variable the GUI reads. They are read once, at start-up,
//! into an `Env` that is handed to the parts that use them.
//!
//!   DIMNA_APP_ID            the windows' class ("dimna", "dimna-control", "dimna-tiles" by default).
//!                           Test runs give their own, so compositor rules for the real
//!                           windows do not apply to them.
//!   DIMNA_KEY_DEBUG         log every key event (window.zig).
//!   DIMNA_FRAME_DEBUG       1: explain frames that land late, and time the GPU per frame;
//!                           2: also one line per frame (pacing.zig).
//!   DIMNA_NO_TITLE          do not put the latency in the window's title.
//!   DIMNA_CONTROL_CLICKS    scripted clicks in the control window, "SECONDS:X,Y;..." (control.zig).
//!   DIMNA_TILE_CLICKS       scripted input in the tile window, "SECONDS:X,Y[,ACTION];..." (tiles.zig): clicks, wheel, keys, drags.
//!   DIMNA_TEST_RING_SECONDS the acquisition ring's length in seconds instead of 30, for
//!                           testing what happens when it fills.
//!   DIMNA_TEST_RECORD_AT    start a recording this many seconds after launch, for test runs
//!                           without a control window (use with --no-control).
//!   DIMNA_TEST_RECORD_FAIL_AFTER   make the recorder fail after this many samples.
//!   DIMNA_TEST_RECORD_STALL        "SAMPLES,MS": make it stall once, for testing the alarms.
//!   HOME, XDG_STATE_HOME    where "~/" in record_dir points, and where notes.log goes
//!                           ($XDG_STATE_HOME/dimna, default ~/.local/state/dimna).
//!
//! Read elsewhere, because they belong to something else: XDG_CONFIG_HOME and HOME for the
//! config file's place (main.zig, from the process's environment map); DIMNA_USB_TRACE and
//! DIMNA_USB_PACE in the board driver (src/ft600.zig, src/oni_usb.zig), which the headless
//! tool uses too; WAYLAND_DISPLAY and the rest that the libraries read themselves.
//! DIMNA_CONTROL_LAYOUT_OUT, DIMNA_DISPLAY_FRAME_OUT and DIMNA_TILES_DRAW_OUT are read only by
//! tests (each writes that test's present output to the path, for regenerating its stored file).

const std = @import("std");

pub const Env = struct {
    app_id: []const u8 = "dimna",
    key_debug: bool = false,
    /// 0: off; 1: late frames and GPU times; 2: also one line per frame.
    frame_debug: u8 = 0,
    no_title: bool = false,
    control_clicks: []const u8 = "",
    tile_clicks: []const u8 = "",
    ring_seconds: f64 = 30,
    record_at: ?f64 = null,
    /// The simulator stalls (`DIMNA_TEST_SIM_STALL=<at s>,<for s>`) or fails with a read
    /// error (`DIMNA_TEST_SIM_FAIL_AT=<s>[,<times>]`: that many seconds into a run, for
    /// the first `times` runs, 1 by default), for testing the alarms and the reopen.
    sim_stall_at: ?f64 = null,
    sim_stall_s: f64 = 0,
    sim_fail_at: ?f64 = null,
    sim_fail_times: u32 = 1,
    /// Free space on the recording's disk that counts as none, in GB (testing the disk alarm).
    disk_reserve_gb: ?f64 = null,
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
        if (get("DIMNA_APP_ID")) |v| e.app_id = v;
        e.key_debug = get("DIMNA_KEY_DEBUG") != null;
        if (get("DIMNA_FRAME_DEBUG")) |v| e.frame_debug = if (v.len > 0 and v[0] == '2') 2 else 1;
        e.no_title = get("DIMNA_NO_TITLE") != null;
        if (get("DIMNA_CONTROL_CLICKS")) |v| e.control_clicks = v;
        if (get("DIMNA_TILE_CLICKS")) |v| e.tile_clicks = v;
        if (get("DIMNA_TEST_RING_SECONDS")) |v| e.ring_seconds = std.fmt.parseFloat(f64, v) catch 30.0;
        if (get("DIMNA_TEST_RECORD_AT")) |v| e.record_at = std.fmt.parseFloat(f64, v) catch null;
        if (get("DIMNA_TEST_SIM_STALL")) |v| {
            var it = std.mem.splitScalar(u8, v, ',');
            e.sim_stall_at = std.fmt.parseFloat(f64, it.first()) catch null;
            e.sim_stall_s = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
        }
        if (get("DIMNA_TEST_SIM_FAIL_AT")) |v| {
            var it = std.mem.splitScalar(u8, v, ',');
            e.sim_fail_at = std.fmt.parseFloat(f64, it.first()) catch null;
            e.sim_fail_times = std.fmt.parseInt(u32, it.next() orelse "1", 10) catch 1;
        }
        if (get("DIMNA_TEST_DISK_RESERVE_GB")) |v| e.disk_reserve_gb = std.fmt.parseFloat(f64, v) catch null;
        if (get("DIMNA_TEST_RECORD_FAIL_AFTER")) |v| e.record_test.fail_after = std.fmt.parseInt(u64, v, 10) catch null;
        if (get("DIMNA_TEST_RECORD_STALL")) |v| {
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
