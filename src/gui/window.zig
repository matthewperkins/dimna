//! One Wayland window (xdg_toplevel), with the input and timing the trace display needs:
//! wheel and two-finger scrolling, touchpad pinch, a few keys, frame callbacks to pace
//! drawing, and presentation feedback (when a frame actually reached the screen).
//!
//! All Wayland objects belong to the thread that calls `pump`.

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const wp = wayland.client.wp;
const zwp = wayland.client.zwp;
const linux = std.os.linux;
const log = std.log.scoped(.window);

/// Evdev key codes (wl_keyboard delivers these; no keymap is needed for a few fixed keys).
pub const Key = enum(u32) {
    escape = 1,
    q = 16,
    r = 19,
    minus = 12,
    equal = 13,
    left_bracket = 26,
    right_bracket = 27,
    up = 103,
    down = 108,
    left = 105,
    right = 106,
    _,
};

/// What the user did since the last `takeInput`.
pub const Input = struct {
    /// Wheel or two-finger scroll, in the compositor's axis units (a wheel click is about 15).
    scroll_x: f64 = 0,
    scroll_y: f64 = 0,
    /// Pinch scale relative to the last `takeInput` (1 = none, > 1 = fingers apart).
    pinch: f64 = 1,
    keys: [16]Key = undefined,
    num_keys: usize = 0,
    shift: bool = false,
    ctrl: bool = false,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
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

const FeedbackSlot = struct {
    window: *Window,
    tag: u64 = 0,
    used: bool = false,
};

pub const Window = struct {
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    seat: ?*wl.Seat = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    gestures: ?*zwp.PointerGesturesV1 = null,
    pinch: ?*zwp.PointerGesturePinchV1 = null,
    presentation: ?*wp.Presentation = null,
    /// clockid_t of presentation timestamps (1 = CLOCK_MONOTONIC), -1 until known.
    presentation_clock: i64 = -1,

    surface: *wl.Surface = undefined,
    xdg_surface: *xdg.Surface = undefined,
    toplevel: *xdg.Toplevel = undefined,

    /// Size in surface units, as last configured (the compositor's choice, or our default).
    width: u32 = 1280,
    height: u32 = 800,
    /// Set when the size changed; the renderer clears it after rebuilding the swapchain.
    resized: bool = true,
    configured: bool = false,
    closed: bool = false,

    /// True when the compositor wants a new frame (set by the frame callback).
    frame_ready: bool = true,
    frame_callback: ?*wl.Callback = null,

    input: Input = .{},
    pinch_last: f64 = 1,
    feedback: [32]FeedbackSlot = undefined,
    presented: [64]Presented = undefined,
    num_presented: usize = 0,
    discarded: u64 = 0,

    /// Connects and creates the window. `self` must stay at a fixed address.
    pub fn init(self: *Window, title: [:0]const u8) !void {
        const display = try wl.Display.connect(null);
        errdefer display.disconnect();
        self.* = .{ .display = display, .registry = try display.getRegistry() };
        for (&self.feedback) |*f| f.* = .{ .window = self };
        self.registry.setListener(*Window, onRegistry, self);
        if (display.roundtrip() != .SUCCESS) return error.WaylandRoundtrip;
        const compositor = self.compositor orelse return error.NoCompositor;
        const wm_base = self.wm_base orelse return error.NoXdgShell;
        wm_base.setListener(*Window, onWmBase, self);
        if (self.seat) |seat| seat.setListener(*Window, onSeat, self);
        if (self.presentation) |p| p.setListener(*Window, onPresentation, self);

        self.surface = try compositor.createSurface();
        self.xdg_surface = try wm_base.getXdgSurface(self.surface);
        self.toplevel = try self.xdg_surface.getToplevel();
        self.xdg_surface.setListener(*Window, onXdgSurface, self);
        self.toplevel.setListener(*Window, onToplevel, self);
        self.toplevel.setTitle(title);
        self.toplevel.setAppId("oez");
        // The first commit, without a buffer, asks the compositor to configure the window.
        self.surface.commit();
        while (!self.configured) {
            if (display.dispatch() != .SUCCESS) return error.WaylandDispatch;
        }
        if (self.presentation == null) log.warn("no wp_presentation: display latency cannot be measured", .{});
        if (self.gestures == null) log.info("no pointer gestures: pinch is unavailable", .{});
    }

    pub fn deinit(self: *Window) void {
        if (self.frame_callback) |cb| cb.destroy();
        if (self.pinch) |p| p.destroy();
        if (self.pointer) |p| p.release();
        if (self.keyboard) |k| k.release();
        self.toplevel.destroy();
        self.xdg_surface.destroy();
        self.surface.destroy();
        self.display.disconnect();
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        self.toplevel.setTitle(title);
    }

    /// Sends our requests and handles the compositor's events, waiting up to `timeout_ms`
    /// for some to arrive.
    pub fn pump(self: *Window, timeout_ms: i32) !void {
        const d = self.display;
        while (!d.prepareRead()) {
            if (d.dispatchPending() != .SUCCESS) return error.WaylandDispatch;
        }
        _ = d.flush();
        var pfd = [1]linux.pollfd{.{ .fd = d.getFd(), .events = linux.POLL.IN, .revents = 0 }};
        const n = linux.poll(&pfd, 1, timeout_ms);
        if (linux.errno(n) == .SUCCESS and n > 0 and (pfd[0].revents & linux.POLL.IN) != 0) {
            if (d.readEvents() != .SUCCESS) return error.WaylandRead;
        } else {
            d.cancelRead();
            if (linux.errno(n) == .SUCCESS and n > 0 and (pfd[0].revents & (linux.POLL.ERR | linux.POLL.HUP)) != 0) return error.WaylandClosed;
        }
        if (d.dispatchPending() != .SUCCESS) return error.WaylandDispatch;
    }

    /// Returns what the user did since the last call and starts collecting anew.
    pub fn takeInput(self: *Window) Input {
        const in = self.input;
        self.input.scroll_x = 0;
        self.input.scroll_y = 0;
        self.input.pinch = 1;
        self.input.num_keys = 0;
        return in;
    }

    /// Returns the frames presented since the last call (valid until the next `pump`).
    pub fn takePresented(self: *Window) []const Presented {
        const n = self.num_presented;
        self.num_presented = 0;
        return self.presented[0..n];
    }

    /// Call right before the buffer for a frame is committed (vkQueuePresentKHR): asks for
    /// the next frame callback and for presentation feedback tagged `tag`.
    pub fn beforePresent(self: *Window, tag: u64) void {
        self.frame_ready = false;
        if (self.frame_callback) |cb| cb.destroy();
        self.frame_callback = self.surface.frame() catch null;
        if (self.frame_callback) |cb| cb.setListener(*Window, onFrame, self) else self.frame_ready = true;
        if (self.presentation) |p| {
            for (&self.feedback) |*slot| {
                if (slot.used) continue;
                const fb = p.feedback(self.surface) catch break;
                slot.used = true;
                slot.tag = tag;
                fb.setListener(*FeedbackSlot, onFeedback, slot);
                break;
            }
        }
    }

    // ------------------------------------------------------------------ listeners

    fn onRegistry(registry: *wl.Registry, event: wl.Registry.Event, self: *Window) void {
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, std.mem.span(wl.Compositor.interface.name))) {
                    self.compositor = registry.bind(g.name, wl.Compositor, @min(g.version, 4)) catch null;
                } else if (std.mem.eql(u8, name, std.mem.span(xdg.WmBase.interface.name))) {
                    self.wm_base = registry.bind(g.name, xdg.WmBase, @min(g.version, 2)) catch null;
                } else if (std.mem.eql(u8, name, std.mem.span(wl.Seat.interface.name))) {
                    if (self.seat == null) self.seat = registry.bind(g.name, wl.Seat, @min(g.version, 5)) catch null;
                } else if (std.mem.eql(u8, name, std.mem.span(wp.Presentation.interface.name))) {
                    self.presentation = registry.bind(g.name, wp.Presentation, 1) catch null;
                } else if (std.mem.eql(u8, name, std.mem.span(zwp.PointerGesturesV1.interface.name))) {
                    self.gestures = registry.bind(g.name, zwp.PointerGesturesV1, 1) catch null;
                }
            },
            .global_remove => {},
        }
    }

    fn onWmBase(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *Window) void {
        switch (event) {
            .ping => |p| wm_base.pong(p.serial),
        }
    }

    fn onXdgSurface(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, self: *Window) void {
        switch (event) {
            .configure => |c| {
                xdg_surface.ackConfigure(c.serial);
                self.configured = true;
            },
        }
    }

    fn onToplevel(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Window) void {
        switch (event) {
            .configure => |c| {
                // 0 means "you choose": keep what we have.
                const w: u32 = if (c.width > 0) @intCast(c.width) else self.width;
                const h: u32 = if (c.height > 0) @intCast(c.height) else self.height;
                if (w != self.width or h != self.height) {
                    self.width = w;
                    self.height = h;
                    self.resized = true;
                }
            },
            .close => self.closed = true,
        }
    }

    fn onFrame(cb: *wl.Callback, event: wl.Callback.Event, self: *Window) void {
        switch (event) {
            .done => {
                cb.destroy();
                self.frame_callback = null;
                self.frame_ready = true;
            },
        }
    }

    fn onPresentation(_: *wp.Presentation, event: wp.Presentation.Event, self: *Window) void {
        switch (event) {
            .clock_id => |c| self.presentation_clock = c.clk_id,
        }
    }

    fn onFeedback(fb: *wp.PresentationFeedback, event: wp.PresentationFeedback.Event, slot: *FeedbackSlot) void {
        const self = slot.window;
        switch (event) {
            .sync_output => return,
            .presented => |p| {
                if (self.num_presented < self.presented.len) {
                    const sec: i128 = (@as(i128, p.tv_sec_hi) << 32) | p.tv_sec_lo;
                    self.presented[self.num_presented] = .{ .tag = slot.tag, .time_ns = sec * 1_000_000_000 + p.tv_nsec, .refresh_ns = p.refresh };
                    self.num_presented += 1;
                }
            },
            .discarded => self.discarded += 1,
        }
        slot.used = false;
        fb.destroy();
    }

    fn onSeat(seat: *wl.Seat, event: wl.Seat.Event, self: *Window) void {
        switch (event) {
            .capabilities => |c| {
                if (c.capabilities.pointer and self.pointer == null) {
                    self.pointer = seat.getPointer() catch null;
                    if (self.pointer) |p| {
                        p.setListener(*Window, onPointer, self);
                        if (self.gestures) |g| {
                            self.pinch = g.getPinchGesture(p) catch null;
                            if (self.pinch) |pinch| pinch.setListener(*Window, onPinch, self);
                        }
                    }
                }
                if (c.capabilities.keyboard and self.keyboard == null) {
                    self.keyboard = seat.getKeyboard() catch null;
                    if (self.keyboard) |k| k.setListener(*Window, onKeyboard, self);
                }
            },
            .name => {},
        }
    }

    fn onPointer(_: *wl.Pointer, event: wl.Pointer.Event, self: *Window) void {
        switch (event) {
            .enter => |e| {
                self.input.pointer_x = e.surface_x.toDouble();
                self.input.pointer_y = e.surface_y.toDouble();
            },
            .motion => |m| {
                self.input.pointer_x = m.surface_x.toDouble();
                self.input.pointer_y = m.surface_y.toDouble();
            },
            .axis => |a| switch (a.axis) {
                .vertical_scroll => self.input.scroll_y += a.value.toDouble(),
                .horizontal_scroll => self.input.scroll_x += a.value.toDouble(),
                else => {},
            },
            else => {},
        }
    }

    fn onPinch(_: *zwp.PointerGesturePinchV1, event: zwp.PointerGesturePinchV1.Event, self: *Window) void {
        switch (event) {
            .begin => self.pinch_last = 1,
            .update => |u| {
                // `scale` is relative to the start of the gesture; accumulate the change.
                const s = u.scale.toDouble();
                if (s > 0 and self.pinch_last > 0) self.input.pinch *= s / self.pinch_last;
                self.pinch_last = s;
            },
            .end => {},
        }
    }

    fn onKeyboard(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Window) void {
        switch (event) {
            .keymap => |k| _ = linux.close(k.fd),
            .key => |k| {
                if (k.state == .pressed and self.input.num_keys < self.input.keys.len) {
                    self.input.keys[self.input.num_keys] = @enumFromInt(k.key);
                    self.input.num_keys += 1;
                }
            },
            .modifiers => |m| {
                // Standard xkb modifier bits: Shift = 1, Control = 4.
                self.input.shift = (m.mods_depressed & 1) != 0;
                self.input.ctrl = (m.mods_depressed & 4) != 0;
            },
            else => {},
        }
    }
};
