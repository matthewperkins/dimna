//! The acquisition thread: owns the board while running, reads blocks straight into a ring
//! slot and commits them. It never waits on a consumer. If the ring is full the block is read
//! into a scratch block and counted as `ring_overflow` (data lost to the pipeline, loudly);
//! the board keeps being drained so its DRAM buffer never fills.

const std = @import("std");
const types = @import("types.zig");
const Board = @import("board.zig").Board;
const BlockRing = @import("ring.zig").BlockRing;
const LiveCommand = types.LiveCommand;
const Atomic = std.atomic.Value;
const linux = std.os.linux;
const log = std.log.scoped(.acquisition);

pub const Acquisition = struct {
    io: std.Io,
    board: *Board,
    ring: *BlockRing,
    health: *types.Health,
    scratch: types.Block,
    stop_flag: Atomic(bool) = .init(false),
    /// True once the thread has exited (normally or on an error).
    done: Atomic(bool) = .init(false),
    /// Blocks the ring could not take.
    ring_overflow: Atomic(u64) = .init(0),
    /// Set when the thread got SCHED_FIFO.
    realtime: Atomic(bool) = .init(false),
    failure: ?anyerror = null,
    thread: ?std.Thread = null,

    /// Starts the board and the thread. `self` must stay at a fixed address until `join`.
    pub fn start(self: *Acquisition) !void {
        try self.board.start(self.health);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |e| {
            self.board.stop() catch {};
            return e;
        };
        self.thread.?.setName(self.io, "acquisition") catch {};
    }

    /// Asks the thread to stop, waits for it, then stops the board.
    pub fn join(self: *Acquisition) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        self.board.stop() catch |e| log.warn("board stop failed: {t}", .{e});
    }

    fn run(self: *Acquisition) void {
        self.realtime.store(setRealtime(70), .release);
        defer self.done.store(true, .release);
        while (!self.stop_flag.load(.acquire)) {
            const slot = self.ring.writeSlot();
            const blk = slot orelse &self.scratch;
            self.board.readBlock(blk) catch |e| {
                self.failure = e;
                log.err("acquisition stopped by a read error: {t}", .{e});
                return;
            };
            blk.acquired_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
            if (slot != null) self.ring.commit() else _ = self.ring_overflow.fetchAdd(1, .monotonic);
        }
    }
};

/// SCHED_FIFO at `priority` for the calling thread. Needs rtprio (e.g. the `realtime` group).
pub fn setRealtime(priority: i32) bool {
    const rc = linux.sched_setscheduler(0, .{ .mode = .FIFO }, &.{ .priority = priority });
    if (linux.errno(rc) != .SUCCESS) {
        log.warn("could not get SCHED_FIFO (errno {t}); running at normal priority", .{linux.errno(rc)});
        return false;
    }
    return true;
}

/// Locks current and future pages in RAM, so acquisition never waits on a page-in.
pub fn lockMemory() bool {
    const rc = linux.mlockall(.{ .CURRENT = true, .FUTURE = true });
    return linux.errno(rc) == .SUCCESS;
}
