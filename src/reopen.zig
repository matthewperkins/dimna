//! When to open the board again after acquisition ended on a read error, and when to stop
//! trying: the policy and its state, with no I/O of its own (`docs/plans/reopen-after-read-error.md`).
//! The caller does the reopening (`Acquisition.reopenSource`, then `start`) when `due`
//! says so and reports the outcome with `result`; the state is what the alarm shows.
//!
//! - Up to `delays_ms.len` attempts, after each of those delays in turn.
//! - A board that is gone (`error.BoardAbsent`: nothing on the bus) is waited for, looked for
//!   every `absent_poll_ms`, without using up an attempt.
//! - An attempt counts as used when it is made; the count goes back to 0 only once a
//!   restarted run has lasted `stable_ns`.
//!
//! Times are nanoseconds on any one clock that does not go back (the caller's).

const std = @import("std");

pub const Policy = struct {
    /// Before attempt 1, 2, 3 and 4: 3, 10, 20 and 48 s (81 s in all; the owner's choice).
    delays_ms: []const u32 = &.{ 3000, 10_000, 20_000, 48_000 },
    /// While no board is on the bus: how often to look again.
    absent_poll_ms: u32 = 1000,
    /// A restarted run this long gives the attempts back.
    stable_ns: i128 = 60 * std.time.ns_per_s,
};

pub const State = enum {
    /// Acquiring (or never failed).
    running,
    /// Waiting for attempt `attempt + 1`, due at `due_ns`.
    waiting,
    /// No board on the bus; looked for again at `due_ns`.
    absent,
    /// Every attempt failed; acquisition stays stopped until dimna is restarted.
    gave_up,
};

pub const Reopen = struct {
    policy: Policy = .{},
    state: State = .running,
    /// Attempts used in this streak (reset by a stable run).
    attempt: usize = 0,
    due_ns: i128 = 0,
    /// When the present run began (launch, or the last restart).
    run_started_ns: i128,
    /// When acquisition last ended, and on what.
    stopped_ns: i128 = 0,
    read_error: ?anyerror = null,
    /// Why the last attempt failed, if it did.
    attempt_error: ?anyerror = null,
    /// Successful restarts, over the whole run of the program.
    restarts: u64 = 0,
    /// Time not acquired over all restarts (from each read error to its restart), ns.
    down_ns: i128 = 0,

    pub fn init(policy: Policy, now_ns: i128) Reopen {
        return .{ .policy = policy, .run_started_ns = now_ns };
    }

    /// Acquisition has ended on `err` at `now_ns`.
    pub fn ended(self: *Reopen, err: anyerror, now_ns: i128) void {
        std.debug.assert(self.state == .running);
        if (now_ns - self.run_started_ns >= self.policy.stable_ns) self.attempt = 0;
        self.read_error = err;
        self.attempt_error = null;
        self.stopped_ns = now_ns;
        self.schedule(now_ns);
    }

    /// True when the next attempt (or look for an absent board) is due.
    pub fn due(self: *const Reopen, now_ns: i128) bool {
        return (self.state == .waiting or self.state == .absent) and now_ns >= self.due_ns;
    }

    /// The outcome of the attempt made at `now_ns`: success (acquisition running again),
    /// `error.BoardAbsent`, or any other failure.
    pub fn result(self: *Reopen, outcome: anyerror!void, now_ns: i128) void {
        std.debug.assert(self.state == .waiting or self.state == .absent);
        if (outcome) |_| {
            self.attempt += 1;
            self.state = .running;
            self.restarts += 1;
            self.down_ns += now_ns - self.stopped_ns;
            self.run_started_ns = now_ns;
            self.attempt_error = null;
        } else |e| {
            self.attempt_error = e;
            if (e == error.BoardAbsent) {
                // Waited for, not counted.
                self.state = .absent;
                self.due_ns = now_ns + @as(i128, self.policy.absent_poll_ms) * std.time.ns_per_ms;
            } else {
                self.attempt += 1;
                self.schedule(now_ns);
            }
        }
    }

    /// The number of the attempt being waited for (1-based), and how many there are.
    pub fn nextAttempt(self: *const Reopen) struct { n: usize, of: usize } {
        return .{ .n = self.attempt + 1, .of = self.policy.delays_ms.len };
    }

    fn schedule(self: *Reopen, now_ns: i128) void {
        if (self.attempt >= self.policy.delays_ms.len) {
            self.state = .gave_up;
            return;
        }
        self.state = .waiting;
        self.due_ns = now_ns + @as(i128, self.policy.delays_ms[self.attempt]) * std.time.ns_per_ms;
    }
};

const testing = std.testing;
const s: i128 = std.time.ns_per_s;
const ms: i128 = std.time.ns_per_ms;

test "attempts follow the delays, then it gives up" {
    var r: Reopen = .init(.{}, 0);
    r.ended(error.OniFailed, 10 * s);
    try testing.expectEqual(State.waiting, r.state);
    try testing.expect(!r.due(13 * s - 1));
    try testing.expect(r.due(13 * s));
    var now: i128 = 13 * s;
    const delays = [_]i128{ 10_000, 20_000, 48_000 };
    for (delays, 2..) |d, n| {
        r.result(error.OniFailed, now);
        try testing.expectEqual(State.waiting, r.state);
        try testing.expectEqual(n, r.nextAttempt().n);
        try testing.expect(!r.due(now + d * ms - 1));
        now += d * ms;
        try testing.expect(r.due(now));
    }
    // The fourth attempt fails: 81 s after the read error, no attempts left.
    try testing.expectEqual(10 * s + 81 * s, now);
    r.result(error.OniFailed, now);
    try testing.expectEqual(State.gave_up, r.state);
    try testing.expect(!r.due(now + 3600 * s));
    try testing.expectEqual(0, r.restarts);
}

test "a board that is gone is waited for without using up attempts" {
    var r: Reopen = .init(.{}, 0);
    r.ended(error.OniFailed, 0);
    var now: i128 = 3 * s;
    // An hour of no board on the bus: looked for every second, never given up.
    for (0..3600) |_| {
        try testing.expect(r.due(now));
        r.result(error.BoardAbsent, now);
        try testing.expectEqual(State.absent, r.state);
        try testing.expect(!r.due(now + 999 * ms));
        now += 1000 * ms;
    }
    try testing.expectEqual(1, r.nextAttempt().n);
    // It comes back: the attempt succeeds.
    r.result({}, now);
    try testing.expectEqual(State.running, r.state);
    try testing.expectEqual(1, r.restarts);
    try testing.expectEqual(now, r.down_ns);
}

test "a run that fails again soon goes on counting; a stable run gives the attempts back" {
    var r: Reopen = .init(.{}, 0);
    var now: i128 = 0;
    // Three quick failures, each reopened at once: attempts 1..3 used.
    for (0..3) |_| {
        r.ended(error.OniFailed, now);
        now = r.due_ns;
        r.result({}, now);
        now += 5 * s;
    }
    try testing.expectEqual(3, r.restarts);
    r.ended(error.OniFailed, now);
    try testing.expectEqual(4, r.nextAttempt().n);
    now = r.due_ns;
    r.result({}, now);
    // The fourth restart lasts a few seconds: no attempts left.
    r.ended(error.OniFailed, now + 5 * s);
    try testing.expectEqual(State.gave_up, r.state);

    // Another program run: a restart that then lasts a minute starts a fresh streak.
    var q: Reopen = .init(.{}, 0);
    q.ended(error.OniFailed, 0);
    q.result({}, q.due_ns);
    q.ended(error.OniFailed, q.run_started_ns + 60 * s);
    try testing.expectEqual(1, q.nextAttempt().n);
    try testing.expectEqual(q.stopped_ns + 3 * s, q.due_ns);
    // One second short of that, the streak goes on.
    var u: Reopen = .init(.{}, 0);
    u.ended(error.OniFailed, 0);
    u.result({}, u.due_ns);
    u.ended(error.OniFailed, u.run_started_ns + 59 * s);
    try testing.expectEqual(2, u.nextAttempt().n);
    try testing.expectEqual(u.stopped_ns + 10 * s, u.due_ns);
}
