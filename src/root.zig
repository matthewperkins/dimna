//! oEZ: acquisition for the Open Ephys acquisition board (ECP5 gateware, FT600 USB 3, ONI).

pub const types = @import("types.zig");
pub const registers = @import("registers.zig");
pub const parser = @import("parser.zig");
pub const oni = @import("oni.zig");
pub const board = @import("board.zig");
pub const ring = @import("ring.zig");
pub const acquisition = @import("acquisition.zig");
pub const sim = @import("sim.zig");
pub const source = @import("source.zig");
pub const record = @import("record.zig");
pub const events = @import("events.zig");
pub const toml = @import("toml.zig");
pub const panels = @import("panels.zig");
pub const dsp = @import("dsp.zig");
pub const feed = @import("feed.zig");
pub const sweeps = @import("sweeps.zig");
pub const slope = @import("slope.zig");
pub const audio = @import("audio.zig");
pub const review = @import("review.zig");
pub const spikes = @import("spikes.zig");
pub const board_config = @import("board_config.zig");
pub const usbfs = @import("usbfs.zig");
pub const ft600 = @import("ft600.zig");
pub const oni_usb = @import("oni_usb.zig");
pub const tile_view = @import("tile_view.zig");
pub const tile_scale = @import("tile_scale.zig");
pub const thresholds = @import("thresholds.zig");
pub const independence_test = @import("independence_test.zig");
pub const published = @import("published.zig");
pub const clock = @import("clock.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("record_test.zig");
}
