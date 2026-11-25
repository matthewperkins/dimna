//! Every text the user sees, in English. One `pub const` per message. A message with values
//! uses named placeholders (`{[left]s}`), so a translation can reorder them; it is formatted
//! with a struct of those names: `i18n.fmt(&buf, .disk_full_in, .{ .left = text })`. A
//! message about a number of things has a form per plural form (`rec_gaps_one`,
//! `rec_gaps_other`; see "Counted messages" in `i18n.zig`). Where a sentence holds two
//! numbers, it says "samples: 3" instead, so no language needs two plurals in one message.
//!
//! Not here: log messages, the command-line usage text, config keys, the contents of files
//! (recordings, events), window titles that compositor rules may match ("dimna", "dimna
//! control", "dimna spikes"), channel names ("A1-5", "TTL2", "AUX1"), and units (µV, ms, Hz).
//! See `i18n.zig` for how a language's file relates to this one.

// ---- Words shared by several windows ----

/// A switch that is on (buttons, summaries).
pub const toggle_on = "on";
/// A switch that is off, or a corner that is not set.
pub const toggle_off = "off";
/// Common average reference (a button, a heading, a badge).
pub const label_car = "CAR";
/// Beside a row of a filtered panel that is drawn unfiltered.
pub const tag_raw = "raw";
/// The control window's filter choice: no filter (beside "band").
pub const btn_raw = "raw";
pub const btn_all = "all";
pub const btn_none = "none";
pub const slope_rising = "rising";
pub const slope_falling = "falling";
/// The display modes of a panel (buttons, and the first word of its summary).
pub const mode_scroll = "scroll";
pub const mode_sweep = "sweep";
pub const mode_triggered = "triggered";
/// "6 presets" / "1 preset" (the control window's notes summary).
pub const presets_one = "{[count]d} preset";
pub const presets_other = "{[count]d} presets";
/// A filter's corners (the panel's band, the amplifier's band), beside their steppers.
pub const label_low = "low";
pub const label_high = "high";

// ---- The neural display: panel titles ----

/// After a title's band, when the common average reference is on.
pub const title_car = "   CAR";
/// A panel's filter in its title: both corners, only the low one, only the high one, none.
pub const title_band_range = "   {[low]d}-{[high]d} Hz{[car]s}";
pub const title_band_above = "   > {[low]d} Hz{[car]s}";
pub const title_band_below = "   < {[high]d} Hz{[car]s}";
pub const title_band_none = "   filter: no corners{[car]s}";
/// A triggered panel's title says "raw" where a band would be.
pub const title_raw = "   raw";
pub const title_raw_car = "   raw   CAR";
/// The scale of a panel's rows in its title and in the control window's summary.
pub const title_per_row = "   {[scale]s}/row";
/// "5 sweeps" after a triggered panel's title.
pub const title_sweeps_one = "   {[count]d} sweep{[waiting]s}";
pub const title_sweeps_other = "   {[count]d} sweeps{[waiting]s}";
pub const title_waiting_for_trigger = " (waiting for a trigger)";
pub const title_review = "   review";
pub const title_sweep = "   sweep";
/// What triggers a panel's sweeps, from a row of the display: "row 5 falling 4.5 σ" (before
/// the threshold is known) and "row 5 falling -62 µV".
pub const trigger_row_sigmas = "row {[row]d} {[slope]s} {[sigmas]d} σ";
pub const trigger_row_level = "row {[row]d} {[slope]s} {[uv]d:.0} µV";
/// Tip over a triggered panel's filter text when it is not the detector's band.
pub const tip_band_header = "These sweeps are drawn through this panel's filter: {[band]s}.";
pub const tip_band_none = "none (raw)";
pub const tip_band_line2 = "Spike detection and the slope trigger always use 300-6000 Hz,";
pub const tip_band_line3 = "so the sweeps may not look like the spike tiles' waveforms.";

// ---- The neural display: rows, banners, status ----

/// A row drawn with a threshold the row's band does not show.
pub const tag_threshold = "thr";
/// In review with nothing to draw yet, where the traces would be.
pub const waiting_overview = "building the overview of this stretch";
pub const waiting_reading = "reading the recording";
/// The alarm bar's second line.
pub const alarm_hint = "press Shift+a to acknowledge";
/// The review badge, top centre; `state` is one of the two messages after it, or empty.
pub const review_badge = "REVIEW   {[behind]d:.1} s behind live   at {[clock]s}{[state]s}   l = live";
pub const review_reading = "   (reading)";
pub const review_building = "   (building the overview)";
/// The note being typed, bottom left.
pub const note_draft = "note at {[clock]s}:  {[text]s}_";
/// Bottom right, when the display missed blocks.
pub const readout_skipped_one = "{[ms]d:.1} ms   {[fps]d} fps   display skipped {[blocks]d} block";
pub const readout_skipped_other = "{[ms]d:.1} ms   {[fps]d} fps   display skipped {[blocks]d} blocks";
/// The recording's clock beside it.
pub const readout_rec = "REC {[clock]s}";

// ---- The key summary (?) ----
// A text that is ASCII is drawn in the fixed-width font, any other in the ordinary one.

pub const help_title = "Keys and the mouse   (? or Esc closes this)";
pub const help_heading_display = "On the display";
pub const help_heading_tiles = "In the spike-tile window";

pub const key_wheel = "wheel";
pub const key_ctrl_wheel = "Ctrl+wheel";
pub const key_shift_wheel = "Shift+wheel";
pub const key_ctrl_shift_wheel = "Ctrl+Shift+wheel";
pub const key_sideways_scroll = "sideways scroll";
pub const key_alt_wheel = "Alt+wheel";
pub const key_touchpad_pinch = "touchpad pinch";
pub const key_minus_equals = "- =";
pub const key_brackets = "[ ]";
pub const key_r = "r";
pub const key_m = "m";
pub const key_f = "f";
pub const key_comma_period = ", .";
pub const key_semicolon_quote = "; '";
pub const key_t = "t";
pub const key_1_8 = "1-8";
pub const key_s = "s";
pub const key_left_click_row = "left-click a row";
pub const key_right_click_row = "right-click a row";
pub const key_ctrl_right_click = "Ctrl+right-click";
pub const key_middle_click = "middle-click";
pub const key_drag_red_line = "drag a red line";
pub const key_n = "n";
pub const key_space = "Space";
pub const key_left_right = "Left / Right";
pub const key_pgup_pgdn = "PgUp / PgDn";
pub const key_home_end = "Home / End";
pub const key_l = "l";
pub const key_slash = "/";
pub const key_backtick = "`";
pub const key_1_9 = "1-9";
pub const key_tilde = "~";
pub const key_shift_a = "Shift+a";
pub const key_question = "?";
pub const key_ctrl_q_or_esc = "Ctrl+Q or Esc";
pub const key_a = "a";
pub const key_u = "u";
pub const key_shift_u = "Shift+u";
pub const key_left_click = "left-click";
pub const key_right_click = "right-click";
pub const key_drag_the_red_line = "drag the red line";
pub const key_the_chips = "the chips";

pub const help_y_scale_uv = "Y scale (µV per row)";
pub const help_y_scale_row = "Y scale of the row alone";
pub const help_back_forward_review = "back / forward in time (review)";
pub const help_same_as_shift_wheel = "the same as Shift+wheel";
pub const help_time_base_window = "time base (triggered: window)";
pub const help_time_base = "time base";
pub const help_y_scale = "Y scale";
pub const help_panel_as_configured = "the panel as configured";
pub const help_scrolling_sweep = "scrolling <-> sweep";
pub const help_filter_toggle = "display filter on / off";
pub const help_low_corner = "low corner down / up";
pub const help_high_corner = "high corner down / up";
pub const help_triggered_toggle = "triggered sweeps on / off";
pub const help_triggered_line = "triggered on TTL: the line";
pub const help_triggered_source = "triggered: TTL <-> spikes, this row";
pub const help_focus_trigger = "focus (spikes: trigger there)";
pub const help_listen_alone = "listen to it alone";
pub const help_sound_add_take = "add to / take from the sound";
pub const help_no_focus = "no channel in focus";
pub const help_threshold_fixed_uv = "its threshold, fixed (µV)";
pub const help_threshold_fixed_noise = "threshold: fixed <-> the noise";
pub const help_freeze = "freeze / back to live";
pub const help_back_forward_tenth = "back / forward 1/10 window";
pub const help_back_forward_window = "back / forward a window";
pub const help_start_live = "start of recording / live";
pub const help_back_to_live = "back to live";
pub const help_type_note = "type a note (Enter saves)";
pub const help_stamp_draft = "stamp the first draft note";
pub const help_stamp_preset = "stamp a preset note";
pub const help_adc_toggle = "hide / show the ADC panels";
pub const help_acknowledge = "acknowledge an alarm";
pub const help_these_keys = "these keys (? or Esc closes)";
pub const help_quit = "quit";
pub const help_tiles_scale_shown = "scale the tiles shown";
pub const help_tiles_scale_one = "scale the tile alone";
pub const help_tiles_threshold = "the tile's threshold";
pub const help_tiles_common_range = "tiles shown: common range";
pub const help_tiles_own_range = "tiles shown: own range, fixed";
pub const help_undo_scale = "undo a change of scale";
pub const help_redo_scale = "redo a change of scale";
pub const help_focus_channel = "focus on that channel";
pub const help_tiles_chips = "one port's tiles, or all";

// ---- The spike-tile window ----

/// The chip that shows the tiles of every port.
pub const tiles_all = "All";
/// The range of the tiles shown, beside the chips: each tile on its own, or differing.
pub const tiles_range_auto = "auto";
pub const tiles_range_mixed = "mixed";

// ---- The control window: the title, status and recording ----

pub const btn_acknowledge = "Acknowledge";
pub const quit_heading = "Settings changed since they were last saved:";
pub const quit_recording_heading = "A recording is running. Quitting stops it; what has been recorded so far is kept.";
pub const btn_stop_recording_and_quit = "Stop recording and quit";
pub const btn_keep_recording = "Keep recording";
pub const notice_quit_recording = "A recording is running";
pub const notice_quit_recording_how = "Ctrl+Q again while this is shown stops it and quits";
pub const quit_panel_views = "panel views (saved to views.toml)";
pub const btn_save_and_quit = "Save as default and quit";
pub const btn_quit_without_saving = "Quit without saving";
pub const btn_cancel = "Cancel";
pub const status_display = "display {[ms]d:.1} ms   {[fps]d} fps   running {[seconds]d:.0} s";
pub const status_starting = "starting";
pub const status_display_skipped_one = "display skipped {[blocks]d} block";
pub const status_display_skipped_other = "display skipped {[blocks]d} blocks";
pub const status_ring_overflow = "ACQUISITION RING OVERFLOW {[count]d}";
pub const btn_save_view = "Save view";
pub const btn_quit = "Quit";
pub const btn_record = "Record";
pub const btn_stop_recording = "Stop recording";
pub const rec_finishing = "finishing the recording";
pub const rec_status = "REC {[clock]s}   {[gb]d:.2} GB   {[msamples]d:.1} M samples";
pub const rec_disk_behind = "disk is {[behind]d:.1} s behind";
pub const rec_gaps_one = "{[gaps]d} gap";
pub const rec_gaps_other = "{[gaps]d} gaps";
pub const rec_failed = "RECORDING FAILED";
pub const rec_idle = "not recording";
/// The line under Record about the disk, idle or recording ("about 8 h 20 min" is `left`).
pub const rec_disk_free = "disk: {[gb]d:.1} GB free, {[left]s} at this layout";
pub const rec_disk_too_full = "disk: {[gb]d:.1} GB free, at least {[need]d:.0} GB needed to record";
/// The line about the source, at the top.
pub const about_source = "{[source]s}   {[rate]d} Hz   channels: {[channels]d}, electrodes: {[electrodes]d}";
pub const source_simulated = "simulated board";
pub const source_board = "Open Ephys acquisition board";
/// The display window's title bar, refreshed once a second.
pub const window_title_status = "dimna   {[panel]s}: {[span]d:.2} s  {[scale]d:.1} {[unit]s}/row   latency {[ms]d:.1} ms   {[fps]d} fps";
/// The last line of the control window.
pub const hint_keys = "Press ? on the display for its keys and mouse actions, and the tile window's.";

// ---- The control window: notes and audio ----

pub const section_notes = "Notes";
pub const notes_summary_empty = "{[presets]s}   no notes yet";
pub const notes_summary_last = "{[presets]s}   last note {[clock]s}  {[text]s}";
pub const notes_hint = "on the display: / types a note, Enter saves it";
pub const notes_typing = "typing a note";
pub const notes_drafts_one = "{[count]d} draft (` stamps it)";
pub const notes_drafts_other = "{[count]d} drafts (` stamps one)";
pub const section_audio = "Audio";
pub const btn_mute = "mute";
pub const label_volume = "volume";
pub const btn_shaped = "shaped";
pub const btn_plain = "plain";
pub const btn_recalibrate = "recalibrate";
pub const audio_no_output = "no audio output";
pub const audio_listening = "listening to {[what]s}";
pub const audio_listening_nothing = "nothing (click a row on the display)";
pub const audio_noise_held = "noise {[sigma]d:.1} µV, held";
pub const audio_measuring = "measuring the noise (3 s)";
pub const audio_gaps_one = "{[count]d} gap in the sound";
pub const audio_gaps_other = "{[count]d} gaps in the sound";
pub const audio_muted = ", muted";
pub const audio_summary_off = "off{[muted]s}   {[db]d:.0} dB";
pub const audio_summary_nothing = "on{[muted]s}   {[db]d:.0} dB   listening to nothing";
pub const audio_summary_on = "on{[muted]s}   {[db]d:.0} dB   listening to {[what]s}   {[ms]d:.0} ms";

// ---- The control window: spikes and headstages ----

pub const section_spikes = "Spikes";
pub const label_threshold = "threshold";
pub const hint_below_zero = "below zero, where it follows the noise";
pub const section_headstages = "Headstages";
pub const board_restart_pending = "(restart pending)";
pub const board_not_saved = "(not saved as default)";
pub const board_summary_head = "{[rate]d} Hz   {[lower]s}–{[upper]s}   DSP ";
pub const board_summary_dsp_on = "on, {[cutoff]s}";
pub const board_summary_half = "   {[headstage]s} 16 of 32";
pub const board_these_change = "(these change what is recorded)";
pub const label_amplifier_band = "amplifier band";
pub const label_dsp_highpass = "DSP high-pass";
pub const label_cutoff = "cutoff";
pub const label_sample_rate = "sample rate";
pub const btn_32_ch = "32 ch";
pub const btn_16_of_32 = "16 of 32";
pub const btn_apply = "Apply (restarts acquisition)";
pub const board_apply_after_stop = "sample rate and channels can change once the recording is stopped";
pub const btn_save_default = "Save as default";
pub const board_differs = "these settings differ from the config file";

// ---- The control window: a panel's section ----

pub const btn_reset = "reset";
pub const summary_band_range = "   band {[low]d}–{[high]d} Hz";
pub const summary_band_below = "   band below {[high]d} Hz";
pub const summary_band_above = "   band above {[low]d} Hz";
pub const summary_band_none = "   band (no corners)";
pub const summary_on_ttl = "   on TTL {[line]d}";
pub const summary_on_spikes = "   on spikes, row {[row]d}";
pub const label_view = "view";
pub const label_window = "window";
pub const label_time = "time";
pub const label_scale = "scale";
pub const stepper_per_row = "{[scale]s}/row";
pub const label_filter = "filter";
pub const btn_band = "band";
pub const label_rows_shown = "rows shown";
pub const label_filtered = "filtered";
pub const label_average_of = "average of";
pub const label_subtract_from = "subtract from";
pub const label_trigger = "trigger";
pub const btn_ttl = "TTL";
pub const btn_spikes = "spikes";
pub const trigger_row_value = "row {[row]d}";
pub const label_level = "level";
pub const label_holdoff = "holdoff";
pub const label_overlaid = "overlaid";
pub const stepper_sweeps_one = "{[count]d} sweep";
pub const stepper_sweeps_other = "{[count]d} sweeps";

// ---- Alarms across the display (until acknowledged) ----

pub const alarm_acquisition_stopped = "ACQUISITION STOPPED ({[err]t}): the board is not being read";
pub const alarm_reopen_waiting = "ACQUISITION STOPPED ({[err]t}): opening the board again in {[seconds]d:.0} s (attempt {[n]d} of {[of]d})";
pub const alarm_reopen_absent = "THE BOARD IS GONE ({[err]t}): waiting for it to come back ({[seconds]d:.0} s so far)";
pub const alarm_restarted_one = "ACQUISITION RESTARTED ONCE after a read error ({[err]t}): {[lost]d:.1} s not acquired";
pub const alarm_restarted_other = "ACQUISITION RESTARTED {[times]d} TIMES after read errors ({[err]t}): {[lost]d:.1} s not acquired";
/// Follows `alarm_restarted_*` while recording.
pub const alarm_restarted_recording = "; the recording goes on in a new folder";
pub const alarm_no_data = "NO DATA FROM THE BOARD FOR {[seconds]d:.1} s";
pub const alarm_quiet_times_one = "THE BOARD WENT QUIET ONCE (0.5 s or more without data)";
pub const alarm_quiet_times_other = "THE BOARD WENT QUIET {[times]d} TIMES (0.5 s or more without data)";
pub const alarm_recording_failed = "RECORDING FAILED: nothing is being recorded";
pub const alarm_blocks_lost_one = "{[blocks]d} BLOCK LOST: the disk fell 30 s behind";
pub const alarm_blocks_lost_other = "{[blocks]d} BLOCKS LOST: the disk fell 30 s behind";
pub const alarm_dropped_one = "THE BOARD DROPPED {[samples]d} SAMPLE";
pub const alarm_dropped_other = "THE BOARD DROPPED {[samples]d} SAMPLES";
pub const alarm_gaps_one = "THE RECORDING HAS {[gaps]d} GAP";
pub const alarm_gaps_other = "THE RECORDING HAS {[gaps]d} GAPS";
pub const alarm_disk_full_in = "THE DISK IS FULL IN {[left]s}";

// ---- Warnings across the display (while their cause lasts) ----

pub const warn_acquisition_stopped = "acquisition stopped ({[err]t}): nothing is being read; restart dimna";
pub const warn_reopen_waiting = "acquisition stopped ({[err]t}): opening the board again in {[seconds]d:.0} s (attempt {[n]d} of {[of]d})";
pub const warn_reopen_absent = "the board is gone ({[err]t}): waiting for it to come back ({[seconds]d:.0} s so far)";
pub const warn_disk_behind = "the disk is {[behind]d:.0} s behind (samples are lost at 30 s)";
pub const warn_disk_full_in = "the disk is full in {[left]s} ({[gb]d:.1} GB left)";
/// "about 12 min", "about 40 s", "about 1 h 50 min": the time left, in the disk messages.
pub const about_minutes = "about {[count]d:.0} min";
pub const about_seconds = "about {[count]d:.0} s";
pub const about_hours = "about {[hours]d} h {[minutes]d} min";

// ---- Notes under the control window's board and recording lines ----

pub const note_cannot_create = "could not create a recording under {[dir]s}: {[err]t}";
pub const note_cannot_start = "could not start the recorder: {[err]t}";
/// Record pressed with too little free space: nothing was created.
pub const note_disk_too_full = "not recording: {[gb]d:.1} GB free under {[dir]s}, at least {[need]d:.0} GB needed";
pub const note_recording_failed = "recording failed: {[err]t}; what was written before is intact";
pub const note_last_recording = "last recording: {[length]s}   samples: {[samples]d}   gaps: {[gaps]d}";
pub const note_saved_to = "saved to {[path]s}";
pub const note_cannot_save_to = "could not save to {[path]s}: {[err]t}";
pub const note_band_edges = "the band's lower edge must stay below its upper edge";
pub const note_not_applied = "not applied: {[err]t}";
pub const note_view_saved = "view saved to {[path]s}";
pub const note_cannot_save = "could not save {[path]s}: {[err]t}";
pub const note_stop_recording_first = "stop the recording first: this changes the shape of the data";
pub const note_board_refused = "the board refused the new settings: {[err]t}";

// ---- The notice over the display at start (where the colours came from) ----

pub const notice_colours_from = "colours taken from {[name]s}";
pub const notice_colours_change = "to change them, edit scheme_image in {[where]s} (remove it for the built-in colours)";
pub const notice_colours_failed = "{[reason]s}; the built-in colours are used";
pub const notice_colours_where = "scheme_image is in {[where]s}";
// The chosen language cannot be shown on this machine (always in English: it is the fallback).
pub const notice_language_missing = "{[language]s} needs {[what]s}: showing English";
pub const notice_language_where = "install it, or set language = \"en\" in {[where]s}";
