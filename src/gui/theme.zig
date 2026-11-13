//! Every colour the GUI draws with, by what it means. Text and quads take `Colour`
//! (8-bit RGBA, alpha blended); the display's fills (`gpu.Fill`) take `[4]f32` and replace
//! the pixels they cover.
//!
//! Some values are close to others (several ambers, two blue tints, two dark oranges, two
//! reds). They are kept apart on purpose until someone decides they should be one: each
//! name here says what it colours, not that it is the only colour of its kind.
//!
//! The trace colours themselves are not here: `shaders/traces.vert` has its own palette
//! (four colours by channel, an amber pull for off-scale columns, red at the converter's
//! limits). Constants that must match a value outside this file say so.

const Colour = @import("font.zig").Colour;

// Text.

/// Headings, panel titles, button labels, values that matter.
pub const text_bright: Colour = .{ 225, 230, 240, 255 };
/// Everything else: notes to the user, row labels, axis labels, read-outs.
pub const text_dim: Colour = .{ 150, 160, 178, 255 };
/// Something to look at: blocks the display skipped, the disk behind, a failed recording.
pub const text_warn: Colour = .{ 255, 190, 90, 255 };
/// "REC" while recording.
pub const text_rec: Colour = .{ 255, 96, 96, 255 };
/// The dark box behind a label on the display, so it reads over the traces.
pub const label_backing: Colour = .{ 8, 10, 14, 200 };

// The channels listened to.

/// A row listened to: its label on the display, and its spike tile's frame, name and
/// waveforms.
pub const heard: Colour = .{ 255, 225, 120, 255 };

// Display: overlays on the traces.

/// A row with a scale of its own: the scale beside its label.
pub const row_scale_text: Colour = .{ 255, 205, 120, 255 };
/// A note: the line where it was stamped (the colour of `heard`, let through a little so
/// the traces show behind it). The note's text beside the line is `heard` itself.
pub const note_line: Colour = .{ heard[0], heard[1], heard[2], 190 };
/// The note being typed, bottom left.
pub const note_draft_text: Colour = .{ 255, 235, 170, 255 };
/// A TTL line was high: the wash over a scrolling or sweep panel while its tint line was
/// high, and over a triggered panel where the trigger line was high in the newest sweep
/// (the laser).
pub const tint_pulse: Colour = .{ 90, 150, 255, 30 };

// Display: triggered sweeps.

/// The vertical line at the trigger (t0).
pub const trigger_line: Colour = .{ 200, 210, 230, 150 };
/// A slope trigger's level: the dashed line across its row.
pub const trigger_level: Colour = .{ 255, 205, 120, 200 };

// Display: bars and badges.

/// An alarm (samples lost, the recording failed): the bar across the display, and the row
/// behind the alarm's text in the control window.
pub const alarm_bar: Colour = .{ 190, 25, 25, 245 };
/// The warning bar (the disk falling behind), and the REVIEW badge at the top of the
/// display.
pub const warning_bar: Colour = .{ 150, 100, 10, 235 };
/// The text on the alarm and warning bars.
pub const bar_text: Colour = .{ 255, 255, 255, 255 };
/// "press a to acknowledge" on the alarm bar.
pub const alarm_hint_text: Colour = .{ 255, 210, 210, 255 };
/// The REVIEW badge's text.
pub const review_badge_text: Colour = .{ 255, 240, 200, 255 };

// Display: fills (`gpu.Fill`, `[4]f32`).

/// The display's background, where the sweep cursor blanks the stretch ahead of it.
/// Also the render pass's clear colour (`gpu.zig`).
pub const background: [4]f32 = .{ 0.04, 0.045, 0.055, 1.0 };
/// The sweep cursor: the line at the newest sample.
pub const sweep_cursor: [4]f32 = .{ 0.45, 0.48, 0.55, 1.0 };
/// The line along a panel's left and top edges where they are not the display's.
pub const panel_divider: [4]f32 = .{ 0.22, 0.24, 0.28, 1.0 };
/// The bar along the top of the panel that input goes to.
pub const target_bar: [4]f32 = .{ 0.30, 0.55, 0.95, 1.0 };

// Spike tiles.

pub const tile_bg: Colour = .{ 17, 19, 25, 255 };
/// The tile under the pointer.
pub const tile_bg_hover: Colour = .{ 26, 29, 38, 255 };
/// The waveforms of a channel not listened to (their alpha is set per waveform). The
/// display's first trace colour: `palette[0]` in `shaders/traces.vert`,
/// `vec3(0.55, 0.85, 1.0)`, is 140.25, 216.75, 255 in 8 bits; this is it rounded.
pub const tile_wave: Colour = .{ 140, 217, 255, 255 };
/// The detection threshold across a tile.
pub const tile_threshold: Colour = .{ 225, 80, 75, 210 };

// Control window (`ui.zig` widgets).

pub const button_idle: Colour = .{ 38, 43, 54, 255 };
pub const button_hover: Colour = .{ 56, 64, 82, 255 };
/// A button that is on (a toggle, the chosen one of a choice).
pub const button_on: Colour = .{ 52, 96, 170, 255 };
pub const button_on_hover: Colour = .{ 66, 116, 200, 255 };
/// The line between sections.
pub const rule: Colour = .{ 48, 52, 62, 255 };
