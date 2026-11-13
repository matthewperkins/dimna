//! A small immediate-mode widget layer over `font.Batch`: text, buttons and steppers laid
//! out left to right in rows. Each frame the whole interface is described again; a widget
//! reports a click in the same call that draws it.

const std = @import("std");
const font = @import("font.zig");
const theme = @import("theme.zig");

pub const Colour = font.Colour;

pub const Ui = struct {
    batch: *font.Batch,
    /// Pointer position in pixels, and whether the left button went down this frame.
    mouse_x: f32,
    mouse_y: f32,
    clicked: bool,
    /// Wheel movement this frame (axis units; a click is about 15), for steppers.
    wheel: f32 = 0,
    /// Where the next widget goes.
    x: f32 = 0,
    y: f32 = 0,
    left: f32 = 12,
    width: f32,
    /// Where a row continues when its widgets do not fit the window's width.
    indent: f32 = 64,

    pub fn begin(batch: *font.Batch, width: f32, mouse_x: f32, mouse_y: f32, clicked: bool, wheel: f32) Ui {
        batch.clear();
        return .{ .batch = batch, .mouse_x = mouse_x, .mouse_y = mouse_y, .clicked = clicked, .wheel = wheel, .x = 12, .y = 10, .width = width };
    }

    fn lineHeight(self: *const Ui) f32 {
        return @round(self.batch.font.line_height);
    }

    /// Height of a row of widgets.
    pub fn rowHeight(self: *const Ui) f32 {
        return self.lineHeight() + 12;
    }

    pub fn newline(self: *Ui) void {
        self.x = self.left;
        self.y += self.rowHeight();
    }

    pub fn space(self: *Ui, px: f32) void {
        self.x += px;
    }

    /// Moves to column `px` from the left edge, if not already past it.
    pub fn column(self: *Ui, px: f32) void {
        self.x = @max(self.x, self.left + px);
    }

    /// Starts a continuation row if a widget `w` wide would not fit on this one.
    fn fit(self: *Ui, w: f32) void {
        if (self.x + w > self.width - 8 and self.x > self.left + self.indent + 1) {
            self.newline();
            self.x = self.left + self.indent;
        }
    }

    fn buttonWidth(self: *const Ui, label: []const u8) f32 {
        return @round(self.batch.font.width(label)) + 18;
    }

    pub fn separator(self: *Ui) void {
        self.batch.rect(self.left, self.y + 2, self.width - 2 * self.left, 1, theme.rule);
        self.y += 8;
        self.x = self.left;
    }

    pub fn text(self: *Ui, string: []const u8, colour: Colour) void {
        self.x = self.batch.text(self.x, self.y + 4, string, colour) + 8;
    }

    /// Text in a box at least `min_width` wide (so what follows does not move as it changes).
    pub fn value(self: *Ui, string: []const u8, min_width: f32) void {
        const w = @max(min_width, self.batch.font.width(string));
        _ = self.batch.text(self.x + (w - self.batch.font.width(string)) / 2, self.y + 4, string, theme.text_bright);
        self.x += w + 6;
    }

    fn hovering(self: *const Ui, x: f32, y: f32, w: f32, h: f32) bool {
        return self.mouse_x >= x and self.mouse_x < x + w and self.mouse_y >= y and self.mouse_y < y + h;
    }

    /// A button; `on` draws it highlighted (a selected choice). True when clicked.
    pub fn button(self: *Ui, label: []const u8, on: bool) bool {
        const w = self.buttonWidth(label);
        const h = self.lineHeight() + 8;
        self.fit(w);
        const hot = self.hovering(self.x, self.y, w, h);
        self.batch.rect(self.x, self.y, w, h, if (on) (if (hot) theme.button_on_hover else theme.button_on) else if (hot) theme.button_hover else theme.button_idle);
        _ = self.batch.text(self.x + 9, self.y + 4, label, theme.text_bright);
        self.x += w + 6;
        return hot and self.clicked;
    }

    /// A small toggle (a row number, say) of a fixed width, so a run of them lines up.
    pub fn chip(self: *Ui, label: []const u8, on: bool) bool {
        const w: f32 = 30;
        const h = self.lineHeight() + 8;
        self.fit(w);
        const hot = self.hovering(self.x, self.y, w, h);
        self.batch.rect(self.x, self.y, w, h, if (on) (if (hot) theme.button_on_hover else theme.button_on) else if (hot) theme.button_hover else theme.button_idle);
        _ = self.batch.text(self.x + (w - self.batch.font.width(label)) / 2, self.y + 4, label, if (on) theme.text_bright else theme.text_dim);
        self.x += w + 3;
        return hot and self.clicked;
    }

    /// "label  [-] value [+]". Returns -1 or +1 when a button is clicked or the wheel turns
    /// over it, else 0.
    pub fn stepper(self: *Ui, label: []const u8, string: []const u8, value_width: f32) i32 {
        const value_w = @max(value_width, self.batch.font.width(string));
        self.fit((if (label.len > 0) self.batch.font.width(label) + 8 else 0) + self.buttonWidth("-") + self.buttonWidth("+") + 12 + value_w + 6);
        const x0 = self.x;
        if (label.len > 0) self.text(label, theme.text_dim);
        var step: i32 = 0;
        if (self.button("-", false)) step = -1;
        self.value(string, value_width);
        if (self.button("+", false)) step = 1;
        if (step == 0 and self.wheel != 0 and self.hovering(x0, self.y, self.x - x0, self.lineHeight() + 8)) step = if (self.wheel < 0) 1 else -1;
        self.x += 10;
        return step;
    }
};

// ---- Tests ----
//
// A font made by hand, without FreeType: every character 8 pixels wide and without a
// bitmap, lines 16 pixels high. Text then adds no quads, so every quad in the batch is a
// widget's rectangle.

const testing = std.testing;

var test_atlas: [1]u8 = .{0};
const test_font: font.Font = .{ .atlas = &test_atlas, .px = 14, .ascent = 12, .line_height = 16, .glyphs = @splat(.{ .advance = 8 }) };

const TestBatch = struct {
    vertices: [64 * 6]font.Vertex = undefined,
    batch: font.Batch = undefined,

    fn ui(self: *TestBatch, width: f32, mouse_x: f32, mouse_y: f32, clicked: bool, wheel: f32) Ui {
        self.batch = .{ .font = &test_font, .vertices = &self.vertices };
        return .begin(&self.batch, width, mouse_x, mouse_y, clicked, wheel);
    }

    /// The `i`-th rectangle drawn, as x, y, w, h.
    fn rect(self: *const TestBatch, i: usize) [4]f32 {
        const v = self.vertices[i * 6 ..][0..6];
        return .{ v[0].pos[0], v[0].pos[1], v[2].pos[0] - v[0].pos[0], v[2].pos[1] - v[0].pos[1] };
    }

    fn count(self: *const TestBatch) usize {
        return self.batch.len / 6;
    }
};

test "a button's rectangle: its label's width plus 18, a line plus 8 high, then a 6-pixel gap" {
    var tb: TestBatch = .{};
    var ui = tb.ui(800, -1, -1, false, 0);
    try testing.expectEqual(28, ui.rowHeight());
    try testing.expect(!ui.button("ab", false));
    try testing.expectEqual([4]f32{ 12, 10, 34, 24 }, tb.rect(0));
    try testing.expectEqual(52, ui.x);
    _ = ui.button("Record", true);
    try testing.expectEqual([4]f32{ 52, 10, 66, 24 }, tb.rect(1));
    try testing.expectEqual(124, ui.x);
    // A chip is 30 wide whatever its label, with a 3-pixel gap.
    _ = ui.chip("12345", false);
    try testing.expectEqual([4]f32{ 124, 10, 30, 24 }, tb.rect(2));
    try testing.expectEqual(157, ui.x);
    // Text moves on by its width plus 8; a value box by at least its minimum width plus 6.
    ui.text("abc", theme.text_dim);
    try testing.expectEqual(157 + 24 + 8, ui.x);
    ui.value("ab", 50);
    try testing.expectEqual(157 + 32 + 56, ui.x);
    ui.value("abcdefgh", 50);
    try testing.expectEqual(157 + 32 + 56 + 70, ui.x);
    try testing.expectEqual(3, tb.count());

    ui.newline();
    try testing.expectEqual(12, ui.x);
    try testing.expectEqual(38, ui.y);
    ui.column(100);
    try testing.expectEqual(112, ui.x);
    ui.column(50); // already past it
    try testing.expectEqual(112, ui.x);
    ui.space(5);
    try testing.expectEqual(117, ui.x);
    ui.separator();
    try testing.expectEqual([4]f32{ 12, 40, 776, 1 }, tb.rect(3));
    try testing.expectEqual(46, ui.y);
    try testing.expectEqual(12, ui.x);
}

test "a row of chips wraps to an indented continuation row" {
    var tb: TestBatch = .{};
    // 200 wide: a widget must end by x = 192. Chips step by 33 from x = 12.
    var ui = tb.ui(200, -1, -1, false, 0);
    for (0..11) |_| _ = ui.chip("1", false);
    const want = [_][2]f32{
        .{ 12, 10 },  .{ 45, 10 },  .{ 78, 10 },  .{ 111, 10 }, .{ 144, 10 },
        .{ 76, 38 },  .{ 109, 38 }, .{ 142, 38 }, .{ 76, 66 },  .{ 109, 66 },
        .{ 142, 66 },
    };
    for (want, 0..) |xy, i| {
        const r = tb.rect(i);
        try testing.expectEqual(xy, [2]f32{ r[0], r[1] });
    }
    // A widget wider than the window starts one continuation row and is drawn there,
    // overflowing (it does not wrap again from the indent); the next one starts another.
    ui = tb.ui(100, -1, -1, false, 0);
    _ = ui.chip("1", false);
    _ = ui.chip("1", false);
    _ = ui.button("a long label", false);
    _ = ui.button("another long one", false);
    try testing.expectEqual(4, tb.count());
    try testing.expectEqual([2]f32{ 76, 38 }, [2]f32{ tb.rect(2)[0], tb.rect(2)[1] });
    try testing.expectEqual([2]f32{ 76, 66 }, [2]f32{ tb.rect(3)[0], tb.rect(3)[1] });
    // At the left edge nothing wraps, however wide.
    ui = tb.ui(50, -1, -1, false, 0);
    _ = ui.button("a long label", false);
    try testing.expectEqual([2]f32{ 12, 10 }, [2]f32{ tb.rect(0)[0], tb.rect(0)[1] });
}

test "a button is clicked when the pointer is inside it as the button goes down" {
    var tb: TestBatch = .{};
    // The button "ab" spans x 12 to 46, y 10 to 34 (right and bottom edges excluded).
    const cases = [_]struct { x: f32, y: f32, clicked: bool, want: bool }{
        .{ .x = 12, .y = 10, .clicked = true, .want = true },
        .{ .x = 45.9, .y = 33.9, .clicked = true, .want = true },
        .{ .x = 46, .y = 20, .clicked = true, .want = false },
        .{ .x = 20, .y = 34, .clicked = true, .want = false },
        .{ .x = 11.9, .y = 20, .clicked = true, .want = false },
        .{ .x = 20, .y = 20, .clicked = false, .want = false },
    };
    for (cases) |c| {
        var ui = tb.ui(800, c.x, c.y, c.clicked, 0);
        try testing.expectEqual(c.want, ui.button("ab", false));
    }
    // Only the button under the pointer reports the click.
    var ui = tb.ui(800, 60, 20, true, 0);
    try testing.expect(!ui.button("ab", false));
    try testing.expect(ui.button("cd", false));
    try testing.expect(!ui.chip("1", false));
}

test "a stepper steps on its buttons and on the wheel over it" {
    var tb: TestBatch = .{};
    // "gain" text 12..44 (x then 52), "-" 52..78, value 84..124, "+" 130..156, then x = 172.
    const Case = struct { x: f32, y: f32, clicked: bool, wheel: f32, want: i32 };
    const cases = [_]Case{
        .{ .x = 60, .y = 20, .clicked = true, .wheel = 0, .want = -1 },
        .{ .x = 140, .y = 20, .clicked = true, .wheel = 0, .want = 1 },
        .{ .x = 100, .y = 20, .clicked = true, .wheel = 0, .want = 0 },
        .{ .x = 60, .y = 20, .clicked = false, .wheel = 0, .want = 0 },
        // The wheel anywhere over it, label included: up (negative) steps up.
        .{ .x = 20, .y = 20, .clicked = false, .wheel = -15, .want = 1 },
        .{ .x = 100, .y = 20, .clicked = false, .wheel = 15, .want = -1 },
        .{ .x = 300, .y = 20, .clicked = false, .wheel = -15, .want = 0 },
        .{ .x = 100, .y = 40, .clicked = false, .wheel = -15, .want = 0 },
    };
    for (cases) |c| {
        var ui = tb.ui(800, c.x, c.y, c.clicked, c.wheel);
        try testing.expectEqual(c.want, ui.stepper("gain", "1.0", 40));
        try testing.expectEqual(172, ui.x);
        try testing.expectEqual([4]f32{ 52, 10, 26, 24 }, tb.rect(0));
        try testing.expectEqual([4]f32{ 130, 10, 26, 24 }, tb.rect(1));
    }
    // A stepper that does not fit moves to the continuation row as a whole.
    var ui = tb.ui(300, -1, -1, false, 0);
    // It needs 150 (label 40, buttons 26 + 26, value 40, gaps 18) and must end by 292.
    ui.column(100);
    ui.space(40); // x = 152: 152 + 150 > 292
    _ = ui.stepper("gain", "1.0", 40);
    try testing.expectEqual([4]f32{ 76 + 40, 38, 26, 24 }, tb.rect(0));
    try testing.expectEqual([4]f32{ 76 + 118, 38, 26, 24 }, tb.rect(1));
}
