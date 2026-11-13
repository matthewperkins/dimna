//! The vertical scales of the spike tiles, with an undo history.
//!
//! A tile's range is the µV from zero to the tile's edge; 0 means the tile scales itself
//! to its own waveforms ("auto"), as every tile does at start. What a tile's auto range is
//! (from its noise and its waveforms) is the caller's business: it is passed in, as are
//! the times, so every rule here can be tested without a window, a detector or a clock.
//!
//! - The wheel scales the tiles of a selection (the tiles shown) by `per_click` per wheel
//!   click. If none of them has a fixed range yet, they first all take one common range,
//!   the largest of their auto ranges, which is remembered as the selection's initial
//!   common range and pushed onto the history.
//! - Ctrl+wheel does the same to one tile alone (an auto tile takes its auto range first).
//! - A wheel change is pushed once the wheel has been still for `settle_ms`.
//! - `undo` and `redo` step through the history (at most `max_entries` entries, whole sets
//!   of ranges); `toCommon` (r) and `fixAuto` (a) push at once.
//! - Ranges are kept within `min_uv` to `max_uv`.

const std = @import("std");
const tile_view = @import("tile_view.zig");

pub const max_tiles = tile_view.max_tiles;
/// How long the wheel must be still before its change becomes a history entry.
pub const settle_ms: i64 = 750;
/// Entries kept in the history; the oldest is dropped.
pub const max_entries = 16;
/// The factor on a range per wheel click.
pub const per_click = 1.05;
/// Wheel axis units per click (what the compositor reports for one click of a wheel).
pub const axis_per_click = 15.0;
/// The span a fixed range is kept in: 1 µV to 10 mV.
pub const min_uv: f32 = 1;
pub const max_uv: f32 = 10_000;
/// Selections with an initial common range of their own: the four ports, and all tiles.
pub const max_groups = 5;

pub const Ranges = [max_tiles]f32;

/// The ranges of a selection at a glance.
pub const Summary = union(enum) {
    /// Every tile scales itself.
    auto,
    /// Every tile has this fixed range.
    common: f32,
    mixed,
};

pub const Scale = struct {
    /// Tiles in use (the first `n` of `ranges`).
    n: usize = 0,
    /// The ranges now, in µV; 0 = auto.
    ranges: Ranges = @splat(0),
    /// Each selection group's initial common range; 0 = none yet.
    common: [max_groups]f32 = @splat(0),
    entries: [max_entries]Ranges = undefined,
    /// Entries held, and the one the ranges were last set from.
    len: usize = 0,
    at: usize = 0,
    /// A wheel change not yet pushed, and when the wheel last moved.
    pending: bool = false,
    moved_ms: i64 = 0,

    /// `n` tiles with the ranges `start` (0 = auto; missing ones are auto). They are the
    /// first history entry.
    pub fn init(self: *Scale, n: usize, start: []const f32) void {
        self.* = .{ .n = @min(n, max_tiles) };
        for (self.ranges[0..self.n], 0..) |*r, i| {
            const v = if (i < start.len) start[i] else 0;
            r.* = if (v > 0) clamp(v) else 0;
        }
        self.push();
    }

    pub fn clamp(v: f32) f32 {
        return std.math.clamp(v, min_uv, max_uv);
    }

    /// The factor `axis` units of wheel make (fractions of a click scale accordingly).
    pub fn factor(axis: f64) f64 {
        return std.math.pow(f64, per_click, axis / axis_per_click);
    }

    fn push(self: *Scale) void {
        self.pending = false;
        if (self.len > 0 and std.mem.eql(f32, &self.entries[self.at], &self.ranges)) return;
        // A push after an undo drops the entries that were undone.
        var next: usize = if (self.len == 0) 0 else self.at + 1;
        if (next == max_entries) {
            std.mem.copyForwards(Ranges, self.entries[0 .. max_entries - 1], self.entries[1..max_entries]);
            next -= 1;
        }
        self.entries[next] = self.ranges;
        self.len = next + 1;
        self.at = next;
    }

    fn flush(self: *Scale) void {
        if (self.pending) self.push();
    }

    fn allAuto(self: *const Scale, sel: []const u32) bool {
        for (sel) |i| {
            if (i < self.n and self.ranges[i] != 0) return false;
        }
        return true;
    }

    /// Sets the selection's initial common range from its tiles' auto ranges now.
    fn makeCommon(self: *Scale, sel: []const u32, group: usize, auto: []const f32) void {
        var largest: f32 = 0;
        for (sel) |i| {
            if (i < self.n) largest = @max(largest, auto[i]);
        }
        if (sel.len > 0) self.common[group] = clamp(largest);
    }

    fn scaleTile(self: *Scale, i: usize, auto_uv: f32, f: f64) void {
        if (self.ranges[i] == 0) self.ranges[i] = clamp(auto_uv);
        self.ranges[i] = clamp(@floatCast(@as(f64, self.ranges[i]) * f));
    }

    /// The wheel, `axis` units, over the tiles `sel` (indices; `group` names the
    /// selection, below `max_groups`). `auto` holds every tile's auto range in µV.
    pub fn wheel(self: *Scale, sel: []const u32, group: usize, auto: []const f32, axis: f64, now_ms: i64) void {
        if (axis == 0 or sel.len == 0) return;
        if (self.allAuto(sel)) {
            self.flush();
            self.makeCommon(sel, group, auto);
            for (sel) |i| {
                if (i < self.n) self.ranges[i] = self.common[group];
            }
            self.push();
        }
        const f = factor(axis);
        for (sel) |i| {
            if (i < self.n) self.scaleTile(i, auto[i], f);
        }
        self.pending = true;
        self.moved_ms = now_ms;
    }

    /// Ctrl+wheel over tile `i`, whose auto range is `auto_uv`.
    pub fn wheelOne(self: *Scale, i: usize, auto_uv: f32, axis: f64, now_ms: i64) void {
        if (axis == 0 or i >= self.n) return;
        self.scaleTile(i, auto_uv, factor(axis));
        self.pending = true;
        self.moved_ms = now_ms;
    }

    /// Pushes a wheel change once the wheel has been still for `settle_ms`. True if it did.
    pub fn tick(self: *Scale, now_ms: i64) bool {
        if (!self.pending or now_ms - self.moved_ms < settle_ms) return false;
        self.push();
        return true;
    }

    /// `u`: back one entry (a wheel change still waiting is pushed first, so this takes it
    /// back). True if the ranges changed.
    pub fn undo(self: *Scale) bool {
        self.flush();
        if (self.at == 0) return false;
        self.at -= 1;
        self.ranges = self.entries[self.at];
        return true;
    }

    /// Shift+`u`: forward one entry. True if the ranges changed.
    pub fn redo(self: *Scale) bool {
        self.flush();
        if (self.at + 1 >= self.len) return false;
        self.at += 1;
        self.ranges = self.entries[self.at];
        return true;
    }

    /// `r`: the selection to its initial common range (made now from the auto ranges, as
    /// the wheel would, if there is none yet), and push.
    pub fn toCommon(self: *Scale, sel: []const u32, group: usize, auto: []const f32) void {
        if (sel.len == 0) return;
        self.flush();
        if (self.common[group] == 0) self.makeCommon(sel, group, auto);
        for (sel) |i| {
            if (i < self.n) self.ranges[i] = self.common[group];
        }
        self.push();
    }

    /// `a`: every tile of the selection to its auto range now, as a fixed number, and push.
    pub fn fixAuto(self: *Scale, sel: []const u32, auto: []const f32) void {
        if (sel.len == 0) return;
        self.flush();
        for (sel) |i| {
            if (i < self.n) self.ranges[i] = clamp(auto[i]);
        }
        self.push();
    }

    pub fn summary(self: *const Scale, sel: []const u32) Summary {
        var first: ?f32 = null;
        for (sel) |i| {
            if (i >= self.n) continue;
            const r = self.ranges[i];
            if (first == null) first = r else if (first.? != r) return .mixed;
        }
        const r = first orelse return .auto;
        return if (r == 0) .auto else .{ .common = r };
    }
};

// ---- Tests ----

const testing = std.testing;

/// Every tile of `n`, as a selection.
fn everyTile(comptime n: usize) [n]u32 {
    var s: [n]u32 = undefined;
    for (&s, 0..) |*v, i| v.* = @intCast(i);
    return s;
}

const all4 = everyTile(4);
const auto4 = [_]f32{ 80, 120, 95, 60 };

fn fresh(s: *Scale) void {
    s.init(4, &.{});
}

test "at start every tile is auto, and that is the first entry" {
    var s: Scale = undefined;
    fresh(&s);
    try testing.expectEqual(1, s.len);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, s.ranges[0..4]);
    try testing.expectEqual(Summary.auto, s.summary(&all4));
    // Undo and redo at the only entry do nothing.
    try testing.expect(!s.undo());
    try testing.expect(!s.redo());
    // From a saved view: its ranges (clamped), 0 still auto, missing ones auto.
    s.init(4, &.{ 150, 0, 0.2 });
    try testing.expectEqualSlices(f32, &.{ 150, 0, 1, 0 }, s.ranges[0..4]);
    try testing.expectEqualSlices(f32, s.ranges[0..4], s.entries[0][0..4]);
}

test "the first wheel from all auto takes the largest auto range, pushes it, then scales" {
    var s: Scale = undefined;
    fresh(&s);
    s.wheel(&all4, 4, &auto4, 15, 1000);
    try testing.expectEqual(120, s.common[4]);
    // The common state was pushed before the scaling.
    try testing.expectEqual(2, s.len);
    try testing.expectEqual(1, s.at);
    try testing.expectEqualSlices(f32, &.{ 120, 120, 120, 120 }, s.entries[1][0..4]);
    for (s.ranges[0..4]) |r| try testing.expectApproxEqRel(@as(f32, 126), r, 1e-6);
    try testing.expect(s.pending);
    try testing.expectEqual(Summary{ .common = s.ranges[0] }, s.summary(&all4));
}

test "five percent per click compounds, and fractions of a click scale accordingly" {
    var s: Scale = undefined;
    fresh(&s);
    // Ten clicks the other way first: the common range is made and pushed, then scaled.
    for (0..10) |_| s.wheel(&all4, 4, &auto4, -15, 0);
    try testing.expectApproxEqRel(@as(f32, 120.0 / std.math.pow(f32, 1.05, 10)), s.ranges[0], 1e-5);
    for (0..10) |_| s.wheel(&all4, 4, &auto4, 15, 0);
    for (s.ranges[0..4]) |r| try testing.expectApproxEqRel(@as(f32, 120), r, 1e-5);
    // Half a click (a touchpad) is the square root of a click's factor.
    try testing.expectApproxEqRel(@sqrt(1.05), Scale.factor(7.5), 1e-12);
    try testing.expectApproxEqRel(1.05 * 1.05 * 1.05, Scale.factor(45), 1e-12);
    // No movement, no change and nothing pending.
    var t: Scale = undefined;
    fresh(&t);
    t.wheel(&all4, 4, &auto4, 0, 0);
    try testing.expect(!t.pending);
    try testing.expectEqual(1, t.len);
}

test "a wheel change is pushed once the wheel has been still for settle_ms" {
    var s: Scale = undefined;
    fresh(&s);
    s.wheel(&all4, 4, &auto4, 15, 1000);
    const after_common = s.len;
    try testing.expect(!s.tick(1000));
    try testing.expect(!s.tick(1000 + settle_ms - 1));
    try testing.expectEqual(after_common, s.len);
    try testing.expect(s.tick(1000 + settle_ms));
    try testing.expectEqual(after_common + 1, s.len);
    try testing.expect(!s.tick(5000)); // nothing more to push
    // Further movement postpones it.
    s.wheel(&all4, 4, &auto4, 15, 6000);
    s.wheel(&all4, 4, &auto4, 15, 6500);
    try testing.expect(!s.tick(6000 + settle_ms));
    try testing.expect(!s.tick(6500 + settle_ms - 1));
    try testing.expect(s.tick(6500 + settle_ms));
    // One entry for the whole gesture.
    try testing.expectEqual(after_common + 2, s.len);
}

test "u and Shift+u step back and forward, and do nothing at either end" {
    var s: Scale = undefined;
    fresh(&s);
    s.fixAuto(&all4, &auto4); // entry 1
    s.toCommon(&all4, 4, &auto4); // entry 2: 120 everywhere
    try testing.expectEqual(3, s.len);
    try testing.expect(!s.redo()); // at the newest
    try testing.expect(s.undo());
    try testing.expectEqualSlices(f32, &auto4, s.ranges[0..4]);
    try testing.expect(s.undo());
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, s.ranges[0..4]);
    try testing.expect(!s.undo()); // at the oldest
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, s.ranges[0..4]);
    try testing.expect(s.redo());
    try testing.expect(s.redo());
    try testing.expectEqualSlices(f32, &.{ 120, 120, 120, 120 }, s.ranges[0..4]);
    try testing.expect(!s.redo());
}

test "a push after an undo drops the entries that were undone" {
    var s: Scale = undefined;
    fresh(&s);
    s.fixAuto(&all4, &auto4);
    s.toCommon(&all4, 4, &auto4);
    try testing.expect(s.undo());
    try testing.expect(s.undo());
    // At the first entry: a new push replaces both undone entries.
    s.wheelOne(2, 95, 15, 0);
    try testing.expect(s.tick(settle_ms));
    try testing.expectEqual(2, s.len);
    try testing.expect(!s.redo());
    try testing.expectEqualSlices(f32, &.{ 0, 0, 95 * 1.05, 0 }, s.ranges[0..4]);
}

test "the 17th entry drops the first" {
    var s: Scale = undefined;
    fresh(&s);
    // Fifteen pushes after the first entry fill the history.
    for (1..max_entries) |k| {
        s.wheelOne(0, 50, 15, @intCast(k * 1000));
        try testing.expect(s.tick(@intCast(k * 1000 + settle_ms)));
    }
    try testing.expectEqual(max_entries, s.len);
    try testing.expectEqual(0, s.entries[0][0]); // the start: auto
    s.wheelOne(0, 50, 15, 100_000);
    try testing.expect(s.tick(100_000 + settle_ms));
    try testing.expectEqual(max_entries, s.len);
    // The oldest is now the first wheel step, not the all-auto start.
    try testing.expectApproxEqRel(@as(f32, 50 * 1.05), s.entries[0][0], 1e-6);
    var undone: usize = 0;
    while (s.undo()) undone += 1;
    try testing.expectEqual(max_entries - 1, undone);
    try testing.expectApproxEqRel(@as(f32, 50 * 1.05), s.ranges[0], 1e-6);
}

test "r before any wheel makes the common range as the wheel would, and pushes" {
    var s: Scale = undefined;
    fresh(&s);
    s.toCommon(&all4, 4, &auto4);
    try testing.expectEqual(120, s.common[4]);
    try testing.expectEqualSlices(f32, &.{ 120, 120, 120, 120 }, s.ranges[0..4]);
    try testing.expectEqual(2, s.len);
    try testing.expect(!s.pending);
    // After the wheel and Ctrl+wheel, r goes back to that same common range.
    s.wheel(&all4, 4, &.{ 500, 500, 500, 500 }, 60, 0);
    s.wheelOne(1, 500, -30, 10);
    s.toCommon(&all4, 4, &.{ 500, 500, 500, 500 });
    try testing.expectEqualSlices(f32, &.{ 120, 120, 120, 120 }, s.ranges[0..4]);
    // The wheel change waiting was pushed first: undo goes to it, not past it.
    try testing.expect(s.undo());
    try testing.expect(s.ranges[0] != 120 and s.ranges[1] != s.ranges[0]);
}

test "a gives fixed numbers, which later auto ranges do not move; undoing to the start does" {
    var s: Scale = undefined;
    fresh(&s);
    s.fixAuto(&all4, &.{ 80, 0.1, 95, 60000 });
    // Fixed and clamped, not auto (0).
    try testing.expectEqualSlices(f32, &.{ 80, min_uv, 95, max_uv }, s.ranges[0..4]);
    try testing.expectEqual(2, s.len);
    try testing.expectEqual(Summary.mixed, s.summary(&all4));
    // A wheel now scales those fixed numbers; the auto ranges it is given do not matter.
    s.wheel(&all4, 4, &.{ 1, 1, 1, 1 }, 15, 0);
    try testing.expectApproxEqRel(@as(f32, 84), s.ranges[0], 1e-6);
    try testing.expectEqual(0, s.common[4]); // not all auto: no common range was made
    try testing.expect(s.undo());
    try testing.expect(s.undo());
    try testing.expectEqual(Summary.auto, s.summary(&all4));
}

test "Ctrl+wheel on an auto tile takes its auto range first; the others are untouched" {
    var s: Scale = undefined;
    fresh(&s);
    s.wheelOne(1, 120, 15, 0);
    try testing.expectEqualSlices(f32, &.{ 0, 120 * 1.05, 0, 0 }, s.ranges[0..4]);
    // Nothing pushed until the wheel settles; no common range made.
    try testing.expectEqual(1, s.len);
    try testing.expectEqual(0, s.common[4]);
    s.wheelOne(9, 120, 15, 0); // no such tile
    try testing.expectEqual(4, s.n);
}

test "undo with a wheel change waiting takes back that change" {
    var s: Scale = undefined;
    fresh(&s);
    s.toCommon(&all4, 4, &auto4); // entry 1: 120
    s.wheel(&all4, 4, &auto4, 15, 0); // waiting: 126
    try testing.expect(s.undo());
    try testing.expectEqualSlices(f32, &.{ 120, 120, 120, 120 }, s.ranges[0..4]);
    try testing.expect(!s.pending);
    // ... and it can be redone.
    try testing.expect(s.redo());
    try testing.expectApproxEqRel(@as(f32, 126), s.ranges[0], 1e-6);
}

test "the wheel on a mixed state: an auto tile takes its auto range first" {
    var s: Scale = undefined;
    fresh(&s);
    s.wheelOne(0, 100, 15, 0);
    try testing.expect(s.tick(settle_ms));
    s.wheel(&all4, 4, &auto4, -15, 1000);
    try testing.expectApproxEqRel(@as(f32, 100), s.ranges[0], 1e-6);
    try testing.expectApproxEqRel(@as(f32, 120.0 / 1.05), s.ranges[1], 1e-6);
    try testing.expectApproxEqRel(@as(f32, 95.0 / 1.05), s.ranges[2], 1e-6);
    try testing.expectEqual(0, s.common[4]);
}

test "ranges are kept between 1 µV and 10 mV" {
    var s: Scale = undefined;
    fresh(&s);
    s.wheel(&all4, 4, &auto4, 15 * 200, 0);
    for (s.ranges[0..4]) |r| try testing.expectEqual(max_uv, r);
    s.wheel(&all4, 4, &auto4, -15 * 400, 0);
    for (s.ranges[0..4]) |r| try testing.expectEqual(min_uv, r);
    // A tile's auto range below 1 µV (a flat channel) is clamped when it is taken, before
    // it is scaled: fifteen clicks from 1 µV, not from 0.195 µV.
    fresh(&s);
    s.wheelOne(3, 0.195, 15 * 15, 0);
    try testing.expectApproxEqRel(std.math.pow(f32, 1.05, 15), s.ranges[3], 1e-5);
}

test "a selection: only its tiles change, and it has its own common range" {
    var s: Scale = undefined;
    fresh(&s);
    const a = [_]u32{ 0, 1 };
    const b = [_]u32{ 2, 3 };
    s.wheel(&a, 0, &auto4, 15, 0);
    try testing.expectEqual(120, s.common[0]);
    try testing.expectEqualSlices(f32, &.{ 0, 0 }, s.ranges[2..4]);
    try testing.expectEqual(Summary.auto, s.summary(&b));
    try testing.expectEqual(Summary.mixed, s.summary(&all4));
    // The other selection's first wheel finds its own tiles all auto: its own largest.
    s.wheel(&b, 1, &auto4, 15, 0);
    try testing.expectEqual(95, s.common[1]);
    try testing.expectEqual(120, s.common[0]);
    s.toCommon(&b, 1, &auto4);
    try testing.expectEqualSlices(f32, &.{ 95, 95 }, s.ranges[2..4]);
    try testing.expectApproxEqRel(@as(f32, 126), s.ranges[0], 1e-6);
    // An empty selection (a port without tiles) changes nothing.
    const len = s.len;
    s.wheel(&.{}, 2, &auto4, 15, 0);
    s.toCommon(&.{}, 2, &auto4);
    s.fixAuto(&.{}, &auto4);
    try testing.expectEqual(len, s.len);
    try testing.expectEqual(Summary.auto, s.summary(&.{}));
}

test "a push that changes nothing adds no entry" {
    var s: Scale = undefined;
    fresh(&s);
    s.fixAuto(&all4, &auto4);
    s.fixAuto(&all4, &auto4);
    try testing.expectEqual(2, s.len);
}
