//! One AppKit window (an NSWindow whose content is a view backed by a CAMetalLayer): the
//! macOS backend of `window.zig`, which declares the types used here and says what a
//! backend must keep. AppKit itself is called by `appkit_shim.m` (Objective-C), through
//! the C interface in `appkit_shim.h`; nothing here calls the Objective-C runtime.
//!
//! Threads. AppKit owns the process's main thread: `run` starts the display's work on a
//! new thread and runs the application's loop on the main thread until that work ends.
//! `init` and `deinit`, from whichever thread owns the window, have the main thread make
//! and destroy it and wait for that. The main thread receives the window's events and
//! merges each into the window's `Mailbox` (below) without waiting for anything; `pump`,
//! on the window's thread, takes what has been merged, waiting up to its timeout (woken by
//! the first event that arrives). Without `run`: on the main thread itself `init` makes
//! the window on the spot and `pump` runs AppKit's events for up to its timeout; on another
//! thread `init` fails (`error.NoAppKitLoop`, nothing made) rather than wait for a loop
//! that is not there.
//!
//! What the callers get, against Wayland's:
//!
//! - `width`, `height`, `pointer_x`, `pointer_y` in pixels of the layer's drawable (the
//!   view's points times the window's backing scale), origin top left, y down. The layer's
//!   `contentsScale` follows the window's screen; the drawable's size is the GPU's
//!   (`Gpu.resize`).
//! - Keys: one `Key` per press, repeats dropped. The key is the character the key types in
//!   the current layout with no modifier (`charactersByApplyingModifiers:0`: 'p' on the key
//!   at QWERTY's R in Dvorak); Escape, Return, Delete (backspace), Tab, Home, End, Page
//!   Up/Down and the arrows by their key codes. `text` is what the press typed
//!   (`NSEvent.characters`), less control characters and the private-use characters AppKit
//!   gives function keys. There is no input method client: a dead key types nothing
//!   itself, and the composed character comes (or not) as AppKit's key translation gives
//!   it with the next press; input methods (Chinese, Japanese) and press-and-hold accents
//!   are not offered to the user. Linux has no compose support either.
//! - A press with Command held is not a key for dimna (no `Key`, no text): Command
//!   combinations are the system's and the menu's (Cmd-Q closes the windows, as their
//!   close buttons do). `alt` is Option, `ctrl` Control.
//! - Scroll: `-scrollingDelta` times 15 per line from a wheel (a click is a line), times 1
//!   per point from a trackpad or Magic Mouse (`hasPreciseScrollingDeltas`); positive is
//!   down and right. The user's "natural scrolling" setting applies, as libinput's does on
//!   Linux (the compositor passes on what libinput reports, after its own inversion).
//!   Momentum (the glide after the fingers lift) is dropped: libinput has none.
//! - Pinch: the trackpad's magnify gesture, the product of `1 + magnification` since the
//!   last take.
//! - `frame_ready`: set by the window's display link (a `CADisplayLink` of the view, on the
//!   main thread, at the refresh of the screen the window is on) at the first refresh after
//!   a `beforePresent`, as Wayland's frame callback does. So the control window and the
//!   tiles, which draw only when it is set, draw at most once a refresh; the display, which
//!   free-runs on the Mac (`--free`), does not look at it.
//! - Presentation: `beforePresent(tag)` adds a presented handler to the frame's drawable
//!   (`Target.drawable`); the handler, on a thread of the system's, records the tag, the
//!   drawable's `presentedTime` and the refresh period of the window's screen. A drawable
//!   that was never shown (time 0) is counted in `discarded` and not reported, as Wayland's
//!   `discarded` feedback is not. The times are `CACurrentMediaTime`'s, which is
//!   `mach_absolute_time` and so `CLOCK_UPTIME_RAW`, the clock `clock.nowNs` reads: checked
//!   at `init` (`presentsOnNowClock`), not assumed.
//! - `fullscreenOn(name)`: the screen by the name macOS shows (`NSScreen.localizedName`,
//!   e.g. "Built-in Retina Display"; case ignored). The window becomes borderless, covers
//!   the screen and sits above the menu bar, with the menu bar and the Dock hidden while
//!   dimna is the active application: the mode the latency probe found quickest (no Space
//!   of its own, no animation). Other windows of dimna on that screen are under it.
//! - `declareLowLatency`: false (macOS has nothing to declare). `preferTearing`: true,
//!   nothing to ask: a layer with sync off (the GPU's choice) shows frames mid-scan.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("appkit_c");
const dimna = @import("dimna");
const log = std.log.scoped(.window);

// What every backend and its callers agree on, declared once in window.zig.
const window = @import("window.zig");
const Key = window.Key;
const Cursor = window.Cursor;
const Input = window.Input;
const Presented = window.Presented;
const Target = @import("gpu.zig").Target;

// ---- waiting on an address (os/os_sync_wait_on_address.h, macOS 14.4) ----

extern "c" fn os_sync_wait_on_address(addr: *anyopaque, value: u64, size: usize, flags: u32) c_int;
extern "c" fn os_sync_wait_on_address_with_timeout(addr: *anyopaque, value: u64, size: usize, flags: u32, clockid: u32, timeout_ns: u64) c_int;
extern "c" fn os_sync_wake_by_address_any(addr: *anyopaque, size: usize, flags: u32) c_int;
const OS_CLOCK_MACH_ABSOLUTE_TIME: u32 = 32;

// ---- the loop ----

/// `window.run` on macOS: `body` on a new thread, AppKit's loop on this one (the main
/// thread) until `body` returns; then `body`'s result. Called elsewhere than on the main
/// thread, it calls `body` on the calling thread, with no loop (its windows then fail).
pub fn run(comptime body: anytype, args: anytype) @TypeOf(@call(.auto, body, args)) {
    const R = @TypeOf(@call(.auto, body, args));
    if (c.dimna_aw_is_main_thread() == 0) {
        log.warn("window.run called off the main thread: no AppKit loop, windows cannot be made", .{});
        return @call(.auto, body, args);
    }
    const Ctx = struct {
        args: @TypeOf(args),
        result: R = undefined,
        fn start(ctx: *@This()) void {
            ctx.result = @call(.auto, body, ctx.args);
            c.dimna_aw_loop_stop();
        }
    };
    var ctx: Ctx = .{ .args = args };
    c.dimna_aw_loop_begin();
    const thread = std.Thread.spawn(.{}, Ctx.start, .{&ctx}) catch |e| {
        log.warn("no thread for the display ({t}); running it without AppKit's loop", .{e});
        c.dimna_aw_loop_stop();
        c.dimna_aw_loop_run(); // returns at once: the stop just asked for ends it
        return @call(.auto, body, args);
    };
    c.dimna_aw_loop_run();
    thread.join();
    return ctx.result;
}

// ---- what the main thread hands the window's thread ----

/// What is not an event but a state: as of the newest event.
pub const State = struct {
    left_down: bool = false,
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_inside: bool = false,
};

/// The events merged since the window's thread last took them.
pub const Pending = struct {
    /// Events merged (for `pump`: anything arrived?).
    events: u32 = 0,
    scroll_x: f64 = 0,
    scroll_y: f64 = 0,
    pinch: f64 = 1,
    keys: [16]Key = undefined,
    num_keys: usize = 0,
    clicks: u32 = 0,
    right_clicks: u32 = 0,
    middle_clicks: u32 = 0,
    text: [64]u8 = undefined,
    text_len: usize = 0,
    /// `state` is the state as of the newest event (set by every input event).
    has_state: bool = false,
    state: State = .{},
    /// The view's newest size, pixels.
    size: ?[2]u32 = null,
    closed: bool = false,
    frame: bool = false,
    /// The newest event's time stamp (s, `CACurrentMediaTime`'s clock), 0 if none had one.
    time: f64 = 0,
};

/// The key of a press: `code` is the virtual key code, `unmod` the character it types in
/// the current layout with no modifier (0: AppKit gave none).
pub fn keyOf(code: u32, unmod: u32) ?Key {
    const named: ?Key.Named = switch (code) {
        53 => .escape,
        36 => .enter,
        51 => .backspace,
        48 => .tab,
        115 => .home,
        119 => .end,
        116 => .page_up,
        121 => .page_down,
        123 => .left,
        126 => .up,
        124 => .right,
        125 => .down,
        else => null,
    };
    if (named) |n| return .{ .named = n };
    if (unmod >= 0x20 and unmod <= 0x7e) return .{ .char = @intCast(unmod) };
    if (unmod != 0) return null;
    // No character from AppKit: the key as on a US keyboard, as Linux does without a keymap.
    const us = "asdfhgzxcv\x00bqweryt123465=97-80]ou[ip\x00lj'k;\\,/nm.\x00 `";
    return if (code < us.len and us[code] != 0) .{ .char = us[code] } else null;
}

/// Scroll in the contract's units (a wheel click about 15, positive down or right) from
/// AppKit's `scrollingDelta` (lines from a wheel, points from a trackpad; positive up or
/// left).
pub fn scrollUnits(delta: f64, precise: bool) f64 {
    return -delta * (if (precise) @as(f64, 1) else 15);
}

/// A position in the view (points, origin bottom left) in pixels from the top left.
pub fn toPixels(x_pt: f64, y_pt: f64, height_pt: f64, scale: f64) [2]f64 {
    return .{ x_pt * scale, (height_pt - y_pt) * scale };
}

/// A size in points in pixels.
pub fn sizePixels(pt: f64, scale: f64) u32 {
    return @intFromFloat(@max(0, @round(pt * scale)));
}

/// Whether a code point belongs in `text`: not a control character, not one of the
/// private-use characters AppKit gives function keys (U+F700 to U+F8FF).
fn typable(cp: u21) bool {
    return cp >= 0x20 and cp != 0x7f and !(cp >= 0x80 and cp < 0xa0) and !(cp >= 0xf700 and cp <= 0xf8ff);
}

/// Merges one event into `p`; `s` is the producer's own state, kept across takes.
pub fn merge(p: *Pending, s: *State, ev: *const c.DimnaAwEvent) void {
    p.events += 1;
    if (ev.time > 0) p.time = ev.time;
    const input_event = switch (ev.kind) {
        c.DIMNA_AW_SIZE, c.DIMNA_AW_CLOSE, c.DIMNA_AW_FRAME => false,
        else => true,
    };
    if (input_event) {
        s.shift = ev.mods & c.DIMNA_AW_SHIFT != 0;
        s.ctrl = ev.mods & c.DIMNA_AW_CTRL != 0;
        s.alt = ev.mods & c.DIMNA_AW_ALT != 0;
    }
    switch (ev.kind) {
        c.DIMNA_AW_KEY_DOWN => if (ev.flags & c.DIMNA_AW_REPEAT == 0 and ev.mods & c.DIMNA_AW_CMD == 0) {
            if (keyOf(ev.code, ev.unmod)) |key| if (p.num_keys < p.keys.len) {
                p.keys[p.num_keys] = key;
                p.num_keys += 1;
            };
            // The press's text, if all of it fits (as on Linux), without what is not typed.
            var buf: [32]u8 = undefined;
            var n: usize = 0;
            const len = @min(ev.text_len, ev.text.len);
            const typed: []const u8 = @ptrCast(ev.text[0..len]);
            if (std.unicode.Utf8View.init(typed)) |view| {
                var it = view.iterator();
                while (it.nextCodepointSlice()) |slice| {
                    const cp = std.unicode.utf8Decode(slice) catch continue;
                    if (!typable(cp)) continue;
                    @memcpy(buf[n..][0..slice.len], slice);
                    n += slice.len;
                }
            } else |_| {}
            if (n > 0 and p.text_len + n <= p.text.len) {
                @memcpy(p.text[p.text_len..][0..n], buf[0..n]);
                p.text_len += n;
            }
        },
        c.DIMNA_AW_BUTTON_DOWN => switch (ev.code) {
            0 => {
                p.clicks += 1;
                s.left_down = true;
            },
            1 => p.right_clicks += 1,
            2 => p.middle_clicks += 1,
            else => {},
        },
        c.DIMNA_AW_BUTTON_UP => if (ev.code == 0) {
            s.left_down = false;
        },
        c.DIMNA_AW_MOTION, c.DIMNA_AW_ENTER => {
            const px = toPixels(ev.x, ev.y, ev.height_pt, ev.scale);
            s.pointer_x = px[0];
            s.pointer_y = px[1];
            if (ev.kind == c.DIMNA_AW_ENTER) s.pointer_inside = true;
        },
        c.DIMNA_AW_LEAVE => {
            s.pointer_inside = false;
            s.left_down = false;
        },
        c.DIMNA_AW_SCROLL => if (ev.flags & c.DIMNA_AW_MOMENTUM == 0) {
            const precise = ev.flags & c.DIMNA_AW_PRECISE != 0;
            p.scroll_x += scrollUnits(ev.x, precise);
            p.scroll_y += scrollUnits(ev.y, precise);
        },
        c.DIMNA_AW_MAGNIFY => if (1 + ev.x > 0) {
            p.pinch *= 1 + ev.x;
        },
        c.DIMNA_AW_SIZE => p.size = .{ sizePixels(ev.x, ev.scale), sizePixels(ev.y, ev.scale) },
        c.DIMNA_AW_CLOSE => p.closed = true,
        c.DIMNA_AW_FRAME => p.frame = true,
        else => {},
    }
    if (input_event) {
        p.has_state = true;
        p.state = s.*;
    }
}

/// The hand-over from the main thread (the one producer of events) to the window's thread
/// (the one consumer), without a lock and without allocating: two `Pending`, one written
/// by the producer while the consumer takes the other. The producer never waits for the
/// consumer; the consumer may wait (spin) for the producer to finish the one event it is
/// merging. Events are merged, not queued, as Wayland's are between two `takeInput`:
/// motion keeps the newest position, scroll and pinch add up, presses are counted, keys
/// (16) and text (64 bytes) are kept to what `Input` holds and the rest dropped.
pub const Mailbox = struct {
    pending: [2]Pending = .{ .{}, .{} },
    busy: [2]std.atomic.Value(u32) = .{ .init(0), .init(0) },
    /// Which of `pending` the producer writes.
    write: std.atomic.Value(u32) = .init(0),
    /// Counts what was handed over (events, presentation reports); the consumer waits on it.
    seq: std.atomic.Value(u32) = .init(0),
    /// 1 while the consumer waits (or is about to).
    waiting: std.atomic.Value(u32) = .init(0),
    /// The producer's own.
    state: State = .{},

    /// On the producer's thread: merges `ev` and wakes the consumer.
    pub fn post(self: *Mailbox, ev: *const c.DimnaAwEvent) void {
        var i: u32 = undefined;
        while (true) {
            i = self.write.load(.seq_cst);
            self.busy[i].store(1, .seq_cst);
            if (self.write.load(.seq_cst) == i) break;
            // The consumer took this one meanwhile: write the other.
            self.busy[i].store(0, .release);
        }
        merge(&self.pending[i], &self.state, ev);
        self.busy[i].store(0, .release);
        self.signal();
    }

    /// Any thread: something was handed over; wakes the consumer if it waits.
    pub fn signal(self: *Mailbox) void {
        _ = self.seq.fetchAdd(1, .seq_cst);
        if (self.waiting.swap(0, .seq_cst) != 0) _ = os_sync_wake_by_address_any(&self.seq.raw, 4, 0);
    }

    /// On the consumer's thread: what was merged since the last take.
    pub fn take(self: *Mailbox) Pending {
        const i = self.write.load(.seq_cst);
        self.write.store(1 - i, .seq_cst);
        while (self.busy[i].load(.seq_cst) != 0) std.atomic.spinLoopHint();
        const p = self.pending[i];
        self.pending[i] = .{};
        return p;
    }

    /// On the consumer's thread: waits until `seq` is no longer `seen`, at most
    /// `timeout_ms` (negative: no limit).
    pub fn wait(self: *Mailbox, seen: u32, timeout_ms: i32) void {
        if (timeout_ms == 0) return;
        self.waiting.store(1, .seq_cst);
        if (self.seq.load(.seq_cst) == seen) {
            if (timeout_ms < 0)
                _ = os_sync_wait_on_address(&self.seq.raw, seen, 4, 0)
            else
                _ = os_sync_wait_on_address_with_timeout(&self.seq.raw, seen, 4, 0, OS_CLOCK_MACH_ABSOLUTE_TIME, @as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms);
        }
        self.waiting.store(0, .seq_cst);
    }
};

/// Presentation reports, from the system's threads to the window's: a few at a time, so a
/// spin lock held for a copy.
const Reports = struct {
    lock: std.atomic.Value(u32) = .init(0),
    buf: [64]Presented = undefined,
    n: usize = 0,
    discarded: u64 = 0,

    fn acquire(self: *Reports) void {
        while (self.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn release(self: *Reports) void {
        self.lock.store(0, .release);
    }
};

pub const Window = struct {
    /// Size in pixels of the layer's drawable to be (the view's points times its scale).
    width: u32 = 1280,
    height: u32 = 800,
    /// Set when the size changed; the renderer clears it after resizing.
    resized: bool = true,
    closed: bool = false,
    /// The display link has seen a refresh since the last `beforePresent`.
    frame_ready: bool = true,
    /// `CLOCK_UPTIME_RAW` (8): the clock presentation times are on.
    presentation_clock: i64 = -1,
    input: Input = .{},
    /// DIMNA_KEY_DEBUG=1 logs every key.
    key_debug: bool = false,

    handle: ?*c.DimnaAwWindow = null,
    layer: ?*anyopaque = null,
    /// `Target.drawable`: the GPU's frame's drawable while it presents.
    drawable: ?*anyopaque = null,
    cursor: Cursor = .default,
    on_now_clock: bool = false,
    screen_names: [c.DIMNA_AW_MAX_SCREENS][c.DIMNA_AW_NAME_LEN]u8 = undefined,
    screen_lens: [c.DIMNA_AW_MAX_SCREENS]usize = undefined,
    num_screens: usize = 0,

    mailbox: Mailbox = .{},
    reports: Reports = .{},
    presented: [64]Presented = undefined,
    num_presented: usize = 0,
    /// Frames whose drawable was never shown.
    discarded: u64 = 0,
    /// The time stamp of the newest event taken (s, `CACurrentMediaTime`'s clock).
    last_event_time: f64 = 0,

    /// Has the main thread make the window and waits for it. `self` must stay at a fixed
    /// address. `app_id` has no use on macOS (no window rules to match).
    pub fn init(self: *Window, title: [:0]const u8, app_id: [:0]const u8, key_debug: bool) !void {
        _ = app_id;
        self.* = .{ .key_debug = key_debug };
        var info: c.DimnaAwInfo = undefined;
        var handle: ?*c.DimnaAwWindow = null;
        switch (c.dimna_aw_create(title.ptr, self, .{ .event = onEvent, .presented = onPresented }, &info, &handle)) {
            c.DIMNA_AW_OK => {},
            c.DIMNA_AW_NO_LOOP => {
                log.err("a window was asked for on a thread other than the main one, with no AppKit loop running (window.run); nothing was opened", .{});
                return error.NoAppKitLoop;
            },
            else => return error.WindowFailed,
        }
        self.handle = handle;
        self.layer = c.dimna_aw_layer(handle);
        // The Dock's and the application switcher's picture (a plain executable has none).
        const icon = @embedFile("dimna-icon.png");
        c.dimna_aw_set_icon(icon.ptr, icon.len);
        self.width = info.width_px;
        self.height = info.height_px;
        self.num_screens = info.num_screens;
        for (0..self.num_screens) |i| {
            const name: []const u8 = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&info.screen_names[i])), 0);
            @memcpy(self.screen_names[i][0..name.len], name);
            self.screen_lens[i] = name.len;
        }
        self.presentation_clock = @backingInt(std.c.CLOCK.UPTIME_RAW);
        self.on_now_clock = mediaTimeIsNow();
        if (!self.on_now_clock) log.warn("CACurrentMediaTime is not on the clock nowNs reads: latency figures will be off", .{});
    }

    /// Has the main thread destroy the window and waits for it. No callback reaches `self`
    /// after this.
    pub fn deinit(self: *Window) void {
        if (self.handle) |h| c.dimna_aw_destroy(h);
        self.* = undefined;
    }

    /// Makes the window fullscreen on the screen of that name (as macOS shows it, case
    /// ignored). False if there is no such screen.
    pub fn fullscreenOn(self: *Window, monitor: []const u8) bool {
        var buf: [256:0]u8 = undefined;
        if (monitor.len >= buf.len) return false;
        @memcpy(buf[0..monitor.len], monitor);
        buf[monitor.len] = 0;
        return c.dimna_aw_fullscreen(self.handle, &buf) != 0;
    }

    /// The part of the top edge the screen does not show under this fullscreen window (the
    /// camera housing of a Mac laptop): left edge, right edge and depth in pixels. Null
    /// when the window is not fullscreen or its screen has none.
    pub fn topCut(self: *const Window) ?[3]f32 {
        var cut: [3]f64 = undefined;
        if (c.dimna_aw_top_cut(self.handle, &cut) == 0) return null;
        return .{ @floatCast(cut[0]), @floatCast(cut[1]), @floatCast(cut[2]) };
    }

    /// Nothing to declare on macOS.
    pub fn declareLowLatency(self: *Window) bool {
        _ = self;
        return false;
    }

    /// Nothing to ask on macOS: with sync off (the GPU's present mode) frames are shown
    /// mid-scan.
    pub fn preferTearing(self: *Window) bool {
        _ = self;
        return true;
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        c.dimna_aw_set_title(self.handle, title.ptr);
    }

    /// What the GPU draws into: the view's CAMetalLayer, and where it puts each frame's
    /// drawable for `beforePresent`.
    pub fn gpuTarget(self: *const Window) Target {
        return .{ .layer = self.layer.?, .drawable = @constCast(&self.drawable) };
    }

    /// The name of screen `i` as macOS shows it, or null past the last one (as they were
    /// when the window was made).
    pub fn monitorName(self: *const Window, i: usize) ?[]const u8 {
        return if (i < self.num_screens) self.screen_names[i][0..self.screen_lens[i]] else null;
    }

    pub fn presentsOnNowClock(self: *const Window) bool {
        return self.on_now_clock;
    }

    /// Takes what the main thread and the presentation reports handed over, waiting up to
    /// `timeout_ms` (negative: no limit) for something if nothing had come.
    pub fn pump(self: *Window, timeout_ms: i32) !void {
        if (c.dimna_aw_is_main_thread() != 0) {
            // No loop runs (it would be on this thread): run AppKit's events here.
            c.dimna_aw_pump_main(if (timeout_ms < 0) 1e9 else @as(f64, @floatFromInt(timeout_ms)) / 1000);
            _ = self.takeHandedOver();
            return;
        }
        const seen = self.mailbox.seq.load(.seq_cst);
        if (self.takeHandedOver()) return;
        self.mailbox.wait(seen, timeout_ms);
        _ = self.takeHandedOver();
    }

    /// Moves what was handed over into `input`, the size, `closed`, `frame_ready` and the
    /// presented frames. True if there was anything.
    fn takeHandedOver(self: *Window) bool {
        const p = self.mailbox.take();
        const in = &self.input;
        in.scroll_x += p.scroll_x;
        in.scroll_y += p.scroll_y;
        in.pinch *= p.pinch;
        for (p.keys[0..p.num_keys]) |k| {
            if (in.num_keys == in.keys.len) break;
            in.keys[in.num_keys] = k;
            in.num_keys += 1;
        }
        in.clicks += p.clicks;
        in.right_clicks += p.right_clicks;
        in.middle_clicks += p.middle_clicks;
        if (p.text_len > 0) {
            // As much as fits, cut at a character's start.
            var n = @min(p.text_len, in.text.len - in.text_len);
            while (n > 0 and n < p.text_len and p.text[n] & 0xc0 == 0x80) n -= 1;
            @memcpy(in.text[in.text_len..][0..n], p.text[0..n]);
            in.text_len += n;
        }
        if (p.has_state) {
            in.left_down = p.state.left_down;
            in.shift = p.state.shift;
            in.ctrl = p.state.ctrl;
            in.alt = p.state.alt;
            in.pointer_x = p.state.pointer_x;
            in.pointer_y = p.state.pointer_y;
            in.pointer_inside = p.state.pointer_inside;
        }
        if (p.size) |s| if (s[0] != self.width or s[1] != self.height) {
            self.width = s[0];
            self.height = s[1];
            self.resized = true;
        };
        if (p.closed) self.closed = true;
        if (p.frame) self.frame_ready = true;
        if (p.time > 0) self.last_event_time = p.time;

        const r = &self.reports;
        r.acquire();
        const n = @min(r.n, self.presented.len - self.num_presented);
        @memcpy(self.presented[self.num_presented..][0..n], r.buf[0..n]);
        self.num_presented += n;
        const got = r.n;
        r.n = 0;
        self.discarded += r.discarded;
        r.discarded = 0;
        r.release();
        return p.events > 0 or got > 0;
    }

    /// Returns what the user did since the last call and starts collecting anew.
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

    /// Returns the frames presented since the last call (valid until the next `pump`).
    pub fn takePresented(self: *Window) []const Presented {
        const n = self.num_presented;
        self.num_presented = 0;
        return self.presented[0..n];
    }

    /// Called by `Gpu.draw` right before it presents the drawable it has put in
    /// `Target.drawable`: asks the display link for the next refresh and the drawable for
    /// the time it reaches the screen, tagged `tag`.
    pub fn beforePresent(self: *Window, tag: u64) void {
        self.frame_ready = false;
        c.dimna_aw_want_frame(self.handle);
        if (self.drawable) |d| c.dimna_aw_add_presented(self.handle, d, tag);
    }

    /// The pointer's shape over this window: the arrow, or the open or closed hand.
    pub fn setCursor(self: *Window, cursor: Cursor) void {
        if (cursor == self.cursor) return;
        self.cursor = cursor;
        c.dimna_aw_set_cursor(self.handle, switch (cursor) {
            .default => 0,
            .grab => 1,
            .grabbing => 2,
        });
    }

    // ---- callbacks from the shim

    /// On the main thread.
    fn onEvent(ctx: ?*anyopaque, ev: [*c]const c.DimnaAwEvent) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(ctx.?));
        if (self.key_debug and ev.*.kind == c.DIMNA_AW_KEY_DOWN) log.info("key code {d} pressed{s}: character U+{X:0>4}, modifiers 0x{x}", .{
            ev.*.code,
            if (ev.*.flags & c.DIMNA_AW_REPEAT != 0) " (repeat)" else "",
            ev.*.unmod,
            ev.*.mods,
        });
        self.mailbox.post(ev);
    }

    /// On a thread of the system's.
    fn onPresented(ctx: ?*anyopaque, tag: u64, time: f64, refresh_ns: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(ctx.?));
        const r = &self.reports;
        r.acquire();
        if (time <= 0) {
            r.discarded += 1;
        } else if (r.n < r.buf.len) {
            r.buf[r.n] = .{ .tag = tag, .time_ns = @intFromFloat(time * 1e9), .refresh_ns = refresh_ns };
            r.n += 1;
        }
        r.release();
        self.mailbox.signal();
    }
};

/// `CACurrentMediaTime` (presentation times) and `clock.nowNs` read the same clock: two
/// readings of the one around a reading of the other agree within 1 ms.
fn mediaTimeIsNow() bool {
    const a = c.dimna_aw_media_time() * 1e9;
    const now: f64 = @floatFromInt(dimna.clock.nowNs());
    const b = c.dimna_aw_media_time() * 1e9;
    return @abs(now - (a + b) / 2) < 1e6 + (b - a);
}

// ------------------------------------------------------------------------- tests

const testing = std.testing;

fn event(kind: c_int) c.DimnaAwEvent {
    var ev = std.mem.zeroes(c.DimnaAwEvent);
    ev.kind = @intCast(kind);
    return ev;
}

fn keyEvent(code: u32, unmod: u32, text: []const u8, mods: c_int, repeat: bool) c.DimnaAwEvent {
    var ev = event(c.DIMNA_AW_KEY_DOWN);
    ev.code = code;
    ev.unmod = unmod;
    ev.mods = @intCast(mods);
    ev.flags = if (repeat) c.DIMNA_AW_REPEAT else 0;
    @memcpy(@as([*]u8, @ptrCast(&ev.text))[0..text.len], text);
    ev.text_len = @intCast(text.len);
    return ev;
}

test "keys from key codes and the layout's characters" {
    const expectEqual = testing.expectEqual;
    // By the character, not the position: Dvorak's 'p' sits at QWERTY's R (code 15).
    try expectEqual(Key{ .char = 'p' }, keyOf(15, 'p').?);
    try expectEqual(Key{ .char = 'r' }, keyOf(15, 'r').?);
    try expectEqual(Key{ .char = ' ' }, keyOf(49, ' ').?);
    try expectEqual(Key{ .char = '/' }, keyOf(44, '/').?);
    // Named keys by code, whatever character AppKit gives them.
    try expectEqual(Key{ .named = .escape }, keyOf(53, 0x1b).?);
    try expectEqual(Key{ .named = .enter }, keyOf(36, '\r').?);
    try expectEqual(Key{ .named = .backspace }, keyOf(51, 0x7f).?);
    try expectEqual(Key{ .named = .tab }, keyOf(48, '\t').?);
    try expectEqual(Key{ .named = .left }, keyOf(123, 0xf702).?);
    try expectEqual(Key{ .named = .up }, keyOf(126, 0xf700).?);
    try expectEqual(Key{ .named = .right }, keyOf(124, 0xf703).?);
    try expectEqual(Key{ .named = .down }, keyOf(125, 0xf701).?);
    try expectEqual(Key{ .named = .home }, keyOf(115, 0xf729).?);
    try expectEqual(Key{ .named = .end }, keyOf(119, 0xf72b).?);
    try expectEqual(Key{ .named = .page_up }, keyOf(116, 0xf72c).?);
    try expectEqual(Key{ .named = .page_down }, keyOf(121, 0xf72d).?);
    // A letter outside ASCII, a function key (F1): not ours.
    try expectEqual(null, keyOf(41, 0xf6));
    try expectEqual(null, keyOf(122, 0xf704));
    // No character from AppKit: as on a US keyboard.
    try expectEqual(Key{ .char = 'a' }, keyOf(0, 0).?);
    try expectEqual(Key{ .char = 'r' }, keyOf(15, 0).?);
    try expectEqual(Key{ .char = 'q' }, keyOf(12, 0).?);
    try expectEqual(Key{ .char = '1' }, keyOf(18, 0).?);
    try expectEqual(Key{ .char = '/' }, keyOf(44, 0).?);
    try expectEqual(Key{ .char = ' ' }, keyOf(49, 0).?);
    try expectEqual(Key{ .char = '`' }, keyOf(50, 0).?);
    try expectEqual(null, keyOf(10, 0));
    try expectEqual(null, keyOf(122, 0));
}

test "scroll in wheel clicks of 15, positive down and right; positions in pixels with y down" {
    // A wheel click toward the user: AppKit's delta -1 line.
    try testing.expectEqual(15, scrollUnits(-1, false));
    try testing.expectEqual(-30, scrollUnits(2, false));
    // A trackpad: one per point.
    try testing.expectEqual(7, scrollUnits(-7, true));
    try testing.expectEqual(-2.5, scrollUnits(2.5, true));
    // 10 points from the left, 20 from the bottom of a view 500 points high, at scale 2.
    try testing.expectEqual([2]f64{ 20, 960 }, toPixels(10, 20, 500, 2));
    try testing.expectEqual([2]f64{ 10, 480 }, toPixels(10, 20, 500, 1));
    try testing.expectEqual(2560, sizePixels(1280, 2));
    try testing.expectEqual(1470, sizePixels(735, 2));
    try testing.expectEqual(1103, sizePixels(735.4, 1.5));
}

test "merging: one key per press, no repeat, none with Command; text without control characters" {
    var p: Pending = .{};
    var s: State = .{};
    merge(&p, &s, &keyEvent(15, 'p', "P", c.DIMNA_AW_SHIFT, false));
    merge(&p, &s, &keyEvent(15, 'p', "P", c.DIMNA_AW_SHIFT, true));
    merge(&p, &s, &keyEvent(15, 'p', "P", c.DIMNA_AW_SHIFT, true));
    merge(&p, &s, &keyEvent(12, 'q', "q", c.DIMNA_AW_CMD, false));
    merge(&p, &s, &keyEvent(0, 'a', "\x01", c.DIMNA_AW_CTRL, false));
    merge(&p, &s, &keyEvent(36, '\r', "\r", 0, false));
    merge(&p, &s, &keyEvent(123, 0xf702, "\u{f702}", 0, false));
    merge(&p, &s, &keyEvent(14, 'e', "é", c.DIMNA_AW_ALT, false));
    try testing.expectEqual(5, p.num_keys);
    try testing.expectEqual(Key{ .char = 'p' }, p.keys[0]);
    try testing.expectEqual(Key{ .char = 'a' }, p.keys[1]);
    try testing.expectEqual(Key{ .named = .enter }, p.keys[2]);
    try testing.expectEqual(Key{ .named = .left }, p.keys[3]);
    try testing.expectEqual(Key{ .char = 'e' }, p.keys[4]);
    try testing.expectEqualStrings("Pé", p.text[0..p.text_len]);
    try testing.expect(p.has_state and p.state.alt and !p.state.shift and !p.state.ctrl);
    // At most 16 keys and 64 bytes of text until taken, whole presses only.
    for (0..40) |_| merge(&p, &s, &keyEvent(0, 'a', "aa", 0, false));
    try testing.expectEqual(16, p.num_keys);
    try testing.expectEqual(3 + 30 * 2, p.text_len);
}

test "merging: buttons, motion, leave, scroll, momentum, pinch, size, close, frame" {
    var p: Pending = .{};
    var s: State = .{};
    var ev = event(c.DIMNA_AW_ENTER);
    ev.x = 10;
    ev.y = 20;
    ev.height_pt = 500;
    ev.scale = 2;
    merge(&p, &s, &ev);
    try testing.expect(p.state.pointer_inside and p.state.pointer_x == 20 and p.state.pointer_y == 960);
    ev = event(c.DIMNA_AW_BUTTON_DOWN);
    merge(&p, &s, &ev);
    ev.code = 1;
    merge(&p, &s, &ev);
    ev.code = 2;
    merge(&p, &s, &ev);
    ev.code = 3;
    merge(&p, &s, &ev);
    try testing.expect(p.clicks == 1 and p.right_clicks == 1 and p.middle_clicks == 1 and p.state.left_down);
    ev = event(c.DIMNA_AW_BUTTON_UP);
    ev.code = 1;
    merge(&p, &s, &ev);
    try testing.expect(p.state.left_down);
    ev.code = 0;
    merge(&p, &s, &ev);
    try testing.expect(!p.state.left_down);
    ev = event(c.DIMNA_AW_BUTTON_DOWN);
    merge(&p, &s, &ev);
    merge(&p, &s, &event(c.DIMNA_AW_LEAVE));
    try testing.expect(!p.state.left_down and !p.state.pointer_inside and p.clicks == 2);
    ev = event(c.DIMNA_AW_SCROLL);
    ev.y = -1;
    ev.x = 1;
    merge(&p, &s, &ev);
    ev.flags = c.DIMNA_AW_PRECISE;
    ev.y = -7;
    ev.x = 0;
    merge(&p, &s, &ev);
    ev.flags = c.DIMNA_AW_PRECISE | c.DIMNA_AW_MOMENTUM;
    ev.y = -100;
    merge(&p, &s, &ev);
    try testing.expect(p.scroll_y == 22 and p.scroll_x == -15);
    ev = event(c.DIMNA_AW_MAGNIFY);
    ev.x = 0.25;
    merge(&p, &s, &ev);
    ev.x = 0.1;
    merge(&p, &s, &ev);
    try testing.expectApproxEqAbs(1.375, p.pinch, 1e-12);
    // Not input: the state is left as it was.
    const before = p.state;
    ev = event(c.DIMNA_AW_SIZE);
    ev.x = 640;
    ev.y = 400.4;
    ev.scale = 2;
    ev.mods = c.DIMNA_AW_SHIFT;
    merge(&p, &s, &ev);
    merge(&p, &s, &event(c.DIMNA_AW_CLOSE));
    merge(&p, &s, &event(c.DIMNA_AW_FRAME));
    try testing.expectEqual([2]u32{ 1280, 801 }, p.size.?);
    try testing.expect(p.closed and p.frame and std.meta.eql(before, p.state));
}

test "the mailbox between threads: nothing lost, merged as it should be, the waiter woken" {
    // A producer thread stands for the main thread: 10,000 events, as fast as it can, while
    // the consumer takes them; then the totals.
    const Producer = struct {
        fn run(m: *Mailbox, n: usize) void {
            for (0..n) |i| {
                var ev = event(c.DIMNA_AW_MOTION);
                if (i % 100 == 50) {
                    ev = keyEvent(0, 'a', "a", 0, false);
                } else if (i % 25 == 10) {
                    ev = event(c.DIMNA_AW_SCROLL);
                    ev.y = -1;
                } else if (i % 25 == 20) {
                    ev = event(c.DIMNA_AW_BUTTON_DOWN);
                } else if (i % 25 == 21) {
                    ev = event(c.DIMNA_AW_BUTTON_UP);
                } else {
                    ev.x = @floatFromInt(i);
                    ev.height_pt = 100;
                    ev.y = 100;
                    ev.scale = 1;
                }
                m.post(&ev);
            }
        }
    };
    const n = 10_000;
    var m: Mailbox = .{};
    var t = try std.Thread.spawn(.{}, Producer.run, .{ &m, n });
    var events: u64 = 0;
    var keys: usize = 0;
    var clicks: u64 = 0;
    var scroll: f64 = 0;
    var last_x: f64 = 0;
    var takes: usize = 0;
    while (events < n) {
        const seen = m.seq.load(.seq_cst);
        const p = m.take();
        if (p.events == 0) {
            m.wait(seen, 100);
            continue;
        }
        takes += 1;
        events += p.events;
        keys += p.num_keys;
        clicks += p.clicks;
        scroll += p.scroll_y;
        if (p.has_state) last_x = p.state.pointer_x;
        // A press and its release are counted even when taken together.
        try testing.expect(!p.state.left_down or p.clicks > 0 or p.has_state);
    }
    t.join();
    try testing.expectEqual(n, events);
    try testing.expectEqual(400, clicks);
    try testing.expectEqual(400 * 15, scroll);
    try testing.expectEqual(9999, last_x);
    // Keys are kept to 16 a take: all of them here, as no take holds more than a few. On a
    // CI machine (the environment's `CI`) the consumer may be kept waiting while the whole
    // burst arrives, and one take then holds every key: GitHub's macOS runner kept 16 of
    // the 100 once (2026-11-24). There: at least a take's worth, and no more than were sent.
    if (std.c.getenv("CI") == null) try testing.expectEqual(100, keys) else try testing.expect(keys >= 16 and keys <= 100);
    if (std.c.getenv("CI") == null) try testing.expect(takes > 1);

    // A waiter is woken by an event at once, not at its timeout.
    const Late = struct {
        fn run(mb: *Mailbox) void {
            dimna.os.sleepNs(20 * std.time.ns_per_ms);
            var ev = event(c.DIMNA_AW_FRAME);
            mb.post(&ev);
        }
    };
    const seen = m.seq.load(.seq_cst);
    const t0 = dimna.clock.nowNs();
    t = try std.Thread.spawn(.{}, Late.run, .{&m});
    m.wait(seen, 2000);
    const waited = dimna.clock.nowNs() - t0;
    t.join();
    try testing.expect(m.take().frame);
    try testing.expect(waited >= 19 * std.time.ns_per_ms and waited < 500 * std.time.ns_per_ms);
    // And a wait with nothing coming ends at its timeout.
    const t1 = dimna.clock.nowNs();
    m.wait(m.seq.load(.seq_cst), 5);
    const idle = dimna.clock.nowNs() - t1;
    try testing.expect(idle >= 4 * std.time.ns_per_ms and idle < 200 * std.time.ns_per_ms);
}

test "without window.run, a window asked for off the main thread fails at once and makes nothing" {
    const Off = struct {
        fn f(result: *c_int) void {
            var info: c.DimnaAwInfo = undefined;
            var handle: ?*c.DimnaAwWindow = null;
            result.* = c.dimna_aw_create("x", null, .{ .event = null, .presented = null }, &info, &handle);
        }
    };
    var result: c_int = -1;
    const t = try std.Thread.spawn(.{}, Off.f, .{&result});
    t.join();
    try testing.expectEqual(c.DIMNA_AW_NO_LOOP, result);
    try testing.expectEqual(0, c.dimna_aw_test_live_windows());
}

test "CACurrentMediaTime is the clock nowNs reads" {
    try testing.expect(mediaTimeIsNow());
}

// ---- with windows: only when DIMNA_TEST_WINDOW=1 ----

fn windowsWanted() bool {
    const want = std.c.getenv("DIMNA_TEST_WINDOW") orelse return false;
    return std.mem.eql(u8, std.mem.span(want), "1");
}

fn presenterWanted() bool {
    const want = std.c.getenv("DIMNA_TEST_PRESENT") orelse return false;
    return std.mem.eql(u8, std.mem.span(want), "1");
}

const T = struct {
    fn deliver(w: *Window, what: c_int, code: c_int, chars: [:0]const u8, mods: c_int, repeat: bool, button: c_int, x: f64, y: f64) void {
        c.dimna_aw_test_deliver(w.handle, what, code, chars.ptr, @intCast(mods), @intFromBool(repeat), button, x, y, 0);
    }
    fn key(w: *Window, code: c_int, chars: [:0]const u8, mods: c_int, repeat: bool) void {
        deliver(w, c.DIMNA_AW_T_KEY_DOWN, code, chars, mods, repeat, 0, 0, 0);
    }
    fn at(w: *Window, what: c_int, button: c_int, x: f64, y: f64) void {
        deliver(w, what, 0, "", 0, false, button, x, y);
    }
    /// Pumps (an event delivered is in the mailbox already) and takes the input.
    fn take(w: *Window) !Input {
        try w.pump(0);
        return w.takeInput();
    }
    fn points(w: *Window) [2]f64 {
        var pw: f64 = 0;
        var ph: f64 = 0;
        c.dimna_aw_test_view_points(w.handle, &pw, &ph);
        return .{ pw, ph };
    }
    fn median(v: []f64) f64 {
        std.mem.sort(f64, v, {}, std.sort.asc(f64));
        return if (v.len == 0) 0 else v[v.len / 2];
    }
};

test "a window opens in pixels, resized at start, and closes leaving none" {
    if (!windowsWanted()) return error.SkipZigTest;
    const Body = struct {
        fn f() !void {
            var w: Window = undefined;
            try w.init("dimna test: open", "dimna-test", false);
            try testing.expect(w.resized and !w.closed and w.frame_ready);
            try testing.expect(w.layer != null and w.presentsOnNowClock());
            try testing.expectEqual(8, w.presentation_clock);
            const pt = T.points(&w);
            try w.pump(50);
            // Pixels: the view's points times the scale (2 on a Retina screen).
            const scale = @as(f64, @floatFromInt(w.width)) / pt[0];
            std.debug.print("\n  window: {d}x{d} points, {d}x{d} pixels, scale {d}; screens:", .{ pt[0], pt[1], w.width, w.height, scale });
            var i: usize = 0;
            while (w.monitorName(i)) |name| : (i += 1) std.debug.print(" '{s}'", .{name});
            std.debug.print("\n", .{});
            try testing.expect(scale == 1 or scale == 2 or scale == 3);
            try testing.expectEqual(w.height, sizePixels(pt[1], scale));
            try testing.expect(w.monitorName(0) != null);
            try testing.expect(!w.fullscreenOn("no such screen"));
            const t = w.gpuTarget();
            try testing.expect(t.layer == w.layer.? and t.drawable == &w.drawable);
            w.setTitle("dimna test: renamed");
            w.setCursor(.grab);
            w.setCursor(.grabbing);
            w.setCursor(.default);
            try testing.expectEqual(1, c.dimna_aw_test_visible_windows());
            w.deinit();
            try testing.expectEqual(0, c.dimna_aw_test_visible_windows());
        }
    };
    try run(Body.f, .{});
    try testing.expectEqual(0, c.dimna_aw_test_live_windows());
}

test "keys, text and modifiers through the window, as the contract has them" {
    if (!windowsWanted()) return error.SkipZigTest;
    const Body = struct {
        fn f() !void {
            var w: Window = undefined;
            try w.init("dimna test: keys", "dimna-test", false);
            defer w.deinit();
            _ = try T.take(&w);
            // Key code 15 (QWERTY's R): its character in this layout, also with Shift held;
            // the text is what the press typed.
            T.key(&w, 15, "x", 0, false);
            const plain = try T.take(&w);
            try testing.expectEqual(1, plain.num_keys);
            try testing.expect(plain.keys[0] == .char and std.ascii.isLower(plain.keys[0].char));
            try testing.expectEqualStrings("x", plain.text[0..plain.text_len]);
            T.key(&w, 15, "X", c.DIMNA_AW_SHIFT, false);
            const shifted = try T.take(&w);
            try testing.expectEqual(1, shifted.num_keys);
            try testing.expectEqual(plain.keys[0], shifted.keys[0]);
            try testing.expect(shifted.shift);
            try testing.expectEqualStrings("X", shifted.text[0..shifted.text_len]);
            std.debug.print("\n  key code 15 in this layout: '{c}'\n", .{plain.keys[0].char});
            // Named keys.
            T.key(&w, 53, "\x1b", 0, false);
            T.key(&w, 123, "\u{f702}", 0, false);
            T.key(&w, 36, "\r", 0, false);
            const named = try T.take(&w);
            try testing.expectEqual(3, named.num_keys);
            try testing.expectEqual(Key{ .named = .escape }, named.keys[0]);
            try testing.expectEqual(Key{ .named = .left }, named.keys[1]);
            try testing.expectEqual(Key{ .named = .enter }, named.keys[2]);
            try testing.expectEqual(0, named.text_len);
            // A key held: its repeats are not presses.
            T.key(&w, 49, " ", 0, false);
            T.key(&w, 49, " ", 0, true);
            T.key(&w, 49, " ", 0, true);
            T.deliver(&w, c.DIMNA_AW_T_KEY_UP, 49, " ", 0, false, 0, 0, 0);
            const held = try T.take(&w);
            try testing.expectEqual(1, held.num_keys);
            try testing.expectEqual(Key{ .char = ' ' }, held.keys[0]);
            try testing.expectEqualStrings(" ", held.text[0..held.text_len]);
            // Text outside ASCII, with Option; Control types nothing; Command is not ours.
            T.key(&w, 0, "a", c.DIMNA_AW_CMD, false);
            T.key(&w, 14, "é", c.DIMNA_AW_ALT, false);
            T.key(&w, 0, "\x01", c.DIMNA_AW_CTRL, false);
            const more = try T.take(&w);
            try testing.expectEqual(2, more.num_keys);
            try testing.expectEqualStrings("é", more.text[0..more.text_len]);
            try testing.expect(more.ctrl and !more.alt and !more.shift);
            // Modifiers alone.
            T.deliver(&w, c.DIMNA_AW_T_FLAGS, 0, "", c.DIMNA_AW_SHIFT | c.DIMNA_AW_ALT, false, 0, 0, 0);
            const mods = try T.take(&w);
            try testing.expect(mods.shift and mods.alt and !mods.ctrl and mods.num_keys == 0);
            T.deliver(&w, c.DIMNA_AW_T_FLAGS, 0, "", 0, false, 0, 0, 0);
            const none = try T.take(&w);
            try testing.expect(!none.shift and !none.alt);
            try testing.expect(!w.closed);
        }
    };
    try run(Body.f, .{});
}

test "pointer, buttons, scroll and pinch through the window; what takeInput resets and keeps" {
    if (!windowsWanted()) return error.SkipZigTest;
    const Body = struct {
        fn f() !void {
            var w: Window = undefined;
            try w.init("dimna test: pointer", "dimna-test", false);
            defer w.deinit();
            const pt = T.points(&w);
            const scale = @as(f64, @floatFromInt(w.width)) / pt[0];
            _ = try T.take(&w);
            // 10 points from the left, 20 from the top (AppKit's y is from the bottom).
            T.at(&w, c.DIMNA_AW_T_ENTER, 0, 10, pt[1] - 20);
            var in = try T.take(&w);
            try testing.expect(in.pointer_inside);
            try testing.expectEqual(10 * scale, in.pointer_x);
            try testing.expectEqual(20 * scale, in.pointer_y);
            T.at(&w, c.DIMNA_AW_T_MOVE, 0, 100.5, pt[1] - 50.25);
            in = try T.take(&w);
            try testing.expectEqual(100.5 * scale, in.pointer_x);
            try testing.expectEqual(50.25 * scale, in.pointer_y);
            // The three buttons; the left one held.
            T.at(&w, c.DIMNA_AW_T_MOUSE_DOWN, 0, 100.5, pt[1] - 50.25);
            T.at(&w, c.DIMNA_AW_T_MOUSE_DOWN, 1, 100.5, pt[1] - 50.25);
            T.at(&w, c.DIMNA_AW_T_MOUSE_UP, 1, 100.5, pt[1] - 50.25);
            T.at(&w, c.DIMNA_AW_T_MOUSE_DOWN, 2, 100.5, pt[1] - 50.25);
            T.at(&w, c.DIMNA_AW_T_MOUSE_UP, 2, 100.5, pt[1] - 50.25);
            in = try T.take(&w);
            try testing.expect(in.clicks == 1 and in.right_clicks == 1 and in.middle_clicks == 1 and in.left_down);
            // Taken: the presses are reset, the states kept.
            in = try T.take(&w);
            try testing.expect(in.clicks == 0 and in.right_clicks == 0 and in.middle_clicks == 0);
            try testing.expect(in.left_down and in.pointer_inside and in.pointer_x == 100.5 * scale);
            T.at(&w, c.DIMNA_AW_T_MOUSE_UP, 0, 100.5, pt[1] - 50.25);
            in = try T.take(&w);
            try testing.expect(!in.left_down and in.clicks == 0);
            // A wheel: a click toward the user is +15 (AppKit: -1 line), away -15; sideways.
            T.at(&w, c.DIMNA_AW_T_WHEEL, 0, 0, -1);
            in = try T.take(&w);
            try testing.expect(in.scroll_y == 15 and in.scroll_x == 0);
            T.at(&w, c.DIMNA_AW_T_WHEEL, 0, 0, 2);
            T.at(&w, c.DIMNA_AW_T_WHEEL, 0, -1, 0);
            in = try T.take(&w);
            try testing.expect(in.scroll_y == -30 and in.scroll_x == 15);
            // A trackpad, in points.
            T.at(&w, c.DIMNA_AW_T_PIXELS, 0, 3, -7);
            in = try T.take(&w);
            try testing.expect(in.scroll_y == 7 and in.scroll_x == -3);
            // Pinch: the ratio since the last take.
            T.at(&w, c.DIMNA_AW_T_MAGNIFY, 0, 0.25, 0);
            T.at(&w, c.DIMNA_AW_T_MAGNIFY, 0, 0.1, 0);
            in = try T.take(&w);
            try testing.expectApproxEqAbs(1.375, in.pinch, 1e-6);
            in = try T.take(&w);
            try testing.expect(in.pinch == 1 and in.scroll_x == 0 and in.scroll_y == 0);
            // Leaving.
            T.at(&w, c.DIMNA_AW_T_EXIT, 0, 0, 0);
            in = try T.take(&w);
            try testing.expect(!in.pointer_inside);
        }
    };
    try run(Body.f, .{});
}

test "the close button and Cmd-Q close the windows" {
    if (!windowsWanted()) return error.SkipZigTest;
    const Body = struct {
        fn f() !void {
            var a: Window = undefined;
            try a.init("dimna test: close A", "dimna-test", false);
            defer a.deinit();
            var b: Window = undefined;
            try b.init("dimna test: close B", "dimna-test", false);
            defer b.deinit();
            try a.pump(0);
            try b.pump(0);
            T.at(&a, c.DIMNA_AW_T_CLOSE_BUTTON, 0, 0, 0);
            try a.pump(0);
            try b.pump(0);
            try testing.expect(a.closed and !b.closed);
            T.at(&b, c.DIMNA_AW_T_CMD_Q, 0, 0, 0);
            try b.pump(0);
            try testing.expect(b.closed);
            // Still there until deinit, as on Wayland.
            try testing.expectEqual(2, c.dimna_aw_test_visible_windows());
        }
    };
    try run(Body.f, .{});
    try testing.expectEqual(0, c.dimna_aw_test_live_windows());
}

test "three windows on three threads pump at once, each with only its own events" {
    if (!windowsWanted()) return error.SkipZigTest;
    const Shared = struct {
        windows: [3]*Window = undefined,
        ready: std.atomic.Value(u32) = .init(0),
        go: std.atomic.Value(u32) = .init(0),
        got: [3]Input = undefined,
        failed: std.atomic.Value(u32) = .init(0),
    };
    const Owner = struct {
        fn f(s: *Shared, k: usize) void {
            var w: Window = undefined;
            var title: [32:0]u8 = @splat(0);
            _ = std.fmt.bufPrint(&title, "dimna test: thread {d}", .{k}) catch {};
            w.init(&title, "dimna-test", false) catch {
                _ = s.failed.fetchAdd(1, .monotonic);
                _ = s.ready.fetchAdd(1, .release);
                return;
            };
            defer w.deinit();
            s.windows[k] = &w;
            _ = s.ready.fetchAdd(1, .release);
            while (s.go.load(.acquire) == 0) std.atomic.spinLoopHint();
            // Until this window's key and pointer have come, or 2 s.
            var all: Input = .{};
            const end = dimna.clock.nowNs() + 2 * std.time.ns_per_s;
            while (dimna.clock.nowNs() < end) {
                w.pump(100) catch break;
                const in = w.takeInput();
                for (in.keys[0..in.num_keys]) |key| {
                    all.keys[all.num_keys] = key;
                    all.num_keys += 1;
                }
                all.clicks += in.clicks;
                all.pointer_x = in.pointer_x;
                if (all.num_keys >= 1 and all.pointer_x != 0 and all.clicks > 0) {
                    // A little longer: anything else meant for another window would come now.
                    w.pump(50) catch {};
                    const late = w.takeInput();
                    all.num_keys += late.num_keys;
                    all.clicks += late.clicks;
                    break;
                }
            }
            // Wait for the others before closing, so all three pump at once to the end.
            _ = s.ready.fetchAdd(1, .acq_rel);
            while (s.ready.load(.acquire) < 6) std.atomic.spinLoopHint();
            s.got[k] = all;
        }
    };
    const Body = struct {
        fn f(s: *Shared) !void {
            var threads: [3]std.Thread = undefined;
            for (&threads, 0..) |*t, k| t.* = try std.Thread.spawn(.{}, Owner.f, .{ s, k });
            while (s.ready.load(.acquire) < 3) std.atomic.spinLoopHint();
            if (s.failed.load(.monotonic) == 0) {
                s.go.store(1, .release);
                // Interleaved, without waiting: a named key, a pointer and a click each.
                const codes = [3]c_int{ 53, 123, 36 };
                for (0..3) |k| {
                    for (0..3) |j| {
                        const h = s.windows[j].handle;
                        switch (k) {
                            0 => c.dimna_aw_test_deliver(h, c.DIMNA_AW_T_KEY_DOWN, codes[j], "", 0, 0, 0, 0, 0, 1),
                            1 => c.dimna_aw_test_deliver(h, c.DIMNA_AW_T_MOVE, 0, "", 0, 0, 0, @floatFromInt(10 * (j + 1)), 10, 1),
                            else => c.dimna_aw_test_deliver(h, c.DIMNA_AW_T_MOUSE_DOWN, 0, "", 0, 0, 0, @floatFromInt(10 * (j + 1)), 10, 1),
                        }
                    }
                }
            } else s.ready.store(6, .release);
            for (threads) |t| t.join();
            try testing.expectEqual(0, s.failed.load(.monotonic));
        }
    };
    var s: Shared = .{};
    try run(Body.f, .{&s});
    const named = [3]Key.Named{ .escape, .left, .enter };
    for (s.got, 0..) |in, k| {
        try testing.expectEqual(1, in.num_keys);
        try testing.expectEqual(Key{ .named = named[k] }, in.keys[0]);
        try testing.expectEqual(1, in.clicks);
        try testing.expect(in.pointer_x > 0);
    }
    // Each its own pointer (10, 20, 30 points from the left, times the scale).
    try testing.expect(s.got[0].pointer_x < s.got[1].pointer_x and s.got[1].pointer_x < s.got[2].pointer_x);
    try testing.expectEqual(0, c.dimna_aw_test_live_windows());
}

test "the hand-over's cost, and a burst of 10,000 events" {
    if (!windowsWanted()) return error.SkipZigTest;
    const n_paced = 3000;
    const Shared = struct {
        w: Window = undefined,
        lat_ns: [n_paced]f64 = undefined,
        n_lat: usize = 0,
        stop: std.atomic.Value(u32) = .init(0),
        // The burst's totals as the pumping thread took them.
        events_x: f64 = 0,
        keys: usize = 0,
        most_keys: usize = 0,
        clicks: u64 = 0,
        scroll: f64 = 0,
        takes: usize = 0,
        left_down: bool = false,
    };
    const Consumer = struct {
        /// Pumps as the control window does (waiting up to 100 ms) and times each event
        /// from its time stamp (taken on the main thread as it was handed to the view).
        fn paced(s: *Shared) void {
            var last_x: f64 = -1;
            while (s.stop.load(.acquire) == 0) {
                s.w.pump(100) catch return;
                const now = dimna.clock.nowNs();
                const in = s.w.takeInput();
                if (in.pointer_x != last_x and s.n_lat < s.lat_ns.len) {
                    last_x = in.pointer_x;
                    s.lat_ns[s.n_lat] = @as(f64, @floatFromInt(now)) - s.w.last_event_time * 1e9;
                    s.n_lat += 1;
                }
            }
        }
        fn burst(s: *Shared) void {
            while (s.stop.load(.acquire) == 0) {
                s.w.pump(100) catch return;
                const in = s.w.takeInput();
                if (in.num_keys > 0 or in.clicks > 0 or in.scroll_y != 0 or in.pointer_x != s.events_x) s.takes += 1;
                s.keys += in.num_keys;
                s.most_keys = @max(s.most_keys, in.num_keys);
                s.clicks += in.clicks;
                s.scroll += in.scroll_y;
                s.events_x = in.pointer_x;
                s.left_down = in.left_down;
            }
        }
    };
    const Body = struct {
        fn f(s: *Shared) !void {
            try s.w.init("dimna test: hand-over", "dimna-test", false);
            defer s.w.deinit();
            const pt = T.points(&s.w);
            const scale = @as(f64, @floatFromInt(s.w.width)) / pt[0];
            _ = try T.take(&s.w);
            // Paced: one motion event every 0.5 ms, handed to the main thread to deliver.
            var t = try std.Thread.spawn(.{}, Consumer.paced, .{s});
            for (0..n_paced) |i| {
                c.dimna_aw_test_deliver(s.w.handle, c.DIMNA_AW_T_MOVE, 0, "", 0, 0, 0, @floatFromInt(i + 1), 10, 1);
                dimna.os.sleepNs(500 * std.time.ns_per_us);
            }
            dimna.os.sleepNs(50 * std.time.ns_per_ms);
            s.stop.store(1, .release);
            s.w.mailbox.signal();
            t.join();
            const lat = s.lat_ns[0..s.n_lat];
            std.mem.sort(f64, lat, {}, std.sort.asc(f64));
            std.debug.print("\n  hand-over, {d} events paced 0.5 ms apart, {d} seen apart: from the main thread to pump returning, us: median {d:.1}, 99th percentile {d:.1}, worst {d:.1}, best {d:.1}\n", .{
                n_paced, lat.len, lat[lat.len / 2] / 1e3, lat[lat.len * 99 / 100] / 1e3, lat[lat.len - 1] / 1e3, lat[0] / 1e3,
            });
            try testing.expect(lat.len > n_paced * 9 / 10);

            // A burst: 10,000 events on the main thread in one go while the window's thread
            // pumps (event i: a key press of code 0 at i % 100 == 50, a wheel click down at
            // i % 25 == 10, a left press at 20 and its release at 21, else motion to x = i).
            s.stop.store(0, .release);
            t = try std.Thread.spawn(.{}, Consumer.burst, .{s});
            const t0 = dimna.clock.nowNs();
            c.dimna_aw_test_burst(s.w.handle, 10_000, pt[1] - 10);
            const took = dimna.clock.nowNs() - t0;
            dimna.os.sleepNs(50 * std.time.ns_per_ms);
            s.stop.store(1, .release);
            s.w.mailbox.signal();
            t.join();
            std.debug.print("  burst of 10,000 on the main thread ({d:.1} ms), pumped meanwhile: {d} takes, keys {d} (most in one take {d}), clicks {d}, scroll {d}, last x {d}, left held {}\n", .{
                @as(f64, @floatFromInt(took)) / 1e6, s.takes, s.keys, s.most_keys, s.clicks, s.scroll, s.events_x / scale, s.left_down,
            });
            try testing.expectEqual(100, s.keys);
            try testing.expectEqual(400, s.clicks);
            try testing.expectEqual(400 * 15, s.scroll);
            try testing.expectEqual(9999 * scale, s.events_x);
            try testing.expect(!s.left_down);

            // The same burst with the window's thread busy elsewhere until it is over: one
            // take; keys beyond 16 are dropped, as on Linux (16 a take).
            c.dimna_aw_test_burst(s.w.handle, 10_000, pt[1] - 10);
            try s.w.pump(0);
            const in = s.w.takeInput();
            std.debug.print("  the same, taken once after: keys {d}, clicks {d}, scroll {d}, last x {d}, left held {}\n", .{
                in.num_keys, in.clicks, in.scroll_y, in.pointer_x / scale, in.left_down,
            });
            try testing.expect(in.num_keys == 16 and in.clicks == 400 and in.scroll_y == 6000 and in.pointer_x == 9999 * scale);
        }
    };
    const s = try testing.allocator.create(Shared);
    defer testing.allocator.destroy(s);
    s.* = .{};
    try run(Body.f, .{s});
}

test "a window made on the main thread without window.run" {
    if (!windowsWanted()) return error.SkipZigTest;
    var w: Window = undefined;
    try w.init("dimna test: main thread", "dimna-test", false);
    defer w.deinit();
    try w.pump(20);
    T.key(&w, 53, "\x1b", 0, false);
    try w.pump(0);
    const in = w.takeInput();
    try testing.expectEqual(1, in.num_keys);
    try testing.expectEqual(Key{ .named = .escape }, in.keys[0]);
}

test "presentation times, with the test presenter: windowed and fullscreen, sync on and off" {
    if (!windowsWanted() or !presenterWanted()) return error.SkipZigTest;
    const Mode = struct { name: []const u8, fullscreen: bool, sync: bool, gated: bool };
    const modes = [_]Mode{
        .{ .name = "window, sync on", .fullscreen = false, .sync = true, .gated = false },
        .{ .name = "window, sync off", .fullscreen = false, .sync = false, .gated = false },
        .{ .name = "window, sync off, drawn on frame_ready", .fullscreen = false, .sync = false, .gated = true },
        .{ .name = "fullscreen, sync on", .fullscreen = true, .sync = true, .gated = false },
        .{ .name = "fullscreen, sync off", .fullscreen = true, .sync = false, .gated = false },
    };
    const Body = struct {
        fn f(mode: Mode) !void {
            const gpa = testing.allocator;
            var w: Window = undefined;
            try w.init("dimna test: presenter", "dimna-test", false);
            defer w.deinit();
            if (mode.fullscreen) try testing.expect(w.fullscreenOn(w.monitorName(0).?));
            var active: c_int = 0;
            var visible: c_int = 0;
            c.dimna_aw_test_state(w.handle, &active, &visible, 0);
            const was_active = active;
            const was_visible = visible;
            // Not hidden under another application's window, whether or not dimna could
            // become the active one.
            c.dimna_aw_test_state(w.handle, &active, &visible, 1);
            const max = 4096;
            const before = try gpa.alloc(i128, max);
            defer gpa.free(before);
            const lat = try gpa.alloc(f64, max);
            defer gpa.free(lat);
            var n_lat: usize = 0;
            var n_late_clock: usize = 0;
            var tag: u64 = 0;
            var refresh: u32 = 0;
            // Half a second to settle (the fullscreen change), then 3 s measured.
            const t_start = dimna.clock.nowNs();
            const t_measure = t_start + std.time.ns_per_s / 2;
            const t_end = t_measure + 3 * std.time.ns_per_s;
            var frames: usize = 0;
            while (dimna.clock.nowNs() < t_end + std.time.ns_per_s / 5) {
                try w.pump(if (mode.gated and !w.frame_ready) 20 else 0);
                for (w.takePresented()) |p| {
                    refresh = p.refresh_ns;
                    const b = before[p.tag % max];
                    if (b < t_measure or n_lat == max) continue;
                    if (p.time_ns < b) n_late_clock += 1;
                    lat[n_lat] = @as(f64, @floatFromInt(p.time_ns - b)) / 1e6;
                    n_lat += 1;
                }
                const now = dimna.clock.nowNs();
                if (now >= t_end) continue;
                if (mode.gated and !w.frame_ready) continue;
                const d = c.dimna_aw_test_next_drawable(w.handle, @intFromBool(mode.sync)) orelse continue;
                tag += 1;
                w.drawable = d;
                before[tag % max] = dimna.clock.nowNs();
                w.beforePresent(tag);
                c.dimna_aw_test_present(d, @floatCast(@as(f64, @floatFromInt(tag % 60)) / 60));
                w.drawable = null;
                if (now >= t_measure) frames += 1;
            }
            const v = lat[0..n_lat];
            std.mem.sort(f64, v, {}, std.sort.asc(f64));
            c.dimna_aw_test_state(w.handle, &active, &visible, 0);
            std.debug.print("  {s} (active {d}, visible {d}; after raising: active {d}, visible {d})\n", .{ mode.name, was_active, was_visible, active, visible });
            std.debug.print("  {s}: {d:.0} frames/s drawn, {d} reports, discarded {d}; beforePresent to presented ms: median {d:.2}, 95th {d:.2}, worst {d:.2}, best {d:.2}; refresh {d:.2} ms; before beforePresent {d}\n", .{
                mode.name,                              @as(f64, @floatFromInt(frames)) / 3,       v.len,                              w.discarded,
                if (v.len > 0) v[v.len / 2] else 0,     if (v.len > 0) v[v.len * 95 / 100] else 0, if (v.len > 0) v[v.len - 1] else 0, if (v.len > 0) v[0] else 0,
                @as(f64, @floatFromInt(refresh)) / 1e6, n_late_clock,
            });
            try testing.expect(v.len > 0 and n_late_clock == 0);
        }
    };
    std.debug.print("\n", .{});
    for (modes) |mode| {
        try run(Body.f, .{mode});
        dimna.os.sleepNs(std.time.ns_per_s);
    }
    try testing.expectEqual(0, c.dimna_aw_test_live_windows());
}
