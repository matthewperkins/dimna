//! A small immediate-mode widget layer over `font.Batch`: text, buttons and steppers laid
//! out left to right in rows. Each frame the whole interface is described again; a widget
//! reports a click in the same call that draws it.

const std = @import("std");
const font = @import("font.zig");

pub const Colour = font.Colour;

pub const text_bright: Colour = .{ 225, 230, 240, 255 };
pub const text_dim: Colour = .{ 150, 160, 178, 255 };
pub const text_warn: Colour = .{ 255, 190, 90, 255 };
const button_idle: Colour = .{ 38, 43, 54, 255 };
const button_hover: Colour = .{ 56, 64, 82, 255 };
const button_on: Colour = .{ 52, 96, 170, 255 };
const button_on_hover: Colour = .{ 66, 116, 200, 255 };
const rule: Colour = .{ 48, 52, 62, 255 };

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
        self.batch.rect(self.left, self.y + 2, self.width - 2 * self.left, 1, rule);
        self.y += 8;
        self.x = self.left;
    }

    pub fn text(self: *Ui, string: []const u8, colour: Colour) void {
        self.x = self.batch.text(self.x, self.y + 4, string, colour) + 8;
    }

    /// Text in a box at least `min_width` wide (so what follows does not move as it changes).
    pub fn value(self: *Ui, string: []const u8, min_width: f32) void {
        const w = @max(min_width, self.batch.font.width(string));
        _ = self.batch.text(self.x + (w - self.batch.font.width(string)) / 2, self.y + 4, string, text_bright);
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
        self.batch.rect(self.x, self.y, w, h, if (on) (if (hot) button_on_hover else button_on) else if (hot) button_hover else button_idle);
        _ = self.batch.text(self.x + 9, self.y + 4, label, text_bright);
        self.x += w + 6;
        return hot and self.clicked;
    }

    /// "label  [-] value [+]". Returns -1 or +1 when a button is clicked or the wheel turns
    /// over it, else 0.
    pub fn stepper(self: *Ui, label: []const u8, string: []const u8, value_width: f32) i32 {
        const value_w = @max(value_width, self.batch.font.width(string));
        self.fit((if (label.len > 0) self.batch.font.width(label) + 8 else 0) + self.buttonWidth("-") + self.buttonWidth("+") + 12 + value_w + 6);
        const x0 = self.x;
        if (label.len > 0) self.text(label, text_dim);
        var step: i32 = 0;
        if (self.button("-", false)) step = -1;
        self.value(string, value_width);
        if (self.button("+", false)) step = 1;
        if (step == 0 and self.wheel != 0 and self.hovering(x0, self.y, self.x - x0, self.lineHeight() + 8)) step = if (self.wheel < 0) 1 else -1;
        self.x += 10;
        return step;
    }
};
