//! What the display and the spike-tile window tell each other. They are two threads with
//! no lock between them: each publishes a small value the other reads when it likes, and
//! what the user asks for in the tile window goes to the display through a queue.
//!
//!   display -> tiles   `Config`: the channels listened to, the channel in focus, the
//!                      panels' common average references (for the detection).
//!   tiles -> display   `Request`: focus this channel, clear the focus, listen to this
//!                      channel. The display decides and publishes the result in `Config`:
//!                      the tile window never changes focus or listening by itself, so
//!                      the two windows cannot disagree.
//!   tiles -> display   `Report`: the detection threshold of the channel in focus (the
//!                      detector runs in the tile window's thread), and the tile window's
//!                      view (port shown, tile ranges), which the display thread saves
//!                      with "Save view".
//!
//! Focus and listening are different things. Focus (one channel, or none) says which
//! channel is being looked at: its tile has an amber frame, and its trace on the display
//! shows the detection threshold. Listening (up to `audio.max_channels`) says which
//! channels are in the sound; it is marked with a note.

const std = @import("std");
const oez = @import("oez");
const Atomic = std.atomic.Value;
pub const TileView = oez.tile_view.TileView;

pub const Config = struct {
    listening: [oez.audio.max_channels]u32 = @splat(0),
    num_listening: usize = 0,
    /// The channel in focus, if any.
    focus: ?u32 = null,
    /// The panels' common average references, for the detection.
    car: oez.spikes.Car = .{},
    use_car: bool = false,
};

pub const Request = union(enum) {
    focus: u32,
    unfocus,
    /// `add`: add the channel to what is listened to, or take it out (Ctrl); else listen
    /// to it alone.
    listen: struct { channel: u32, add: bool },
};

pub const Report = struct {
    /// The detection threshold of `threshold_channel`, in µV (negative), when
    /// `threshold_valid`; the display draws it on the focused channel's trace.
    threshold_channel: u32 = 0,
    threshold_uv: f32 = 0,
    threshold_valid: bool = false,
    view: TileView = .{},
};

pub const Shared = struct {
    cfg: oez.published.Published(Config) = .{},
    report: oez.published.Published(Report) = .{},
    requests: oez.events.Spsc(Request, 32) = .{},
    /// The view the tile window starts with: set by the display thread before the tile
    /// window's thread is started (from the view file, or what was last reported), and
    /// read by that thread once.
    initial_view: TileView = .{},
    stop: Atomic(bool) = .init(false),

    /// Display thread.
    pub fn publish(self: *Shared, cfg: *const Config) void {
        self.cfg.publish(cfg);
    }

    /// Tile thread.
    pub fn read(self: *Shared, out: *Config, seen: *u32) void {
        _ = self.cfg.read(out, seen);
    }
};
