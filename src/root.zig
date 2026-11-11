//! oEZ: acquisition for the Open Ephys acquisition board (ECP5 gateware, FT600 USB 3, ONI).

pub const types = @import("types.zig");
pub const registers = @import("registers.zig");
pub const parser = @import("parser.zig");
pub const oni = @import("oni.zig");
pub const board = @import("board.zig");
pub const ring = @import("ring.zig");
pub const acquisition = @import("acquisition.zig");
pub const record = @import("record.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
