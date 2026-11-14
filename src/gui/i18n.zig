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

// ---- Counted messages ----
//
// A message about a number of things ("3 gaps") has one form per plural form of the
// language, named `<base>_one`, `<base>_few`, `<base>_many`, `<base>_other`. English has
// `_one` and `_other`; Polish needs `_one`, `_few` and `_many`; Chinese only `_other`
// (`forms`). A form may leave out the number ("THE BOARD WENT QUIET ONCE"). A language
// without the message shows English's, by English's rule.
//
//     i18n.count(&buf, "rec_gaps", n, .{ .gaps = n })

/// The plural forms languages tell apart (CLDR's names). Only whole numbers are counted.
pub const Form = enum { one, few, many, other };

/// The form of `n` in `lang` (CLDR's rules for integers; French's and Portuguese's "many"
/// for exact millions is not used: `_other` serves).
pub fn form(lang: Language, n: u64) Form {
    return switch (lang) {
        .en, .de => if (n == 1) .one else .other,
        // CLDR: i = 0,1 (pt is Brazilian Portuguese's rule); Persian: i = 0 or n = 1.
        .fr, .pt, .fa => if (n <= 1) .one else .other,
        .pl => if (n == 1)
            .one
        else if (n % 10 >= 2 and n % 10 <= 4 and !(n % 100 >= 12 and n % 100 <= 14))
            .few
        else
            .many,
        .zh => .other,
    };
}

/// The forms each counted message of `lang` must have.
pub fn forms(lang: Language) []const Form {
    return switch (lang) {
        .en, .de, .fr, .pt, .fa => &.{ .one, .other },
        .pl => &.{ .one, .few, .many },
        .zh => &.{.other},
    };
}

/// Whether `cat` has any form of the counted message `base`.
fn hasCounted(comptime cat: type, comptime base: []const u8) bool {
    inline for (comptime std.enums.values(Form)) |f| {
        if (@hasDecl(cat, base ++ "_" ++ @tagName(f))) return true;
    }
    return false;
}

/// The form `f` of `base` in `cat`, or its `_other` (a form `cat`'s language does not use).
fn countedOf(comptime cat: type, comptime base: []const u8, comptime f: Form) []const u8 {
    const name = base ++ "_" ++ @tagName(f);
    if (@hasDecl(cat, name)) return @field(cat, name);
    if (@hasDecl(cat, base ++ "_other")) return @field(cat, base ++ "_other");
    // Chinese's single form, whatever it is named.
    inline for (comptime std.enums.values(Form)) |g| {
        if (@hasDecl(cat, base ++ "_" ++ @tagName(g))) return @field(cat, base ++ "_" ++ @tagName(g));
    }
    unreachable;
}

/// Whose rule and forms `base` is shown with in `lang`: its own, if it has its own file
/// with the message, else English's.
fn countedSource(comptime lang: Language, comptime base: []const u8) Language {
    return if (catalogue(lang) != en and hasCounted(catalogue(lang), base)) lang else .en;
}

fn checkCounted(comptime base: []const u8) void {
    if (!@hasDecl(en, base ++ "_one") or !@hasDecl(en, base ++ "_other"))
        @compileError("lang/en.zig has no counted message '" ++ base ++ "' (" ++ base ++ "_one and _other)");
}

/// Formats the form of `base` for `n` in `lang` with the fields of `args` it names.
fn countedFormat(comptime lang: Language, buf: []u8, comptime base: []const u8, n: u64, args: anytype) []const u8 {
    const src = comptime countedSource(lang, base);
    return switch (form(src, n)) {
        inline else => |f| blk: {
            const s = comptime countedOf(catalogue(src), base, f);
            break :blk format.fmt(buf, s, only(s, args));
        },
    };
}

/// A counted message in the current language, formatted into `buf` (cut as `fmt` cuts).
/// `args` has every placeholder of every form (the number too, if a form shows it).
pub fn count(buf: []u8, comptime base: []const u8, n: u64, args: anytype) []const u8 {
    comptime checkCounted(base);
    return switch (current) {
        inline else => |lang| countedFormat(lang, buf, base, n, args),
    };
}

/// `count` in a given language.
pub fn countIn(lang: Language, buf: []u8, comptime base: []const u8, n: u64, args: anytype) []const u8 {
    comptime checkCounted(base);
    return switch (lang) {
        inline else => |l| countedFormat(l, buf, base, n, args),
    };
}

/// `count`, onto a writer.
pub fn printCount(w: *std.Io.Writer, comptime base: []const u8, n: u64, args: anytype) std.Io.Writer.Error!void {
    comptime checkCounted(base);
    switch (current) {
        inline else => |lang| {
            const src = comptime countedSource(lang, base);
            switch (form(src, n)) {
                inline else => |f| {
                    const s = comptime countedOf(catalogue(src), base, f);
                    try w.print(s, only(s, args));
                },
            }
        },
    }
}

/// The fields of `args` that the format string `s` names (std.fmt refuses unused ones, and
/// a form may leave the number out).
fn only(comptime s: []const u8, args: anytype) Only(s, @TypeOf(args)) {
    var out: Only(s, @TypeOf(args)) = undefined;
    inline for (comptime std.meta.fieldNames(@TypeOf(out))) |name| @field(out, name) = @field(args, name);
    return out;
}

fn Only(comptime s: []const u8, comptime Args: type) type {
    @setEvalBranchQuota(100_000);
    const phs = (placeholders(s) catch @compileError("malformed placeholders in '" ++ s ++ "'")).slice();
    var names: [phs.len][:0]const u8 = undefined;
    var types: [phs.len]type = undefined;
    var attrs: [phs.len]std.builtin.Type.Struct.FieldAttributes = undefined;
    var len: usize = 0;
    for (phs) |p| {
        const name = std.fmt.comptimePrint("{s}", .{p.name});
        var seen = false;
        for (names[0..len]) |m| seen = seen or std.mem.eql(u8, m, name);
        if (seen) continue;
        if (!@hasField(Args, name)) @compileError("'" ++ s ++ "' needs a field '" ++ name ++ "'");
        const T = @FieldType(Args, name);
        names[len] = name;
        types[len] = switch (T) {
            comptime_int => i64,
            comptime_float => f64,
            else => T,
        };
        attrs[len] = .{};
        len += 1;
    }
    return @Struct(.auto, null, names[0..len], types[0..len], attrs[0..len]);
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

/// The counted message `name` is a form of ("rec_gaps" for "rec_gaps_few"), if English has
/// that counted message.
fn countedBase(comptime name: []const u8) ?[]const u8 {
    inline for (comptime std.enums.values(Form)) |f| {
        const suffix = "_" ++ @tagName(f);
        if (comptime std.mem.endsWith(u8, name, suffix)) {
            const base = name[0 .. name.len - suffix.len];
            if (comptime @hasDecl(en, base ++ "_one") and @hasDecl(en, base ++ "_other")) return base;
        }
    }
    return null;
}

/// The first declaration of `cat` that English does not have, if any: a stale translation.
/// A form English does not use (`_few`, `_many`) of a counted message English has is not.
fn firstStale(comptime cat: type) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    inline for (comptime std.meta.declarations(cat)) |name| {
        if (!@hasDecl(en, name) and comptime countedBase(name) == null) return name;
    }
    return null;
}

/// What a message of a translation is checked against: English's message of that name, or
/// for a form of a counted message, English's `_other`.
fn englishFor(comptime name: []const u8) []const u8 {
    if (comptime countedBase(name)) |base| return @field(en, base ++ "_other");
    return @field(en, name);
}

/// Whether every placeholder of `a` is one of `b` (a form may leave the number out).
fn subsetPlaceholders(a: []const Placeholder, b: []const Placeholder) bool {
    for (a) |x| {
        var found = false;
        for (b) |y| found = found or (std.mem.eql(u8, x.name, y.name) and x.kind == y.kind);
        if (!found) return false;
    }
    return true;
}

/// Leading and trailing spaces: separators the layout depends on (a title's "   ").
fn edgeSpaces(s: []const u8) [2]usize {
    const lead = s.len - std.mem.trimStart(u8, s, " ").len;
    const trail = s.len - std.mem.trimEnd(u8, s, " ").len;
    return .{ lead, trail };
}

/// Checks one message `name` of `lang` (`mine`): its placeholders agree with English's
/// (the same set; for a counted form, some of `_other`'s), it formats, and its edge spaces
/// are English's. Prints what is wrong and returns false.
fn checkMessage(comptime lang: Language, comptime name: []const u8, comptime mine: []const u8) bool {
    @setEvalBranchQuota(1_000_000);
    const english = comptime englishFor(name);
    const eng: ?Placeholders = comptime if (placeholders(english)) |p| p else |_| null;
    const own: ?Placeholders = comptime if (placeholders(mine)) |p| p else |_| null;
    const counted = comptime countedBase(name) != null;
    const agrees = comptime eng != null and own != null and
        (if (counted) subsetPlaceholders(own.?.slice(), eng.?.slice()) else samePlaceholders(own.?.slice(), eng.?.slice()));
    if (comptime !agrees) {
        std.debug.print("{t} {s}: its placeholders differ from English's\n", .{ lang, name });
        return false;
    } else {
        var buf: [512]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, mine, dummyArgs(own.?.slice())) catch |e| {
            std.debug.print("{t} {s}: does not format ({t})\n", .{ lang, name, e });
            return false;
        };
        if (out.len == 0 and mine.len > 0) return false;
    }
    // English's own forms may differ at the edges ("{[count]d} preset"); translations keep
    // the edges of the English message they stand for.
    const own_edges = edgeSpaces(mine);
    const eng_edges = edgeSpaces(if (@hasDecl(en, name)) @field(en, name) else english);
    if (lang != .en and (own_edges[0] != eng_edges[0] or own_edges[1] != eng_edges[1])) {
        std.debug.print("{t} {s}: starts or ends with {d}/{d} spaces where English has {d}/{d}\n", .{ lang, name, own_edges[0], own_edges[1], eng_edges[0], eng_edges[1] });
        return false;
    }
    return true;
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
        pub const alarm_recording_failed = "x";
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
    // And the checks themselves: a wrong name, a counted form with the number left out (fine),
    // a counted form with a placeholder English does not have, edge spaces changed.
    try testing.expect(!checkMessage(.de, "alarm_disk_full_in", "VOLL IN {[lefft]s}"));
    try testing.expect(checkMessage(.de, "alarm_quiet_times_one", "EINMAL"));
    try testing.expect(!checkMessage(.pl, "alarm_gaps_few", "{[gaps]d} {[extra]s}"));
    try testing.expect(!checkMessage(.de, "title_review", "Rückblick"));
    @setEvalBranchQuota(10_000_000);
    var ok = true;
    inline for (comptime std.enums.values(Language)) |lang| {
        const cat = catalogue(lang);
        // Every message English has, as this language shows it.
        inline for (comptime std.meta.declarations(en)) |name| ok = checkMessage(lang, name, if (@hasDecl(cat, name)) @field(cat, name) else @field(en, name)) and ok;
        // The forms English does not have.
        inline for (comptime std.meta.declarations(cat)) |name| {
            if (comptime !@hasDecl(en, name) and countedBase(name) != null) ok = checkMessage(lang, name, @field(cat, name)) and ok;
        }
    }
    try testing.expect(ok);
}

test "every counted message of a language has the forms its language needs" {
    try testing.expectEqual(Form.one, form(.pl, 1));
    try testing.expectEqual(Form.few, form(.pl, 2));
    try testing.expectEqual(Form.few, form(.pl, 24));
    try testing.expectEqual(Form.many, form(.pl, 5));
    try testing.expectEqual(Form.many, form(.pl, 12));
    try testing.expectEqual(Form.many, form(.pl, 0));
    try testing.expectEqual(Form.many, form(.pl, 112));
    try testing.expectEqual(Form.few, form(.pl, 102));
    try testing.expectEqual(Form.one, form(.fr, 0));
    try testing.expectEqual(Form.other, form(.en, 0));
    try testing.expectEqual(Form.other, form(.zh, 1));
    try testing.expectEqual(Form.one, form(.fa, 1));
    @setEvalBranchQuota(1_000_000);
    var ok = true;
    inline for (comptime std.enums.values(Language)) |lang| {
        const cat = catalogue(lang);
        if (cat == en and lang != .en) continue; // no file yet: English throughout
        inline for (comptime std.meta.declarations(en)) |name| {
            if (comptime std.mem.endsWith(u8, name, "_other") and countedBase(name) != null) {
                const base = comptime countedBase(name).?;
                if (comptime hasCounted(cat, base)) {
                    inline for (comptime forms(lang)) |f| {
                        if (comptime !@hasDecl(cat, base ++ "_" ++ @tagName(f))) {
                            std.debug.print("{t} {s}: no form '{t}'\n", .{ lang, base, f });
                            ok = false;
                        }
                    }
                }
            }
        }
    }
    try testing.expect(ok);
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
    try printCount(&w, "alarm_gaps", 3, .{ .gaps = 3 });
    try testing.expectEqualStrings("THE RECORDING HAS 3 GAPS", w.buffered());
    // A counted message: English's two forms, one of them without the number.
    try testing.expectEqualStrings("1 gap", count(&buf, "rec_gaps", 1, .{ .gaps = 1 }));
    try testing.expectEqualStrings("0 gaps", count(&buf, "rec_gaps", 0, .{ .gaps = 0 }));
    w = .fixed(&buf);
    try printCount(&w, "alarm_quiet_times", 1, .{ .times = 1 });
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "THE BOARD WENT QUIET ONCE"));
    // A language without its own file counts by English's rule, not its own (French counts
    // 0 as one; English's form for 0 is "other").
    try testing.expectEqualStrings("0 gaps", countIn(.fr, &buf, "rec_gaps", 0, .{ .gaps = 0 }));
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
