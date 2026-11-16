//! The one monotonic clock of the GUI's threads.
//!
//! `CLOCK_MONOTONIC`, the clock `Io.Clock.awake` reads on Linux, so these readings can be
//! compared with `Block.acquired_ns` (stamped by the acquisition thread through `Io`).
//! Latency figures are differences between the two; they must stay on the same clock.

const std = @import("std");
const os = @import("os.zig");

/// Nanoseconds on the monotonic clock. Needs no `Io`, so any thread can call it.
pub fn nowNs() i128 {
    return os.nowNs();
}

test "the same clock as Io.Clock.awake, and it does not go back" {
    const io = std.testing.io;
    const a = std.Io.Clock.awake.now(io).nanoseconds;
    const b = nowNs();
    const c = std.Io.Clock.awake.now(io).nanoseconds;
    try std.testing.expect(a <= b and b <= c);
    try std.testing.expect(nowNs() >= b);
}
