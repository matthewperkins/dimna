//! STAND-IN until docs/plans/pyramid-overview.md is merged: the pyramid store filled from
//! the live rows only, no backfill thread. Same interface.

const std = @import("std");
const types = @import("types.zig");
const panels = @import("panels.zig");
const pyramid = @import("pyramid.zig");
const log = std.log.scoped(.overview);

pub const Overview = struct {
    gpa: std.mem.Allocator,
    nch: usize,
    budget: usize,
    store: ?pyramid.Store = null,
    first: i64 = 0,
    file_end: i64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, layout: *const types.Layout, budget_bytes: usize) !Overview {
        _ = io;
        return .{ .gpa = gpa, .nch = layout.numChannels(), .budget = budget_bytes };
    }

    pub fn deinit(self: *Overview) void {
        self.end();
    }

    pub fn begin(self: *Overview, dir: []const u8, first_sample: i64, set: *const panels.Set, width: usize) !void {
        _ = dir;
        _ = set;
        self.end();
        self.store = try pyramid.Store.init(self.gpa, width, self.nch, self.budget);
        self.first = first_sample;
        self.file_end = first_sample;
    }

    pub fn end(self: *Overview) void {
        if (self.store) |*s| s.deinit();
        self.store = null;
    }

    pub fn active(self: *const Overview) bool {
        return self.store != null;
    }

    pub fn add(self: *Overview, first: i64, rows: []const i16, ttl: []const u16) void {
        const s = &(self.store orelse return);
        s.add(first, rows, ttl) catch |err| {
            log.warn("the overview stopped: {t}", .{err});
            self.end();
        };
    }

    pub fn turn(self: *Overview, set: *const panels.Set, width: usize, file_end: i64, want: ?pyramid.Range, hold: bool) void {
        _ = set;
        _ = width;
        _ = want;
        _ = hold;
        self.file_end = file_end;
    }

    pub fn columns(self: *const Overview, lo: i64, hi: i64, cols: usize, history_columns: []const usize, out: []pyramid.Pair) bool {
        const s = &(self.store orelse return false);
        return s.columns(lo, hi, cols, history_columns, out);
    }

    pub fn building(self: *const Overview) bool {
        const s = &(self.store orelse return false);
        var buf: [1]pyramid.Range = undefined;
        return s.holes(.raw, self.first, self.file_end, &buf).len > 0 or s.holes(.slots, self.first, self.file_end, &buf).len > 0;
    }

    pub fn bytes(self: *const Overview) usize {
        return if (self.store) |*s| s.bytes() else 0;
    }
};
