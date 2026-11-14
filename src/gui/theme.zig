//! Every colour the GUI draws with, by what it means. Text and quads take `Colour`
//! (8-bit RGBA, alpha blended); the display's fills (`gpu.Fill`) take `[4]f32` and replace
//! the pixels they cover.
//!
//! Some values are close to others (several ambers, two blue tints, two dark oranges, two
//! reds). They are kept apart on purpose until someone decides they should be one: each
//! name here says what it colours, not that it is the only colour of its kind.
//!
//! The themed colours are `var`s holding today's values; `apply` replaces them once, at
//! startup, before any window or thread draws (a scheme taken from an image, `scheme.zig`).
//! The alarm colours (the alarm and warning bars, REC, the off-scale and converter-limit
//! marks on traces) are themed too: a scheme gives them the hues its image uses least, so
//! they clash with everything else. Focus, notes and the detection threshold are `const`
//! and never change. The four trace colours are `trace`, which `gpu.zig` pushes to
//! `shaders/traces.vert` with `off_scale` and `clip`. Constants that must match a value
//! outside this file say so.

const std = @import("std");
const Colour = @import("font.zig").Colour;
const scheme_mod = @import("scheme.zig");

/// The four trace colours, by channel & 3 (0..1 each).
pub var trace: [4][3]f32 = .{ .{ 0.55, 0.85, 1.0 }, .{ 1.0, 0.82, 0.45 }, .{ 0.6, 1.0, 0.65 }, .{ 1.0, 0.6, 0.75 } };
/// What an off-scale column of a trace is pulled towards (65 %).
pub var off_scale: [3]f32 = .{ 1.0, 0.62, 0.2 };
/// A column at the converter's limits (the amplifier or ADC saturated).
pub var clip: [3]f32 = .{ 1.0, 0.22, 0.18 };

const themed = .{
    "text_bright",     "text_dim",   "label_backing",   "help_backing",  "help_title",   "help_key",
    "help_text",       "background", "sweep_cursor",    "panel_divider", "target_bar",   "tile_bg",
    "tile_bg_hover",   "tile_wave",  "tile_range_text", "button_idle",   "button_hover", "button_on",
    "button_on_hover", "rule",       "heading_idle",    "heading_hover", "trace",        "off_scale",
    "clip",            "text_warn",  "text_rec",        "alarm_bar",     "warning_bar",  "alarm_hint_text",
};

/// Sets every themed colour from `s`. Call it once at startup, before anything draws.
pub fn apply(s: scheme_mod.Scheme) void {
    inline for (themed) |name| @field(@This(), name) = @field(s, name);
}

/// The colours in use, as a scheme.
pub fn current() scheme_mod.Scheme {
    var s: scheme_mod.Scheme = undefined;
    inline for (themed) |name| @field(s, name) = @field(@This(), name);
    return s;
}

test "apply sets every themed colour and current reads them back" {
    const saved = current();
    defer apply(saved);
    var s = saved;
    inline for (@typeInfo(scheme_mod.Scheme).@"struct".field_names) |name| {
        // Change every field to something no default has.
        const T = @TypeOf(@field(s, name));
        if (T == Colour) @field(s, name) = .{ 1, 2, 3, 77 } else if (T == [4]f32) @field(s, name) = .{ 0.5, 0.25, 0.125, 1 } else if (T == [3]f32) @field(s, name) = .{ 0.3, 0.6, 0.9 } else @field(s, name) = .{ .{ 0.1, 0.2, 0.3 }, .{ 0.4, 0.5, 0.6 }, .{ 0.7, 0.8, 0.9 }, .{ 0.15, 0.25, 0.35 } };
    }
    apply(s);
    try std.testing.expectEqualDeep(s, current());
    try std.testing.expectEqual(@as(u8, 77), tile_bg_hover[3]);
}

// Text.

/// Headings, panel titles, button labels, values that matter.
pub var text_bright: Colour = .{ 225, 230, 240, 255 };
/// Everything else: notes to the user, row labels, axis labels, read-outs.
pub var text_dim: Colour = .{ 150, 160, 178, 255 };
/// Something to look at: blocks the display skipped, the disk behind, a failed recording.
pub var text_warn: Colour = .{ 255, 190, 90, 255 };
/// "REC" while recording.
pub var text_rec: Colour = .{ 255, 96, 96, 255 };
/// The dark box behind a label on the display, so it reads over the traces.
pub var label_backing: Colour = .{ 8, 10, 14, 200 };

// The channels listened to.

/// The amber of the thing being looked at. It marks the channel in focus (its tile's
/// frame and its row's label) and a note (its text beside the marker line). Listening is
/// not marked by colour but by a note sign before the name.
pub const focus: Colour = .{ 255, 225, 120, 255 };
/// A note's text beside its marker line.
pub const note_text: Colour = focus;

// Display: overlays on the traces.

/// A row with a scale of its own: the scale beside its label.
pub const row_scale_text: Colour = .{ 255, 205, 120, 255 };
/// A note: the line where it was stamped (the colour of `focus`, let through a little so
/// the traces show behind it). The note's text beside the line is `note_text`.
pub const note_line: Colour = .{ focus[0], focus[1], focus[2], 190 };
/// The note being typed, bottom left.
pub const note_draft_text: Colour = .{ 255, 235, 170, 255 };
/// A TTL line was high: the wash over a scrolling or sweep panel while its tint line was
/// high, and over a triggered panel where the trigger line was high in the newest sweep
/// (the laser).
pub const tint_pulse: Colour = .{ 90, 150, 255, 30 };

// Display: triggered sweeps.

/// The vertical line at the trigger (t0).
pub const trigger_line: Colour = .{ 200, 210, 230, 150 };
/// A slope trigger's level: the dashed line across its row. It is the trigger channel's
/// detection threshold, so it is in the threshold's colour; the dashes say it is the
/// trigger's.
pub const trigger_level: Colour = tile_threshold;

// Display: bars and badges.

/// An alarm (samples lost, the recording failed): the bar across the display, and the row
/// behind the alarm's text in the control window.
pub var alarm_bar: Colour = .{ 190, 25, 25, 245 };
/// The warning bar (the disk falling behind), and the REVIEW badge at the top of the
/// display.
pub var warning_bar: Colour = .{ 150, 100, 10, 235 };
/// The text on the alarm and warning bars.
pub const bar_text: Colour = .{ 255, 255, 255, 255 };
/// "press Shift+a to acknowledge" on the alarm bar.
pub var alarm_hint_text: Colour = .{ 255, 210, 210, 255 };
/// The REVIEW badge's text.
pub const review_badge_text: Colour = .{ 255, 240, 200, 255 };

// Display: the key summary (`?`).

/// The box behind it: nearly opaque, so the traces do not show through the text.
pub var help_backing: Colour = .{ 14, 16, 22, 245 };
/// Its title and the two columns' headings.
pub var help_title: Colour = .{ 225, 230, 240, 255 };
/// A key or mouse action.
pub var help_key: Colour = .{ 150, 200, 255, 255 };
/// What it does.
pub var help_text: Colour = .{ 175, 184, 200, 255 };

// Display: fills (`gpu.Fill`, `[4]f32`).

/// The display's background, where the sweep cursor blanks the stretch ahead of it.
/// Also the render pass's clear colour (`gpu.zig`).
pub var background: [4]f32 = .{ 0.04, 0.045, 0.055, 1.0 };
/// The sweep cursor: the line at the newest sample.
pub var sweep_cursor: [4]f32 = .{ 0.45, 0.48, 0.55, 1.0 };
/// The line along a panel's left and top edges where they are not the display's.
pub var panel_divider: [4]f32 = .{ 0.22, 0.24, 0.28, 1.0 };
/// The bar along the top of the panel that input goes to.
pub var target_bar: [4]f32 = .{ 0.30, 0.55, 0.95, 1.0 };

// Spike tiles.

pub var tile_bg: Colour = .{ 17, 19, 25, 255 };
/// The tile under the pointer.
pub var tile_bg_hover: Colour = .{ 26, 29, 38, 255 };
/// The waveforms of a channel not listened to (their alpha is set per waveform). The
/// display's first trace colour: `trace[0]`, `vec3(0.55, 0.85, 1.0)` by default, is 140.25,
/// 216.75, 255 in 8 bits; this is it rounded.
pub var tile_wave: Colour = .{ 140, 217, 255, 255 };
/// The detection threshold across a tile.
pub const tile_threshold: Colour = .{ 225, 80, 75, 210 };
/// A tile's fixed range ("±150 µV"), bottom left: dimmer than the other read-outs.
pub var tile_range_text: Colour = .{ 115, 124, 140, 255 };
/// A fixed threshold's value ("-52 µV"), left of sigma: the red of the line, lightened to
/// read as text. A threshold that follows the noise shows no value.
pub const tile_threshold_text: Colour = .{ 240, 130, 120, 255 };

// Control window (`ui.zig` widgets).

pub var button_idle: Colour = .{ 38, 43, 54, 255 };
pub var button_hover: Colour = .{ 56, 64, 82, 255 };
/// A button that is on (a toggle, the chosen one of a choice).
pub var button_on: Colour = .{ 52, 96, 170, 255 };
pub var button_on_hover: Colour = .{ 66, 116, 200, 255 };
/// The line between sections.
pub var rule: Colour = .{ 48, 52, 62, 255 };
/// A section's heading, which opens and closes it: flatter than a button.
pub var heading_idle: Colour = .{ 26, 30, 38, 255 };
pub var heading_hover: Colour = .{ 48, 55, 70, 255 };
