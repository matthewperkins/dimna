//! What the acquisition thread reads from: the real board or the simulator.

const std = @import("std");
const types = @import("types.zig");
const Board = @import("board.zig").Board;
const Sim = @import("sim.zig").Sim;

pub const Source = union(enum) {
    board: *Board,
    sim: *Sim,

    pub fn start(self: Source, health: *types.Health) !void {
        switch (self) {
            .board => |b| try b.start(health),
            .sim => |s| s.start(health),
        }
    }
    pub fn stop(self: Source) !void {
        switch (self) {
            .board => |b| try b.stop(),
            .sim => |s| s.stop(),
        }
    }
    /// After acquisition ended on a read error and the source was stopped: opened again as
    /// at launch, with `new` settings, ready to `start` (see `Board.reopen`).
    /// `error.BoardAbsent`: no board on the bus; it can only be waited for.
    pub fn reopen(self: Source, new: types.Settings) !void {
        switch (self) {
            .board => |b| try b.reopen(new),
            .sim => |s| try s.reopen(new),
        }
    }
    pub fn readBlock(self: Source, blk: *types.Block) !void {
        switch (self) {
            .board => |b| try b.readBlock(blk),
            .sim => |s| try s.readBlock(blk),
        }
    }
    pub fn live(self: Source, cmd: types.LiveCommand) !void {
        switch (self) {
            .board => |b| try b.live(cmd),
            .sim => |s| try s.live(cmd),
        }
    }
    /// Gap-free amplifier change. The simulator keeps it in its settings, as the board does,
    /// and reports what was asked for.
    pub fn setAmpLive(self: Source, a: Board.AmpSettings, now_ns: i96) !Board.AmpActual {
        return switch (self) {
            .board => |b| try b.setAmpLive(a),
            .sim => |s| sim: {
                try s.setAmpLive(a);
                break :sim .{
                    .lower = a.lower_bandwidth,
                    .upper = a.upper_bandwidth,
                    .dsp_cutoff = a.dsp_cutoff,
                    .switched_ns = now_ns,
                    .writes_before_switch = 0,
                };
            },
        };
    }
    pub fn settings(self: Source) types.Settings {
        return switch (self) {
            .board => |b| b.settings,
            .sim => |s| s.settings,
        };
    }
    pub fn sampleRate(self: Source) f64 {
        return switch (self) {
            .board => |b| b.sample_rate,
            .sim => |s| s.sample_rate,
        };
    }
    pub fn layout(self: Source) types.Layout {
        return switch (self) {
            .board => |b| b.layout(),
            .sim => |s| s.layout(),
        };
    }
    /// Only the real board's thread asks for real-time priority.
    pub fn wantsRealtime(self: Source) bool {
        return self == .board;
    }
};
