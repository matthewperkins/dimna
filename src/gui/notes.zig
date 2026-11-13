//! Typed notes, stamped with the sample they refer to.
//!
//! On the neural display, with no note open:
//!   /        opens a note, stamped at that moment; type; Enter or \ saves it, Esc drops
//!            it, Tab keeps the text as a draft to stamp later
//!   `        stamps the oldest draft now
//!   1 .. 9   stamps a preset (the config's [notes] preset1 .. preset9), if there is one
//! While a note is open every key goes into it, so no other shortcut fires.
//!
//! The stamp is the newest sample acquired plus the time since it was acquired, so the
//! display's own latency is not in it; keys are read once per frame, so it can be up to
//! one frame (a few ms) late.
//!
//! A saved note goes three ways: into the recording's events.tsv (kind "note") if one is
//! running, into a log of all notes ($XDG_STATE_HOME/oez/notes.log, default
//! ~/.local/state), and onto the traces as a marker.

const std = @import("std");
const oez = @import("oez");
const Input = @import("window.zig").Input;
const Key = @import("window.zig").Key;
const linux = std.os.linux;
const log = std.log.scoped(.notes);

pub const max_text = 200;

/// The longest beginning of `s` of at most `max` bytes that does not end inside a UTF-8
/// character. Text is cut with this wherever it is copied into a smaller buffer or shown
/// shortened.
pub fn prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and s[n] & 0xC0 == 0x80) n -= 1;
    return s[0..n];
}

pub const Note = struct {
    sample: i64 = 0,
    buf: [max_text]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Note) []const u8 {
        return self.buf[0..self.len];
    }
    fn set(self: *Note, s: []const u8) void {
        self.len = prefix(s, self.buf.len).len;
        @memcpy(self.buf[0..self.len], s[0..self.len]);
    }
};

pub const Notes = struct {
    /// The note being typed, if one is open.
    editing: bool = false,
    draft: Note = .{},
    /// Texts kept to be stamped later, oldest first.
    drafts: [8]Note = undefined,
    num_drafts: usize = 0,
    presets: [9]Note = @splat(.{}),
    /// The last notes saved, for the markers and the control window (a ring).
    recent: [32]Note = undefined,
    recent_head: usize = 0,
    recent_len: usize = 0,
    total: u64 = 0,
    /// Notes saved since the caller last took them (for the recording).
    fresh: [8]Note = undefined,
    num_fresh: usize = 0,
    log_fd: i32 = -1,
    /// Set when something changed that the control window shows.
    dirty: bool = false,

    /// Reads the presets from the config's [notes] table and opens the notes log.
    /// `home`, `state_home`: `Env.home` and `Env.state_home`, for where the notes log goes.
    pub fn init(doc: oez.toml.Document, home: []const u8, state_home: []const u8) Notes {
        var self: Notes = .{};
        for (&self.presets, 1..) |*p, n| {
            var key_buf: [12]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "preset{d}", .{n}) catch continue;
            if (doc.string("notes", 0, key)) |s| p.set(s);
        }
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = (if (state_home.len > 0)
            std.fmt.bufPrintSentinel(&path_buf, "{s}/oez", .{state_home}, 0)
        else
            std.fmt.bufPrintSentinel(&path_buf, "{s}/.local/state/oez", .{home}, 0)) catch return self;
        mkdirs(dir);
        var file_buf: [std.fs.max_path_bytes]u8 = undefined;
        const file = std.fmt.bufPrintSentinel(&file_buf, "{s}/notes.log", .{dir}, 0) catch return self;
        const rc = linux.open(file, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(rc) == .SUCCESS) self.log_fd = @intCast(rc) else log.warn("cannot open {s}: notes are not logged there", .{file});
        return self;
    }

    pub fn deinit(self: *Notes) void {
        if (self.log_fd >= 0) _ = linux.close(self.log_fd);
    }

    /// The `i`-th most recent note (0 = newest).
    pub fn recentNote(self: *const Notes, i: usize) ?*const Note {
        if (i >= self.recent_len) return null;
        return &self.recent[(self.recent_head + self.recent_len - 1 - i) % self.recent.len];
    }

    /// Takes what the user typed this frame. `now_sample` is the sample "now" refers to.
    /// While a note is open, or for a key that is a note command, the keys are taken out
    /// of `in`, so they do nothing else. `session`: the recording's folder, or "".
    pub fn handle(self: *Notes, in: *Input, now_sample: i64, session: []const u8) void {
        if (self.editing) {
            var done: enum { no, save, cancel, keep } = .no;
            for (in.keys[0..in.num_keys]) |k| switch (k) {
                .char => |c| if (c == '\\') {
                    done = .save;
                },
                .named => |n| switch (n) {
                    .enter => done = .save,
                    .escape => done = .cancel,
                    .tab => done = .keep,
                    .backspace => {
                        // One whole character: back over UTF-8 continuation bytes.
                        while (self.draft.len > 0) {
                            self.draft.len -= 1;
                            if (self.draft.buf[self.draft.len] & 0xC0 != 0x80) break;
                        }
                    },
                    else => {},
                },
            };
            if (done == .no or done == .save or done == .keep) {
                // Whole characters only: a note that is full takes no part of one.
                const typed = in.text[0..in.text_len];
                var at: usize = 0;
                while (at < typed.len) {
                    const ch = typed[at];
                    const n = std.unicode.utf8ByteSequenceLength(ch) catch 1;
                    if (at + n > typed.len) break;
                    defer at += n;
                    // The key that ends the note is not part of it.
                    if (ch == '\\' or ch == '\t' or ch == '\r' or ch == '\n') continue;
                    if (ch & 0xC0 == 0x80) continue; // a stray continuation byte
                    if (self.draft.len + n > self.draft.buf.len) break;
                    @memcpy(self.draft.buf[self.draft.len..][0..n], typed[at..][0..n]);
                    self.draft.len += n;
                }
            }
            switch (done) {
                .no => {},
                .cancel => self.editing = false,
                .save => {
                    self.editing = false;
                    if (self.draft.len > 0) self.save(self.draft.sample, self.draft.text(), session);
                },
                .keep => {
                    self.editing = false;
                    if (self.draft.len > 0 and self.num_drafts < self.drafts.len) {
                        self.drafts[self.num_drafts] = self.draft;
                        self.num_drafts += 1;
                    }
                },
            }
            self.dirty = true;
            in.num_keys = 0;
            in.text_len = 0;
            return;
        }
        // Not editing: /, ` and the digits that have a preset are ours.
        var kept: usize = 0;
        for (in.keys[0..in.num_keys]) |k| {
            // A digit whose preset has a text.
            const preset: ?usize = if (k.digit()) |d| (if (self.presets[d - 1].len > 0) d - 1 else null) else null;
            if (k.is('/')) {
                self.editing = true;
                self.draft = .{ .sample = now_sample };
                self.dirty = true;
            } else if (k.is('`')) {
                if (self.num_drafts > 0) {
                    self.save(now_sample, self.drafts[0].text(), session);
                    for (1..self.num_drafts) |i| self.drafts[i - 1] = self.drafts[i];
                    self.num_drafts -= 1;
                }
            } else if (preset) |which| {
                self.save(now_sample, self.presets[which].text(), session);
            } else {
                in.keys[kept] = k;
                kept += 1;
            }
        }
        in.num_keys = kept;
        // Whatever opened the note is not its first character.
        if (self.editing) in.text_len = 0;
    }

    /// Stamps preset `n` (1 to 9), as its key does (for the control window's buttons).
    pub fn stampPreset(self: *Notes, n: usize, now_sample: i64, session: []const u8) void {
        if (n >= 1 and n <= 9 and self.presets[n - 1].len > 0) self.save(now_sample, self.presets[n - 1].text(), session);
    }

    fn save(self: *Notes, sample: i64, text: []const u8, session: []const u8) void {
        var note: Note = .{ .sample = sample };
        note.set(text);
        self.recent[(self.recent_head + self.recent_len) % self.recent.len] = note;
        if (self.recent_len < self.recent.len) self.recent_len += 1 else self.recent_head = (self.recent_head + 1) % self.recent.len;
        self.total += 1;
        if (self.num_fresh < self.fresh.len) {
            self.fresh[self.num_fresh] = note;
            self.num_fresh += 1;
        }
        self.dirty = true;
        if (self.log_fd >= 0) {
            // time <TAB> sample <TAB> session folder (or -) <TAB> text
            var line: [max_text + 400]u8 = undefined;
            var when: [40]u8 = undefined;
            const text_line = std.fmt.bufPrint(
                &line,
                "{s}\t{d}\t{s}\t{s}\n",
                .{ oez.record.localTime(&when), sample, if (session.len > 0) session else "-", note.text() },
            ) catch return;
            _ = linux.write(self.log_fd, text_line.ptr, text_line.len);
        }
    }
};

/// Creates `path` and its parents (as `mkdir -p`).
fn mkdirs(path: [:0]const u8) void {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i < path.len and path[i] != '/') continue;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        _ = linux.mkdir(buf[0..i :0], 0o755);
    }
}

// ---- Tests ----
//
// None of these calls `Notes.init`, which opens $XDG_STATE_HOME/oez/notes.log (default
// ~/.local/state/oez/notes.log): a `Notes` made with `.{}` has `log_fd == -1` and logs
// nowhere. The test of the log line gives it a file under /tmp instead.

const testing = std.testing;

/// One frame of input: these keys, and the text they would type.
fn frame(keys: []const Key, text: []const u8) Input {
    var in: Input = .{};
    @memcpy(in.keys[0..keys.len], keys);
    in.num_keys = keys.len;
    @memcpy(in.text[0..text.len], text);
    in.text_len = text.len;
    return in;
}

fn digit(d: u8) Key {
    return .{ .char = d };
}

fn chr(c: u8) Key {
    return .{ .char = c };
}

fn nm(n: Key.Named) Key {
    return .{ .named = n };
}

/// Feeds one frame to `notes` and returns what is left of it for the other shortcuts.
fn feed(notes: *Notes, keys: []const Key, text: []const u8, now: i64) Input {
    var in = frame(keys, text);
    notes.handle(&in, now, "");
    return in;
}

/// Opens a note at `now` and types `text` into it, in frames of at most 64 bytes.
fn openAndType(notes: *Notes, now: i64, text: []const u8) !void {
    _ = feed(notes, &.{chr('/')}, "/", now);
    try testing.expect(notes.editing);
    var rest = text;
    while (rest.len > 0) {
        const n = @min(rest.len, 64);
        _ = feed(notes, &.{}, rest[0..n], now + 1);
        rest = rest[n..];
    }
}

test "a new Notes logs nowhere" {
    const notes: Notes = .{};
    try testing.expectEqual(-1, notes.log_fd);
    try testing.expect(!notes.editing);
}

test "slash opens a note; the keys that follow are its text, not shortcuts" {
    var notes: Notes = .{};
    notes.presets[2].set("preset three");
    // The '/' itself is not the note's first character, and the other keys pass through.
    var in = feed(&notes, &.{ chr('q'), chr('/') }, "q/", 100);
    try testing.expect(notes.editing);
    try testing.expectEqual(100, notes.draft.sample);
    try testing.expectEqual(0, notes.draft.len);
    try testing.expectEqual(0, in.text_len);
    try testing.expectEqual(1, in.num_keys);
    try testing.expectEqual(chr('q'), in.keys[0]);
    // While it is open, nothing is left for the other shortcuts, a preset's digit and
    // backtick included: they are text.
    in = feed(&notes, &.{ chr('q'), chr('m'), digit('3'), chr('`'), chr('/'), chr(' ') }, "qm3`/ ", 200);
    try testing.expectEqual(0, in.num_keys);
    try testing.expectEqual(0, in.text_len);
    try testing.expectEqualStrings("qm3`/ ", notes.draft.text());
    try testing.expectEqual(0, notes.total);
    try testing.expect(notes.editing);
}

test "Enter or backslash saves the note with the stamp it was opened at" {
    var notes: Notes = .{};
    try openAndType(&notes, 1000, "cell 3 ");
    // The text typed in the frame that ends it is kept; the ending key's own text is not.
    _ = feed(&notes, &.{nm(.enter)}, "lost\r", 5000);
    try testing.expect(!notes.editing);
    try testing.expectEqual(1, notes.total);
    try testing.expectEqual(1000, notes.recentNote(0).?.sample);
    try testing.expectEqualStrings("cell 3 lost", notes.recentNote(0).?.text());

    try openAndType(&notes, 7000, "second");
    _ = feed(&notes, &.{chr('\\')}, "\\", 9000);
    try testing.expect(!notes.editing);
    try testing.expectEqual(2, notes.total);
    try testing.expectEqual(7000, notes.recentNote(0).?.sample);
    try testing.expectEqualStrings("second", notes.recentNote(0).?.text());
    try testing.expectEqualStrings("cell 3 lost", notes.recentNote(1).?.text());
    try testing.expectEqual(null, notes.recentNote(2));

    // An empty note is not saved.
    _ = feed(&notes, &.{chr('/')}, "/", 10000);
    _ = feed(&notes, &.{nm(.enter)}, "", 10001);
    try testing.expect(!notes.editing);
    try testing.expectEqual(2, notes.total);
}

test "Esc drops the note" {
    var notes: Notes = .{};
    try openAndType(&notes, 1000, "never mind");
    const in = feed(&notes, &.{nm(.escape)}, "x", 2000);
    try testing.expect(!notes.editing);
    try testing.expectEqual(0, in.num_keys);
    try testing.expectEqual(0, notes.total);
    try testing.expectEqual(0, notes.num_fresh);
    try testing.expectEqual(0, notes.num_drafts);
}

test "Tab keeps the note as a draft; backtick stamps the oldest draft now" {
    var notes: Notes = .{};
    try openAndType(&notes, 1000, "laser on");
    _ = feed(&notes, &.{nm(.tab)}, "\t", 1100);
    try openAndType(&notes, 2000, "laser off");
    _ = feed(&notes, &.{nm(.tab)}, "\t", 2100);
    try testing.expect(!notes.editing);
    try testing.expectEqual(2, notes.num_drafts);
    try testing.expectEqual(0, notes.total);
    try testing.expectEqualStrings("laser on", notes.drafts[0].text());

    // Backtick is a note command when no note is open: taken out of the input.
    var in = feed(&notes, &.{ chr('`'), chr('m') }, "`m", 50_000);
    try testing.expectEqual(1, in.num_keys);
    try testing.expectEqual(chr('m'), in.keys[0]);
    try testing.expectEqual(1, notes.total);
    try testing.expectEqual(50_000, notes.recentNote(0).?.sample);
    try testing.expectEqualStrings("laser on", notes.recentNote(0).?.text());
    try testing.expectEqual(1, notes.num_drafts);
    try testing.expectEqualStrings("laser off", notes.drafts[0].text());

    _ = feed(&notes, &.{chr('`')}, "`", 60_000);
    try testing.expectEqual(60_000, notes.recentNote(0).?.sample);
    try testing.expectEqualStrings("laser off", notes.recentNote(0).?.text());
    try testing.expectEqual(0, notes.num_drafts);
    // With no drafts left, backtick does nothing (and is still taken).
    in = feed(&notes, &.{chr('`')}, "`", 70_000);
    try testing.expectEqual(0, in.num_keys);
    try testing.expectEqual(2, notes.total);

    // An empty note is not kept as a draft.
    _ = feed(&notes, &.{chr('/')}, "/", 80_000);
    _ = feed(&notes, &.{nm(.tab)}, "\t", 80_001);
    try testing.expectEqual(0, notes.num_drafts);
}

test "Backspace removes one whole UTF-8 character" {
    var notes: Notes = .{};
    // a, é (2 bytes), → (3 bytes)
    try openAndType(&notes, 0, "a\u{e9}\u{2192}");
    try testing.expectEqual(6, notes.draft.len);
    _ = feed(&notes, &.{nm(.backspace)}, "", 1);
    try testing.expectEqualStrings("a\u{e9}", notes.draft.text());
    _ = feed(&notes, &.{nm(.backspace)}, "", 2);
    try testing.expectEqualStrings("a", notes.draft.text());
    _ = feed(&notes, &.{nm(.backspace)}, "", 3);
    try testing.expectEqualStrings("", notes.draft.text());
    // At an empty note it does nothing, and the note stays open.
    _ = feed(&notes, &.{ nm(.backspace), nm(.backspace) }, "", 4);
    try testing.expectEqual(0, notes.draft.len);
    try testing.expect(notes.editing);
    // Two in one frame remove two characters.
    _ = feed(&notes, &.{}, "\u{2192}x\u{e9}", 5);
    _ = feed(&notes, &.{ nm(.backspace), nm(.backspace) }, "", 6);
    try testing.expectEqualStrings("\u{2192}", notes.draft.text());
}

test "a note longer than the buffer is cut at max_text bytes" {
    var notes: Notes = .{};
    var long: [250]u8 = undefined;
    for (&long, 0..) |*ch, i| ch.* = '0' + @as(u8, @intCast(i % 10));
    try openAndType(&notes, 42, &long);
    try testing.expectEqual(max_text, notes.draft.len);
    _ = feed(&notes, &.{nm(.enter)}, "", 43);
    try testing.expectEqualStrings(long[0..max_text], notes.recentNote(0).?.text());
    try testing.expectEqual(42, notes.recentNote(0).?.sample);
}

test "presets 1 to 9 stamp only when no note is open, and only if they are set" {
    var notes: Notes = .{};
    notes.presets[0].set("one");
    notes.presets[8].set("nine");
    // 1 and 9 have presets and are taken; 2 has none and passes through to the display.
    var in = feed(&notes, &.{ digit('1'), digit('2'), digit('9') }, "129", 500);
    try testing.expectEqual(1, in.num_keys);
    try testing.expectEqual(digit('2'), in.keys[0]);
    try testing.expectEqual(2, notes.total);
    try testing.expectEqualStrings("nine", notes.recentNote(0).?.text());
    try testing.expectEqualStrings("one", notes.recentNote(1).?.text());
    try testing.expectEqual(500, notes.recentNote(0).?.sample);

    // With a note open the digit is text.
    _ = feed(&notes, &.{chr('/')}, "/", 600);
    in = feed(&notes, &.{digit('1')}, "1", 700);
    try testing.expectEqual(0, in.num_keys);
    try testing.expectEqual(2, notes.total);
    try testing.expectEqualStrings("1", notes.draft.text());

    // The control window's buttons: only 1 to 9, only presets that are set.
    notes.stampPreset(9, 800, "");
    notes.stampPreset(2, 800, "");
    notes.stampPreset(0, 800, "");
    notes.stampPreset(10, 800, "");
    try testing.expectEqual(3, notes.total);
}

test "fresh holds what was saved since the caller last took it" {
    var notes: Notes = .{};
    notes.presets[3].set("four");
    try testing.expectEqual(0, notes.num_fresh);
    try openAndType(&notes, 10, "typed");
    _ = feed(&notes, &.{nm(.enter)}, "", 11);
    _ = feed(&notes, &.{digit('4')}, "4", 12);
    try testing.expectEqual(2, notes.num_fresh);
    try testing.expectEqualStrings("typed", notes.fresh[0].text());
    try testing.expectEqual(10, notes.fresh[0].sample);
    try testing.expectEqualStrings("four", notes.fresh[1].text());
    try testing.expectEqual(12, notes.fresh[1].sample);
    // The caller takes them (as main.zig does) and the next turn starts empty.
    notes.num_fresh = 0;
    _ = feed(&notes, &.{digit('4')}, "4", 13);
    try testing.expectEqual(1, notes.num_fresh);
    try testing.expectEqual(13, notes.fresh[0].sample);
    // More than `fresh` holds in one turn: the first ones are kept, all are counted.
    notes.num_fresh = 0;
    for (0..notes.fresh.len + 3) |i| _ = feed(&notes, &.{digit('4')}, "4", @intCast(100 + i));
    try testing.expectEqual(notes.fresh.len, notes.num_fresh);
    try testing.expectEqual(100, notes.fresh[0].sample);
    try testing.expectEqual(3 + notes.fresh.len + 3, notes.total);
}

test "recent keeps the last 32 notes, newest first" {
    var notes: Notes = .{};
    notes.presets[0].set("p");
    for (0..40) |i| {
        _ = feed(&notes, &.{digit('1')}, "1", @intCast(i));
        notes.num_fresh = 0;
    }
    try testing.expectEqual(40, notes.total);
    try testing.expectEqual(39, notes.recentNote(0).?.sample);
    try testing.expectEqual(8, notes.recentNote(31).?.sample);
    try testing.expectEqual(null, notes.recentNote(32));
}

test "a saved note is one line in the log: time, sample, session, text" {
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buf, "/tmp/oez-notes-test-{d}", .{linux.getpid()}, 0);
    var file_buf: [96]u8 = undefined;
    const file = try std.fmt.bufPrintSentinel(&file_buf, "{s}/notes.log", .{dir}, 0);
    _ = linux.mkdir(dir, 0o755);
    defer {
        _ = linux.unlink(file);
        _ = linux.rmdir(dir);
    }
    const rc = linux.open(file, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    try testing.expectEqual(.SUCCESS, linux.errno(rc));
    var notes: Notes = .{ .log_fd = @intCast(rc) };
    defer notes.deinit();
    notes.presets[0].set("baseline");
    try openAndType(&notes, 12345, "cell 1");
    var in = frame(&.{nm(.enter)}, "");
    notes.handle(&in, 99999, "/data/2026-11-12_10-00-00");
    in = frame(&.{digit('1')}, "1");
    notes.handle(&in, 67890, "");

    var buf: [1024]u8 = undefined;
    const fd = linux.open(file, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    try testing.expectEqual(.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));
    const n = linux.read(@intCast(fd), &buf, buf.len);
    try testing.expectEqual(.SUCCESS, linux.errno(n));
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    const expect = [_][3][]const u8{
        .{ "12345", "/data/2026-11-12_10-00-00", "cell 1" },
        .{ "67890", "-", "baseline" },
    };
    for (expect) |e| {
        var fields = std.mem.splitScalar(u8, lines.next().?, '\t');
        try testing.expect(fields.next().?.len > 0); // local time
        try testing.expectEqualStrings(e[0], fields.next().?);
        try testing.expectEqualStrings(e[1], fields.next().?);
        try testing.expectEqualStrings(e[2], fields.next().?);
        try testing.expectEqual(null, fields.next());
    }
    try testing.expectEqualStrings("", lines.next().?);
    try testing.expectEqual(null, lines.next());
}

test "a full note takes no part of a character, and text is cut between characters" {
    var n: Notes = .{};
    var in: Input = .{};
    in.keys[0] = chr('/');
    in.num_keys = 1;
    n.handle(&in, 0, "");
    try testing.expect(n.editing);
    // 199 bytes, then a two-byte character: it does not fit and is left out whole.
    var k: usize = 0;
    while (k < 199) : (k += 1) {
        in = .{};
        in.text[0] = 'a';
        in.text_len = 1;
        n.handle(&in, 0, "");
    }
    in = .{};
    @memcpy(in.text[0..3], "\u{e9}b");
    in.text_len = 3;
    n.handle(&in, 0, "");
    try testing.expectEqual(199, n.draft.len);
    try testing.expect(std.unicode.utf8ValidateSlice(n.draft.text()));

    try testing.expectEqualStrings("ab", prefix("ab\u{e9}", 3));
    try testing.expectEqualStrings("ab\u{e9}", prefix("ab\u{e9}", 4));
    try testing.expectEqualStrings("", prefix("\u{2013}", 2));
    try testing.expectEqualStrings("abc", prefix("abc", 10));
    try testing.expectEqualStrings("", prefix("abc", 0));
}
