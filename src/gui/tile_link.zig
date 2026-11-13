//! What the display and the spike-tile window tell each other. They are two threads with
//! no lock between them: each publishes a small value the other reads when it likes, and
//! what the user asks for in the tile window goes to the display through a queue.
//!
//!   display -> tiles   `Config`: the channels listened to, the channel in focus, the
//!                      panels' common average references and every channel's threshold
//!                      (for the detection).
//!   tiles -> display   `Request`: focus this channel, clear the focus, listen to this
//!                      channel, set its threshold. The display decides and publishes the
//!                      result in `Config`: the tile window never changes focus, listening
//!                      or a threshold by itself, so the two windows cannot disagree.
//!   tiles -> display   `Report`: every electrode's detection threshold in use, in µV (the
//!                      detector runs in the tile window's thread, and only it knows the
//!                      noise that a threshold following the noise is set from), and the
//!                      tile window's view (port shown, tile ranges), which the display
//!                      thread saves with "Save view".
//!
//! Focus and listening are different things. Focus (one channel, or none) says which
//! channel is being looked at: its tile has an amber frame, and its trace on the display
//! shows its detection threshold. Listening (up to `audio.max_channels`) says which
//! channels are in the sound; it is marked with a note.

const std = @import("std");
const oez = @import("oez");
const Atomic = std.atomic.Value;
pub const TileView = oez.tile_view.TileView;
pub const Thresholds = oez.thresholds.Thresholds;

pub const Config = struct {
    listening: [oez.audio.max_channels]u32 = @splat(0),
    num_listening: usize = 0,
    /// The channel in focus, if any.
    focus: ?u32 = null,
    /// The panels' common average references, for the detection.
    car: oez.spikes.Car = .{},
    use_car: bool = false,
    /// Every channel's threshold: what the detector uses.
    thresholds: Thresholds = .{},
};

pub const Request = union(enum) {
    focus: u32,
    unfocus,
    /// `add`: add the channel to what is listened to, or take it out (Ctrl); else listen
    /// to it alone.
    listen: struct { channel: u32, add: bool },
    /// Fix the channel's threshold at `uv` µV (its sign the slope); 0: back to the noise.
    threshold: struct { channel: u32, uv: f32 },
};

pub const Report = struct {
    /// Every electrode's threshold in use, µV (the first `len` are valid): the display
    /// draws the focused channel's on its trace, and latches a slope trigger's.
    thresholds: oez.thresholds.Reported = .{},
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
