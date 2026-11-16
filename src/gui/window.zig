//! A window: what the display, the control window and the tiles each open one of. This
//! file holds what every backend and its callers agree on (`Key`, `Cursor`, `Input`,
//! `Presented`) and the choice of this system's backend, at compile time: `Window` is the
//! backend's own, so a caller calls the backend's functions directly; there is no indirect
//! call. Linux: `window_wayland.zig` (a Wayland xdg_toplevel). macOS: `window_appkit.zig`
//! (an AppKit window with a CAMetalLayer view, through `appkit_shim.m`).
//!
//! What a backend's `Window` must keep, because the callers rely on it (main.zig,
//! control.zig, tiles.zig; display.zig, notes.zig and script.zig read `Input`):
//!
//! - `init(title, app_id, key_debug)` on a `Window` that stays at that address; `deinit`.
//!   Each window has its own connection to the window system, and everything of it belongs
//!   to the thread that calls `pump` (three windows run on three threads).
//! - `pump(timeout_ms)`: sends what was asked for and handles the window system's events,
//!   waiting up to `timeout_ms` (0 to 2 ms on the display's loop) for some to arrive. What
//!   the window system reports (input, size, frames presented) arrives only inside it.
//! - `takeInput()`: what the user did since the last call. It resets `scroll_x`,
//!   `scroll_y`, `pinch` (to 1), `num_keys`, `clicks`, `right_clicks`, `middle_clicks` and
//!   `text_len`; `left_down`, `shift`, `ctrl`, `alt`, `pointer_x`, `pointer_y` and
//!   `pointer_inside` stay as they are (they are states, not events).
//!   - Keys: one `Key` per press, at most 16 per take; no key repeat. A key is the
//!     character its key is labelled with in the user's layout without modifiers ('r' on
//!     the key marked r, also with Shift held); the modifiers are `shift`, `ctrl`, `alt`.
//!     `text` (at most 64 bytes of UTF-8) is what the presses typed with the modifiers.
//!   - Scroll: in units of about 15 per wheel click, positive down (`scroll_y`) or right
//!     (`scroll_x`). Pinch: the ratio of finger spread since the last take (1: none,
//!     > 1: apart).
//!   - `pointer_x`, `pointer_y`: in the same unit as `width`, `height` and the GPU's
//!     `pixelSize` (pixels; there is no scaling between them).
//! - Plain fields the callers read and write:
//!   - `width`, `height` (read): the size the window system gave, which `Gpu.resize` is
//!     asked for;
//!   - `resized`: set by the backend when the size changed (true at start); the caller sets
//!     it false after `Gpu.resize`, and true when `Gpu.draw` says `.out_of_date`;
//!   - `closed` (read): the user closed the window;
//!   - `frame_ready`: the window system wants a new frame (set by the backend; cleared by
//!     `beforePresent`); the display's loop sets it true again when `Gpu.draw` presented
//!     nothing (`.busy`, `.out_of_date`).
//!   - `presentation_clock` (read, for a message only): the system's number of the clock
//!     presentation times are on.
//! - `beforePresent(tag)`: called by `Gpu.draw` immediately before the frame is presented,
//!   so that what it asks for (the next frame's callback, and the report of when this frame
//!   reached the screen, tagged `tag`) attaches to this frame.
//! - `takePresented()`: the frames that reached the screen since the last call (valid
//!   until the next `pump`); `presentsOnNowClock()`: their times are on the clock
//!   `clock.nowNs` reads (else the latency figures are off).
//! - `gpuTarget()`: what `Gpu.init` draws into. `monitorName(i)`: the name of monitor `i`
//!   (null past the last), for `fullscreenOn(name)`, which makes the window fullscreen
//!   there (false: no such monitor).
//! - `declareLowLatency()`, `preferTearing()` (false where not supported), `setTitle`,
//!   `setCursor(cursor)`.
//!
//! And besides `Window`, `run(body, args)` (see `run` below), which main.zig runs the
//! display in.

const std = @import("std");
const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .linux => @import("window_wayland.zig"),
    .macos => @import("window_appkit.zig"),
    else => @compileError("dimna has no window backend for this system yet"),
};
pub const Window = backend.Window;

/// Runs `body` with `args` (a tuple) with this system's windowing set up around it, and
/// returns what `body` returns (its status, or its error). main.zig runs the display's
/// work in it: its window, the loop and the teardown.
///
/// Linux (`window_wayland.zig`): calls `body` on the calling thread, the process's main
/// thread, and returns its result; nothing else. Each window has its own connection there,
/// so the control window's and the tiles' threads make theirs themselves. Both functions
/// and the call of `body` are inlined, so `body` is compiled into its caller as when it
/// was written there (main.zig's `main` is the code it was before `runDisplay` was cut
/// out of it).
///
/// macOS (`window_appkit.zig`): AppKit must own the process's main thread, so `run` starts
/// `body` on a new thread, runs AppKit's loop on the main thread (making and destroying
/// the windows that `Window.init` and `deinit`, on any thread, ask it for, while the asking
/// thread waits), and returns `body`'s result when `body` has ended.
pub inline fn run(comptime body: anytype, args: anytype) @TypeOf(@call(.auto, body, args)) {
    return backend.run(body, args);
}

/// A key dimna acts on, by what the key is labelled in the user's keyboard layout (its
/// symbol without modifiers, from the compositor's keymap through xkbcommon), not by where
/// it sits: on Dvorak, 'r' is the key marked r.
pub const Key = union(enum) {
    /// A key that types a character: that character without modifiers ('r', '/', '1', ' ').
    char: u8,
    named: Named,

    pub const Named = enum { escape, enter, backspace, tab, home, end, page_up, page_down, left, up, right, down };

    /// From an X keysym; null for a key dimna has no use for.
    pub fn fromKeysym(sym: u32) ?Key {
        return switch (sym) {
            0x20...0x7e => .{ .char = @intCast(sym) },
            0xff1b => .{ .named = .escape },
            0xff0d => .{ .named = .enter },
            0xff08 => .{ .named = .backspace },
            0xff09 => .{ .named = .tab },
            0xff50 => .{ .named = .home },
            0xff57 => .{ .named = .end },
            0xff55 => .{ .named = .page_up },
            0xff56 => .{ .named = .page_down },
            0xff51 => .{ .named = .left },
            0xff52 => .{ .named = .up },
            0xff53 => .{ .named = .right },
            0xff54 => .{ .named = .down },
            else => null,
        };
    }

    pub fn is(self: Key, c: u8) bool {
        return self == .char and self.char == c;
    }

    pub fn isNamed(self: Key, n: Named) bool {
        return self == .named and self.named == n;
    }

    /// 1 to 9 for a digit key, else null.
    pub fn digit(self: Key) ?u8 {
        return if (self == .char and self.char >= '1' and self.char <= '9') self.char - '0' else null;
    }
};

/// What the pointer looks like over a window.
pub const Cursor = enum { default, grab, grabbing };

/// What the user did since the last `takeInput`.
pub const Input = struct {
    /// Wheel or two-finger scroll, in the compositor's axis units (a wheel click is about 15).
    scroll_x: f64 = 0,
    scroll_y: f64 = 0,
    /// Pinch scale relative to the last `takeInput` (1 = none, > 1 = fingers apart).
    pinch: f64 = 1,
    keys: [16]Key = undefined,
    num_keys: usize = 0,
    /// The left mouse button is held down (for dragging).
    left_down: bool = false,
    /// Presses of the left, right and middle mouse buttons.
    clicks: u32 = 0,
    right_clicks: u32 = 0,
    middle_clicks: u32 = 0,
    /// What the keys pressed would type (UTF-8), for text entry.
    text: [64]u8 = undefined,
    text_len: usize = 0,
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    /// The pointer is over the window (between its enter and leave).
    pointer_inside: bool = false,
};

/// A frame that reached the screen.
pub const Presented = struct {
    /// The tag given to `beforePresent`.
    tag: u64,
    /// Presentation time in the compositor's presentation clock, ns.
    time_ns: i128,
    /// The output's refresh period in ns (0 if unknown).
    refresh_ns: u32,
};

test "run returns what the body returns, or its error; on Linux on the calling thread" {
    const Body = struct {
        fn f(thread: *std.Thread.Id, status: u8) !u8 {
            thread.* = std.Thread.getCurrentId();
            if (status == 255) return error.BodyFailed;
            return status;
        }
    };
    var thread: std.Thread.Id = undefined;
    for ([_]u8{ 0, 1, 2 }) |status| {
        try std.testing.expectEqual(status, try run(Body.f, .{ &thread, status }));
        if (builtin.os.tag == .linux) try std.testing.expectEqual(std.Thread.getCurrentId(), thread);
    }
    try std.testing.expectError(error.BodyFailed, run(Body.f, .{ &thread, 255 }));
}

test "keys from keysyms: characters, named keys, and nothing for the rest" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(Key{ .char = 'r' }, Key.fromKeysym('r').?);
    try expectEqual(Key{ .char = ' ' }, Key.fromKeysym(0x20).?);
    try expectEqual(Key{ .named = .escape }, Key.fromKeysym(0xff1b).?);
    try expectEqual(Key{ .named = .page_down }, Key.fromKeysym(0xff56).?);
    // Shift, a function key, a letter outside ASCII: not ours.
    try expectEqual(null, Key.fromKeysym(0xffe1));
    try expectEqual(null, Key.fromKeysym(0xffbe));
    try expectEqual(null, Key.fromKeysym(0xe9));
    try expectEqual(null, Key.fromKeysym(0));
    try expectEqual(3, (Key{ .char = '3' }).digit().?);
    try expectEqual(null, (Key{ .char = '0' }).digit());
    try expectEqual(null, (Key{ .named = .enter }).digit());
    try std.testing.expect((Key{ .char = '/' }).is('/') and !(Key{ .named = .tab }).is('/'));
    try std.testing.expect((Key{ .named = .tab }).isNamed(.tab) and !(Key{ .char = 'q' }).isNamed(.escape));
}
