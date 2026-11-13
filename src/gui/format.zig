//! Numbers with units, as the display and the control window show them, and the one way
//! labels are formatted.

const std = @import("std");
const Kind = @import("oez").panels.Kind;

/// Formats into `buf`. Text that does not fit is cut, at a character boundary (it never
/// ends inside a UTF-8 character); there is no error to handle. For labels, where a cut
/// label is better than none.
pub fn fmt(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print(f, args) catch return wholeCharacters(w.buffered()); // did not fit: cut
    return w.buffered();
}

/// `s` without a UTF-8 character that is cut off at its end.
fn wholeCharacters(s: []const u8) []const u8 {
    // The start of the last character: at most 3 continuation bytes back.
    var start = s.len;
    while (start > 0 and s.len - start < 4) {
        start -= 1;
        if (s[start] & 0xC0 != 0x80) break;
    }
    if (start == s.len) return s;
    const need = std.unicode.utf8ByteSequenceLength(s[start]) catch return s;
    return if (s.len - start < need) s[0..start] else s;
}

/// "500 ms" or "2.00 s".
pub fn fmtSpan(buf: []u8, s: f64) []const u8 {
    return if (s < 0.9995) fmt(buf, "{d:.0} ms", .{s * 1000}) else fmt(buf, "{d:.2} s", .{s});
}

/// A scale per row with a unit that keeps the number readable: "400 µV", "1.50 mV",
/// "250 mV", "5.00 V". `v` is in the kind's unit: µV for electrodes, V for aux and adc.
pub fn fmtScale(buf: []u8, kind: Kind, v: f64) []const u8 {
    return switch (kind) {
        .ttl => "",
        .electrode => if (v < 999.5) fmt(buf, "{d:.0} µV", .{v}) else fmt(buf, "{d:.2} mV", .{v / 1000}),
        .aux, .adc => if (v < 0.9995) fmt(buf, "{d:.0} mV", .{v * 1000}) else fmt(buf, "{d:.2} V", .{v}),
    };
}

const testing = std.testing;

test "fmt: what fits is formatted whole, what does not is cut at a character" {
    var buf: [8]u8 = undefined;
    // Exact fit.
    try testing.expectEqualStrings("12345678", fmt(&buf, "{d}", .{12345678}));
    try testing.expectEqualStrings("ab 400", fmt(&buf, "{s} {d}", .{ "ab", 400 }));
    // One byte short.
    try testing.expectEqualStrings("12345678", fmt(&buf, "{d}", .{123456789}));
    try testing.expectEqualStrings("display ", fmt(&buf, "display {d:.1} ms", .{4.25}));
    // "µ" is two bytes (C2 B5): with 7 bytes before it, it would end inside it.
    try testing.expectEqualStrings("1234567", fmt(&buf, "1234567{s}", .{"µV"}));
    try testing.expectEqualStrings("123456µ", fmt(&buf, "123456{s}", .{"µV"}));
    // A three-byte character (en dash, E2 80 93) cut after one and after two bytes.
    try testing.expectEqualStrings("1234567", fmt(&buf, "1234567\u{2013}", .{}));
    try testing.expectEqualStrings("123456", fmt(&buf, "123456\u{2013}", .{}));
    try testing.expectEqualStrings("12345\u{2013}", fmt(&buf, "12345\u{2013}x", .{}));
    // A four-byte character cut after three bytes.
    try testing.expectEqualStrings("12345", fmt(&buf, "12345\u{1F600}", .{}));
    // An empty buffer.
    try testing.expectEqualStrings("", fmt(buf[0..0], "{d}", .{1}));
    try testing.expectEqualStrings("", fmt(buf[0..0], "", .{}));
    // The result is in the buffer.
    const got = fmt(&buf, "{d}", .{42});
    try testing.expectEqual(@intFromPtr(&buf), @intFromPtr(got.ptr));
}

test "fmt: a cut never leaves an incomplete character, whatever the buffer's size" {
    const text = "a µV – b \u{1F600} c";
    var buf: [text.len]u8 = undefined;
    for (0..text.len + 1) |n| {
        const got = fmt(buf[0..n], "{s}", .{text});
        try testing.expect(std.unicode.utf8ValidateSlice(got));
        try testing.expect(std.mem.startsWith(u8, text, got));
        // Nothing more is cut than the character that did not fit.
        try testing.expect(got.len + 3 >= n);
    }
}

test "fmtScale picks the unit that keeps the number readable" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("400 µV", fmtScale(&buf, .electrode, 400));
    try testing.expectEqualStrings("1.50 mV", fmtScale(&buf, .electrode, 1500));
    try testing.expectEqualStrings("250 mV", fmtScale(&buf, .adc, 0.25));
    try testing.expectEqualStrings("5.00 V", fmtScale(&buf, .aux, 5));
    try testing.expectEqualStrings("", fmtScale(&buf, .ttl, 1));
}
