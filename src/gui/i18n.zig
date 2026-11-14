//! The texts the GUI shows, by language. The English catalogue (`lang/en.zig`) holds one
//! `pub const` per message; a message with values has named placeholders (`{[left]s}`), so a
//! translation can order them as its language needs. Other languages are files of the same
//! names (`lang/de.zig`, ...); a message a language lacks is shown in English (checked at
//! compile time, per message), and a message a language has that English does not is a
//! stale translation, which a test reports.
//!
//! `current` is set once at start-up, before any window draws (`pick`, from the config's
//! `language` key or `LANG`); after that it is only read, by every thread.
//!
//!     i18n.text(.hint_keys)                              // a message without values
//!     i18n.fmt(&buf, .disk_full_in, .{ .left = text })   // one with values; cut to `buf`
//!     i18n.print(writer, .alarm_gaps, .{ .gaps = n })    // onto a writer, as it fits
//!
//! `Id` names every message, so a typo is a compile error.

const std = @import("std");
const format = @import("format.zig");
const en = @import("lang/en.zig");
const log = std.log.scoped(.dimna);

/// The languages dimna is to be translated into (a language without a file shows English).
pub const Language = enum { en, de, fr, pt, pl, zh, fa };

/// The language of every text below. Set once, at start-up.
pub var current: Language = .en;

/// A language's messages, as a type whose declarations are the messages it has. Later
/// plans add `lang/de.zig` and so on, and a line for each here.
pub fn catalogue(comptime lang: Language) type {
    return switch (lang) {
        .en, .de, .fr, .pt, .pl, .zh, .fa => en,
    };
}

/// The messages: one name per declaration of the English file.
pub const Id = blk: {
    const names = std.meta.declarations(en);
    var field_names: [names.len][]const u8 = undefined;
    var values: [names.len]u16 = undefined;
    for (names, 0..) |name, i| {
        field_names[i] = name;
        values[i] = i;
    }
    break :blk @Enum(u16, .exhaustive, &field_names, &values);
};

/// The message `id` in `lang`, in English where `lang` has none.
fn lookup(comptime lang: Language, comptime id: Id) []const u8 {
    const name = @tagName(id);
    const cat = catalogue(lang);
    return if (@hasDecl(cat, name)) @field(cat, name) else @field(en, name);
}

/// A message without values, in the current language.
pub fn text(comptime id: Id) []const u8 {
    return switch (current) {
        inline else => |lang| lookup(lang, id),
    };
}

/// A message in a given language.
pub fn textIn(lang: Language, comptime id: Id) []const u8 {
    return switch (lang) {
        inline else => |l| lookup(l, id),
    };
}

/// A message without values whose id is known only at run time (a table of keys), in the
/// current language.
pub fn textOf(id: Id) []const u8 {
    return switch (id) {
        inline else => |known| text(known),
    };
}

/// `textOf` in a given language.
pub fn textOfIn(lang: Language, id: Id) []const u8 {
    return switch (id) {
        inline else => |known| textIn(lang, known),
    };
}

/// A message with values, formatted into `buf` as `format.fmt` does: text that does not fit
/// is cut at a whole UTF-8 character. `args` is a struct with the message's placeholders'
/// names as fields.
pub fn fmt(buf: []u8, comptime id: Id, args: anytype) []const u8 {
    return switch (current) {
        inline else => |lang| format.fmt(buf, lookup(lang, id), args),
    };
}

/// A message with values, onto a writer (which keeps what fits, if it is a fixed one).
pub fn print(w: *std.Io.Writer, comptime id: Id, args: anytype) std.Io.Writer.Error!void {
    return switch (current) {
        inline else => |lang| w.print(lookup(lang, id), args),
    };
}

/// The language to use: the config's `language` (a name of `Language`; anything else is
/// warned about once and means English), else the first two letters of `LANG` when they name
/// a language ("pl_PL.UTF-8"), else English. Either may be empty.
pub fn pick(configured: []const u8, lang_env: []const u8) Language {
    if (configured.len > 0) {
        return std.meta.stringToEnum(Language, configured) orelse {
            log.warn("config: language '{s}' is not one of en, de, fr, pt, pl, zh, fa; using en", .{configured});
            return .en;
        };
    }
    if (lang_env.len < 2) return .en;
    var two: [2]u8 = undefined;
    for (&two, lang_env[0..2]) |*c, l| c.* = std.ascii.toLower(l);
    // "C" and "POSIX" are not two letters of a language; "pl" must also end there or go on
    // with a separator ("pl", "pl_PL", "pl.UTF-8"), so "plain" is not Polish.
    if (lang_env.len > 2 and std.mem.indexOfScalar(u8, "_.@-", lang_env[2]) == null) return .en;
    return std.meta.stringToEnum(Language, &two) orelse .en;
}

/// What a language needs from the machine beyond what English does: a font with its script
/// (a sample of characters it must have), and for a joined, right-to-left script, the
/// shaping libraries. Null: nothing beyond English (the Latin languages).
pub const Needs = struct {
    name: []const u8,
    sample: []const u32,
    shaping: bool,
    /// What to install, for the message.
    font_hint: []const u8,
};

pub fn needs(lang: Language) ?Needs {
    return switch (lang) {
        // 阈值 ("threshold"): two common Simplified characters.
        .zh => .{ .name = "Chinese", .sample = &.{ 0x9608, 0x503C }, .shaping = false, .font_hint = "a Chinese font (Noto Sans CJK SC: noto-fonts-cjk, fonts-noto-cjk)" },
        // پ ی ف: Persian's own peh and yeh, and feh.
        .fa => .{ .name = "Persian", .sample = &.{ 0x067E, 0x06CC, 0x0641 }, .shaping = true, .font_hint = "an Arabic-script font (Noto Sans Arabic: noto-fonts, fonts-noto-core)" },
        else => null,
    };
}

/// Why `lang` cannot be shown, given whether a font has its sample and whether the shaping
/// libraries load; null if it can.
pub fn missing(lang: Language, has_font: bool, has_shaping: bool) ?[]const u8 {
    const n = needs(lang) orelse return null;
    if (!has_font) return n.font_hint;
    if (n.shaping and !has_shaping) return "HarfBuzz and FriBidi (harfbuzz, fribidi)";
    return null;
}

test "a language that cannot be shown says what it needs; the Latin ones need nothing" {
    try std.testing.expect(missing(.de, false, false) == null);
    try std.testing.expect(missing(.zh, true, false) == null); // Chinese needs no shaping
    try std.testing.expect(std.mem.indexOf(u8, missing(.zh, false, true).?, "CJK SC") != null);
    try std.testing.expect(missing(.fa, true, true) == null);
    try std.testing.expect(std.mem.indexOf(u8, missing(.fa, false, true).?, "Arabic") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing(.fa, true, false).?, "HarfBuzz") != null);
}

// ---- Checking a catalogue ----

/// One placeholder of a message: its name and its kind (`s` text, `d` number, `t` a tag).
const Placeholder = struct { name: []const u8, kind: u8 };

/// The placeholders of a format string, in order.
const Placeholders = struct {
    items: [16]Placeholder = undefined,
    len: usize = 0,

    fn slice(self: *const Placeholders) []const Placeholder {
        return self.items[0..self.len];
    }
};

/// Reads the placeholders of `s`: `{[name]s}`, `{[name]d}`, `{[name]d:.1}`, `{[name]t}`,
/// with `{{` and `}}` for the braces themselves. Anything else is malformed.
fn placeholders(comptime s: []const u8) error{Malformed}!Placeholders {
    var out: Placeholders = .{};
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '{' => {
                if (i + 1 < s.len and s[i + 1] == '{') {
                    i += 1;
                    continue;
                }
                if (i + 1 >= s.len or s[i + 1] != '[') return error.Malformed;
                const name_end = std.mem.indexOfScalarPos(u8, s, i + 2, ']') orelse return error.Malformed;
                const name = s[i + 2 .. name_end];
                if (name.len == 0) return error.Malformed;
                for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return error.Malformed;
                const close = std.mem.indexOfScalarPos(u8, s, name_end, '}') orelse return error.Malformed;
                const spec = s[name_end + 1 .. close];
                if (spec.len == 0 or std.mem.indexOfScalar(u8, "sdt", spec[0]) == null) return error.Malformed;
                if (spec.len > 1 and (spec[0] != 'd' or spec[1] != ':')) return error.Malformed;
                if (out.len == out.items.len) return error.Malformed;
                out.items[out.len] = .{ .name = name, .kind = spec[0] };
                out.len += 1;
                i = close;
            },
            '}' => {
                if (i + 1 < s.len and s[i + 1] == '}') {
                    i += 1;
                    continue;
                }
                return error.Malformed;
            },
            else => {},
        }
    }
    return out;
}

/// The first declaration of `cat` that English does not have, if any: a stale translation.
fn firstStale(comptime cat: type) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    inline for (comptime std.meta.declarations(cat)) |name| {
        if (!@hasDecl(en, name)) return name;
    }
    return null;
}

/// Whether the placeholders of two messages are the same set of names and kinds.
fn samePlaceholders(a: []const Placeholder, b: []const Placeholder) bool {
    if (a.len != b.len) return false;
    for (a) |x| {
        var found = false;
        for (b) |y| found = found or (std.mem.eql(u8, x.name, y.name) and x.kind == y.kind);
        if (!found) return false;
    }
    return true;
}

/// A struct with a field per placeholder, filled with a dummy value of its kind.
fn dummyArgs(comptime phs: []const Placeholder) DummyArgs(phs) {
    var args: DummyArgs(phs) = undefined;
    inline for (phs) |p| {
        @field(args, p.name) = switch (p.kind) {
            's' => "x",
            'd' => 1.5,
            't' => error.Dummy,
            else => unreachable,
        };
    }
    return args;
}

fn DummyArgs(comptime phs: []const Placeholder) type {
    var names: [phs.len][:0]const u8 = undefined;
    var types: [phs.len]type = undefined;
    var attrs: [phs.len]std.builtin.Type.Struct.FieldAttributes = undefined;
    for (phs, 0..) |p, i| {
        names[i] = std.fmt.comptimePrint("{s}", .{p.name});
        types[i] = switch (p.kind) {
            's' => []const u8,
            'd' => f64,
            't' => @TypeOf(error.Dummy),
            else => unreachable,
        };
        attrs[i] = .{};
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

const testing = std.testing;

test "no language has a message that English does not (a stale translation)" {
    // The check itself finds one in a catalogue that has an extra.
    const Stale = struct {
        pub const alarm_gaps = "x";
        pub const no_such_message_in_english = "y";
    };
    try testing.expectEqualStrings("no_such_message_in_english", comptime firstStale(Stale).?);
    inline for (comptime std.enums.values(Language)) |lang| {
        if (comptime firstStale(catalogue(lang))) |name| {
            std.debug.print("{t}: '{s}' is not in lang/en.zig\n", .{ lang, name });
            return error.TestUnexpectedResult;
        }
    }
}

test "every message of every language formats with its placeholders, and agrees with English" {
    // The parser catches what it should.
    try testing.expect(comptime (placeholders("{[a]s} and {[b]d:.1} {{x}}") catch unreachable).len == 2);
    try testing.expectError(error.Malformed, comptime placeholders("{s}"));
    try testing.expectError(error.Malformed, comptime placeholders("{[a]x}"));
    try testing.expectError(error.Malformed, comptime placeholders("{[a]s"));
    try testing.expectError(error.Malformed, comptime placeholders("a } b"));
    @setEvalBranchQuota(1_000_000);
    var buf: [512]u8 = undefined;
    inline for (comptime std.enums.values(Id)) |id| {
        const name = @tagName(id);
        const english: ?Placeholders = comptime if (placeholders(@field(en, name))) |p| p else |_| null;
        if (english == null) {
            std.debug.print("lang/en.zig {s}: malformed placeholders\n", .{name});
            return error.TestUnexpectedResult;
        }
        const phs = comptime if (english) |e| e.slice() else &[0]Placeholder{};
        inline for (comptime std.enums.values(Language)) |lang| {
            const mine: ?Placeholders = comptime if (placeholders(lookup(lang, id))) |p| p else |_| null;
            // Only a message that agrees with English is formatted: a bad one would not
            // compile, and this reports which it is.
            const agrees = comptime mine != null and samePlaceholders(mine.?.slice(), phs);
            if (comptime !agrees) {
                std.debug.print("{t} {s}: its placeholders differ from English's\n", .{ lang, name });
                return error.TestUnexpectedResult;
            } else {
                const out = std.fmt.bufPrint(&buf, lookup(lang, id), dummyArgs(phs)) catch |e| {
                    std.debug.print("{t} {s}: does not format ({t})\n", .{ lang, name, e });
                    return error.TestUnexpectedResult;
                };
                try testing.expect(out.len > 0 or lookup(lang, id).len == 0);
            }
        }
    }
}

test "text, fmt and print give the current language's message, cut at a character" {
    try testing.expectEqualStrings("Keys and the mouse   (? or Esc closes this)", text(.help_title));
    try testing.expectEqualStrings("Keys and the mouse   (? or Esc closes this)", textOf(.help_title));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("THE DISK IS FULL IN about 12 min", fmt(&buf, .alarm_disk_full_in, .{ .left = "about 12 min" }));
    // "noise 1.5 µV, held": 8 bytes end inside "µ"? "noise 1.5 " is 10; 11 would cut it.
    var small: [11]u8 = undefined;
    try testing.expectEqualStrings("noise 1.5 ", fmt(&small, .audio_noise_held, .{ .sigma = 1.5 }));
    var w: std.Io.Writer = .fixed(&buf);
    try print(&w, .alarm_gaps, .{ .gaps = 3 });
    try testing.expectEqualStrings("THE RECORDING HAS 3 GAPS", w.buffered());
}

test "the language: the config's value, then LANG, else English" {
    try testing.expectEqual(Language.de, pick("de", ""));
    try testing.expectEqual(Language.zh, pick("zh", "pl_PL.UTF-8")); // the config wins
    try testing.expectEqual(Language.pl, pick("", "pl_PL.UTF-8"));
    try testing.expectEqual(Language.pl, pick("", "pl"));
    try testing.expectEqual(Language.fa, pick("", "FA_IR"));
    try testing.expectEqual(Language.en, pick("", "C"));
    try testing.expectEqual(Language.en, pick("", ""));
    try testing.expectEqual(Language.en, pick("", "POSIX"));
    try testing.expectEqual(Language.en, pick("", "plain")); // not "pl"
    try testing.expectEqual(Language.en, pick("", "xx_XX")); // no such language
    try testing.expectEqual(Language.en, pick("klingon", "pl_PL.UTF-8")); // a bad value: English, not LANG
}
