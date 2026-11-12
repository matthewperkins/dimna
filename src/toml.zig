//! A reader for the subset of TOML that oEZ's config file uses:
//!
//!   key = "string" | number | true | false | [number, number, ...]
//!   [table]            keys that follow belong to it
//!   [[table]]          a new element of an array of tables
//!   # comment
//!
//! Strings are basic strings with \" and \\ escapes. Anything else is a syntax error with a
//! line number. (oEZ only reads config; meta.toml is written by `record.zig`.)

const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    number: f64,
    boolean: bool,
    numbers: []const f64,
};

pub const Entry = struct {
    /// "" for top-level keys, else the table's name.
    table: []const u8,
    /// Which `[[table]]` element this key belongs to (0 for `[table]` and the top level).
    index: usize,
    key: []const u8,
    value: Value,
    line: usize,
};

pub const Document = struct {
    entries: []const Entry,

    /// The value of a top-level or `[table]` key, if present with that type.
    pub fn get(self: Document, table: []const u8, index: usize, key: []const u8) ?Value {
        for (self.entries) |e| {
            if (e.index == index and std.mem.eql(u8, e.table, table) and std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }
    pub fn string(self: Document, table: []const u8, index: usize, key: []const u8) ?[]const u8 {
        return switch (self.get(table, index, key) orelse return null) {
            .string => |s| s,
            else => null,
        };
    }
    pub fn number(self: Document, table: []const u8, index: usize, key: []const u8) ?f64 {
        return switch (self.get(table, index, key) orelse return null) {
            .number => |n| n,
            else => null,
        };
    }
    pub fn boolean(self: Document, table: []const u8, index: usize, key: []const u8) ?bool {
        return switch (self.get(table, index, key) orelse return null) {
            .boolean => |b| b,
            else => null,
        };
    }
    pub fn numbers(self: Document, table: []const u8, index: usize, key: []const u8) ?[]const f64 {
        return switch (self.get(table, index, key) orelse return null) {
            .numbers => |n| n,
            else => null,
        };
    }
    /// How many `[[table]]` elements there are.
    pub fn count(self: Document, table: []const u8) usize {
        var n: usize = 0;
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.table, table)) n = @max(n, e.index + 1);
        }
        return n;
    }
};

pub const Error = error{ Syntax, OutOfMemory };

/// Where the last syntax error was (1-based line), for the caller's message.
pub var error_line: usize = 0;

fn stripComment(line: []const u8) []const u8 {
    var in_string = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_string) {
            if (c == '\\') i += 1 else if (c == '"') in_string = false;
        } else if (c == '"') {
            in_string = true;
        } else if (c == '#') return line[0..i];
    }
    return line;
}

fn parseValue(arena: std.mem.Allocator, text: []const u8) Error!Value {
    if (text.len == 0) return error.Syntax;
    if (text[0] == '"') {
        if (text.len < 2 or text[text.len - 1] != '"') return error.Syntax;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 1;
        while (i < text.len - 1) : (i += 1) {
            var c = text[i];
            if (c == '\\') {
                i += 1;
                if (i >= text.len - 1) return error.Syntax;
                c = switch (text[i]) {
                    '"' => '"',
                    '\\' => '\\',
                    'n' => '\n',
                    't' => '\t',
                    else => return error.Syntax,
                };
            } else if (c == '"') return error.Syntax;
            try out.append(arena, c);
        }
        return .{ .string = try out.toOwnedSlice(arena) };
    }
    if (std.mem.eql(u8, text, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, text, "false")) return .{ .boolean = false };
    if (text[0] == '[') {
        if (text[text.len - 1] != ']') return error.Syntax;
        var list: std.ArrayList(f64) = .empty;
        var it = std.mem.tokenizeAny(u8, text[1 .. text.len - 1], ", \t");
        while (it.next()) |tok| try list.append(arena, std.fmt.parseFloat(f64, tok) catch return error.Syntax);
        return .{ .numbers = try list.toOwnedSlice(arena) };
    }
    return .{ .number = std.fmt.parseFloat(f64, text) catch return error.Syntax };
}

/// Parses `text`. Everything returned lives in `arena`.
pub fn parse(arena: std.mem.Allocator, text: []const u8) Error!Document {
    var entries: std.ArrayList(Entry) = .empty;
    var table: []const u8 = "";
    var index: usize = 0;
    // Element counts of the arrays of tables seen so far.
    var counts: std.ArrayList(struct { name: []const u8, n: usize }) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        error_line = line_no;
        const line = std.mem.trim(u8, stripComment(raw), " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            const array = std.mem.startsWith(u8, line, "[[");
            const open: usize = if (array) 2 else 1;
            if (line.len < 2 * open + 1 or !std.mem.endsWith(u8, line, if (array) "]]" else "]")) return error.Syntax;
            const name = std.mem.trim(u8, line[open .. line.len - open], " \t");
            if (name.len == 0) return error.Syntax;
            table = try arena.dupe(u8, name);
            index = 0;
            if (array) {
                for (counts.items) |*c| {
                    if (std.mem.eql(u8, c.name, name)) {
                        index = c.n;
                        c.n += 1;
                        break;
                    }
                } else try counts.append(arena, .{ .name = table, .n = 1 });
            }
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.Syntax;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) return error.Syntax;
        const value = try parseValue(arena, std.mem.trim(u8, line[eq + 1 ..], " \t"));
        try entries.append(arena, .{ .table = table, .index = index, .key = try arena.dupe(u8, key), .value = value, .line = line_no });
    }
    return .{ .entries = try entries.toOwnedSlice(arena) };
}

const testing = std.testing;

test "parses keys, tables and arrays of tables" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(),
        \\# oEZ config
        \\monitor = "DP-2"   # the neural display
        \\tearing = true
        \\margin_ms = 3.5
        \\
        \\[[panel]]
        \\name = "Port \"B\" # not a comment"
        \\source = "B1"
        \\rect = [0.0, 0.0, 0.5, 1]
        \\
        \\[[panel]]
        \\name = "Port A"
        \\rect = [0.5,0,0.5,1.0]
        \\scale = 250
        \\
        \\[audio]
        \\enabled = false
    );
    try testing.expectEqualStrings("DP-2", doc.string("", 0, "monitor").?);
    try testing.expectEqual(true, doc.boolean("", 0, "tearing").?);
    try testing.expectEqual(3.5, doc.number("", 0, "margin_ms").?);
    try testing.expectEqual(2, doc.count("panel"));
    try testing.expectEqualStrings("Port \"B\" # not a comment", doc.string("panel", 0, "name").?);
    try testing.expectEqualSlices(f64, &.{ 0.0, 0.0, 0.5, 1.0 }, doc.numbers("panel", 0, "rect").?);
    try testing.expectEqualStrings("Port A", doc.string("panel", 1, "name").?);
    try testing.expectEqual(250, doc.number("panel", 1, "scale").?);
    try testing.expectEqual(null, doc.string("panel", 1, "source"));
    try testing.expectEqual(false, doc.boolean("audio", 0, "enabled").?);
    try testing.expectEqual(null, doc.number("", 0, "monitor")); // wrong type
    try testing.expectEqual(0, doc.count("nothing"));
}

test "reports the line of a syntax error" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.Syntax, parse(arena_state.allocator(), "a = 1\nb = \"unterminated\nc = 2"));
    try testing.expectEqual(2, error_line);
    try testing.expectError(error.Syntax, parse(arena_state.allocator(), "a = 1\n\n[[panel]\n"));
    try testing.expectEqual(3, error_line);
    try testing.expectError(error.Syntax, parse(arena_state.allocator(), "rect = [0, x]"));
}
