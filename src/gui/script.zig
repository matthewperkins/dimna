//! Scripted input for tests: steps that are fed into the display's input as if the user
//! had made them. It goes in above the compositor's seat, so it tests what the program does
//! with input, not whether real input arrives.

const std = @import("std");
const Input = @import("window.zig").Input;
const Display = @import("display.zig").Display;

/// Adds the script steps that are due at `elapsed_s` to `in`. `pos` is the script cursor.
/// `panel=N` (1-based) and `pointer=FX,FY` (fractions of the display) choose the panel that
/// input goes to, as moving the pointer would.
pub fn runScript(script: []const u8, pos: *usize, elapsed_s: f64, in: *Input, display: *Display) void {
    while (pos.* < script.len) {
        const rest = script[pos.*..];
        const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const step = rest[0..end];
        const colon = std.mem.indexOfScalar(u8, step, ':') orelse {
            pos.* += @min(end + 1, rest.len);
            continue;
        };
        const at = std.fmt.parseFloat(f64, step[0..colon]) catch 0;
        if (at > elapsed_s) return;
        const what = step[colon + 1 ..];
        if (std.mem.startsWith(u8, what, "cwheel=")) {
            // Ctrl+wheel.
            in.scroll_y += std.fmt.parseFloat(f64, what[7..]) catch 0;
            in.ctrl = true;
        } else if (std.mem.startsWith(u8, what, "wheel=")) {
            in.scroll_y += std.fmt.parseFloat(f64, what[6..]) catch 0;
        } else if (std.mem.startsWith(u8, what, "hwheel=")) {
            in.scroll_x += std.fmt.parseFloat(f64, what[7..]) catch 0;
        } else if (std.mem.startsWith(u8, what, "pinch=")) {
            in.pinch *= std.fmt.parseFloat(f64, what[6..]) catch 1;
        } else if (std.mem.startsWith(u8, what, "panel=")) {
            const n = std.fmt.parseInt(usize, what[6..], 10) catch 1;
            display.scripted_target = std.math.clamp(n, 1, @max(display.set.len, 1)) - 1;
        } else if (std.mem.startsWith(u8, what, "type=")) {
            // Text as typed (for notes).
            const t = what[5..];
            const n = @min(t.len, in.text.len - in.text_len);
            @memcpy(in.text[in.text_len..][0..n], t[0..n]);
            in.text_len += n;
        } else if (std.mem.eql(u8, what, "enter") or std.mem.eql(u8, what, "esc") or std.mem.eql(u8, what, "tab") or std.mem.eql(u8, what, "backspace")) {
            if (in.num_keys < in.keys.len) {
                in.keys[in.num_keys] = if (what[0] == 'e' and what[1] == 'n') .enter else if (what[0] == 'e') .escape else if (what[0] == 't') .tab else .backspace;
                in.num_keys += 1;
            }
        } else if (std.mem.eql(u8, what, "space") or std.mem.eql(u8, what, "home") or std.mem.eql(u8, what, "end") or std.mem.eql(u8, what, "pgup") or std.mem.eql(u8, what, "pgdn") or std.mem.eql(u8, what, "left") or std.mem.eql(u8, what, "right")) {
            if (in.num_keys < in.keys.len) {
                in.keys[in.num_keys] = switch (what[0]) {
                    's' => .space,
                    'h' => .home,
                    'e' => .end,
                    'l' => .left,
                    'r' => .right,
                    else => if (what[2] == 'u') .page_up else .page_down,
                };
                in.num_keys += 1;
            }
        } else if (std.mem.eql(u8, what, "click")) {
            in.clicks += 1;
        } else if (std.mem.eql(u8, what, "cclick")) {
            // Ctrl+click.
            in.clicks += 1;
            in.ctrl = true;
        } else if (std.mem.startsWith(u8, what, "pointer=")) {
            var it = std.mem.tokenizeScalar(u8, what[8..], ',');
            const fx = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            const fy = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            if (display.set.at(fx, fy)) |i| display.scripted_target = i;
            display.pointer_fy = fy;
            display.scripted_pointer = true;
        } else for (what) |ch| {
            if (in.num_keys == in.keys.len) break;
            in.keys[in.num_keys] = switch (ch) {
                '[' => .left_bracket,
                ']' => .right_bracket,
                '-' => .minus,
                '=' => .equal,
                'r' => .r,
                'm' => .m,
                'f' => .f,
                't' => .t,
                's' => .s,
                'a' => .a,
                '/' => .slash,
                '`' => .grave,
                '\\' => .backslash,
                '9' => @enumFromInt(ch),
                '1'...'8' => @enumFromInt(ch),
                ',' => .comma,
                '.' => .dot,
                '\'' => .apostrophe,
                'q' => .q,
                else => continue,
            };
            in.num_keys += 1;
        }
        pos.* += @min(end + 1, rest.len);
    }
}
