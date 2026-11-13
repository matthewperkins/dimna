//! Scripted input for tests: steps that are fed into the display's input as if the user
//! had made them. It goes in above the compositor's seat, so it tests what the program does
//! with input, not whether real input arrives.
//!
//! `--script "SECONDS:STEP;SECONDS:STEP;..."`, where STEP is one of
//!   wheel=N, hwheel=N, cwheel=N     wheel, sideways, Ctrl+wheel (axis units, 15 = one click)
//!   swheel=N, awheel=N              Shift+wheel (back and forth in time), Alt+wheel (time base)
//!   pinch=F                         a pinch by that scale factor
//!   pointer=FX,FY, panel=N          put the pointer there (fractions of the display), or on
//!                                   panel N (1-based)
//!   move=FX,FY                      move the pointer there (as pointer=; for a drag)
//!   click, cclick                   a left click, a Ctrl+left click
//!   press, release                  press the left button and hold it (from then on every
//!                                   turn has it down, as dragging does), let it go
//!   rclick, crclick, mclick         a right click, a Ctrl+right click, a middle click
//!   type=TEXT                       typed text
//!   enter, esc, tab, backspace, space, left, right, pgup, pgdn, home, end
//!   or keys such as "]]==" (any of [ ] - = r m f t s a n l / ` 1-9 , . ' q, and A for
//!   Shift+a). ';' separates steps, so the ';' key itself cannot be scripted.

const std = @import("std");
const Input = @import("window.zig").Input;
const Display = @import("display.zig").Display;

/// Adds the script steps that are due at `elapsed_s` to `in`. `pos` is the script cursor.
/// `panel=N` (1-based) and `pointer=FX,FY` (fractions of the display) choose the panel that
/// input goes to, as moving the pointer would.
pub fn runScript(script: []const u8, pos: *usize, elapsed_s: f64, in: *Input, display: *Display) void {
    // A button pressed by the script stays down until it releases it.
    if (display.scripted_left) in.left_down = true;
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
        } else if (std.mem.startsWith(u8, what, "swheel=") or std.mem.startsWith(u8, what, "awheel=")) {
            // Shift+wheel, Alt+wheel.
            in.scroll_y += std.fmt.parseFloat(f64, what[7..]) catch 0;
            if (what[0] == 's') in.shift = true else in.alt = true;
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
        } else if (std.mem.eql(u8, what, "enter") or std.mem.eql(u8, what, "esc") or
            std.mem.eql(u8, what, "tab") or std.mem.eql(u8, what, "backspace"))
        {
            if (in.num_keys < in.keys.len) {
                in.keys[in.num_keys] = .{ .named = if (what[0] == 'e' and what[1] == 'n')
                    .enter
                else if (what[0] == 'e')
                    .escape
                else if (what[0] == 't')
                    .tab
                else
                    .backspace };
                in.num_keys += 1;
            }
        } else if (std.mem.eql(u8, what, "space") or std.mem.eql(u8, what, "home") or std.mem.eql(u8, what, "end") or
            std.mem.eql(u8, what, "pgup") or std.mem.eql(u8, what, "pgdn") or
            std.mem.eql(u8, what, "left") or std.mem.eql(u8, what, "right"))
        {
            if (in.num_keys < in.keys.len) {
                in.keys[in.num_keys] = switch (what[0]) {
                    's' => .{ .char = ' ' },
                    'h' => .{ .named = .home },
                    'e' => .{ .named = .end },
                    'l' => .{ .named = .left },
                    'r' => .{ .named = .right },
                    else => .{ .named = if (what[2] == 'u') .page_up else .page_down },
                };
                in.num_keys += 1;
            }
        } else if (std.mem.eql(u8, what, "click")) {
            in.clicks += 1;
        } else if (std.mem.eql(u8, what, "cclick")) {
            // Ctrl+click.
            in.clicks += 1;
            in.ctrl = true;
        } else if (std.mem.eql(u8, what, "rclick")) {
            in.right_clicks += 1;
        } else if (std.mem.eql(u8, what, "crclick")) {
            // Ctrl+right click.
            in.right_clicks += 1;
            in.ctrl = true;
        } else if (std.mem.eql(u8, what, "mclick")) {
            in.middle_clicks += 1;
        } else if (std.mem.eql(u8, what, "press")) {
            in.clicks += 1;
            in.left_down = true;
            display.scripted_left = true;
        } else if (std.mem.eql(u8, what, "release")) {
            in.left_down = false;
            display.scripted_left = false;
        } else if (std.mem.startsWith(u8, what, "pointer=") or std.mem.startsWith(u8, what, "move=")) {
            var it = std.mem.tokenizeScalar(u8, what[std.mem.indexOfScalar(u8, what, '=').? + 1 ..], ',');
            const fx = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            const fy = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            if (display.set.at(fx, fy)) |i| display.scripted_target = i;
            display.pointer_fy = fy;
            display.pointer_fx = fx;
            display.scripted_pointer = true;
        } else for (what) |ch| {
            if (in.num_keys == in.keys.len) break;
            // The keys that are shortcuts somewhere; anything else is not a key step.
            if (std.mem.indexOfScalar(u8, "[]-=rmftsanlA/`\\123456789,.'q", ch) == null) continue;
            // A is Shift+a: the key's character without modifiers, with Shift held (as
            // `window.zig` reports keys).
            if (ch == 'A') in.shift = true;
            in.keys[in.num_keys] = .{ .char = if (ch == 'A') 'a' else ch };
            in.num_keys += 1;
        }
        pos.* += @min(end + 1, rest.len);
    }
}
