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

pub const Note = struct {
    sample: i64 = 0,
    buf: [max_text]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Note) []const u8 {
        return self.buf[0..self.len];
    }
    fn set(self: *Note, s: []const u8) void {
        self.len = @min(s.len, self.buf.len);
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
    pub fn init(doc: oez.toml.Document) Notes {
        var self: Notes = .{};
        for (&self.presets, 1..) |*p, n| {
            var key_buf: [12]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "preset{d}", .{n}) catch continue;
            if (doc.string("notes", 0, key)) |s| p.set(s);
        }
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const state: []const u8 = if (std.c.getenv("XDG_STATE_HOME")) |x| std.mem.span(x) else "";
        const home: []const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else ".";
        const dir = (if (state.len > 0) std.fmt.bufPrintSentinel(&path_buf, "{s}/oez", .{state}, 0) else std.fmt.bufPrintSentinel(&path_buf, "{s}/.local/state/oez", .{home}, 0)) catch return self;
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
                .enter, .backslash => done = .save,
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
            };
            if (done == .no or done == .save or done == .keep) {
                for (in.text[0..in.text_len]) |ch| {
                    // The key that ends the note is not part of it.
                    if (ch == '\\' or ch == '\t' or ch == '\r' or ch == '\n') continue;
                    if (self.draft.len < self.draft.buf.len) {
                        self.draft.buf[self.draft.len] = ch;
                        self.draft.len += 1;
                    }
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
            const code = @backingInt(k);
            if (k == .slash) {
                self.editing = true;
                self.draft = .{ .sample = now_sample };
                self.dirty = true;
            } else if (k == .grave) {
                if (self.num_drafts > 0) {
                    self.save(now_sample, self.drafts[0].text(), session);
                    for (1..self.num_drafts) |i| self.drafts[i - 1] = self.drafts[i];
                    self.num_drafts -= 1;
                }
            } else if (code >= '1' and code <= '9' and self.presets[code - '1'].len > 0) {
                self.save(now_sample, self.presets[code - '1'].text(), session);
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
            const text_line = std.fmt.bufPrint(&line, "{s}\t{d}\t{s}\t{s}\n", .{ oez.record.localTime(&when), sample, if (session.len > 0) session else "-", note.text() }) catch return;
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
