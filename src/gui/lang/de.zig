//! Every text the user sees, in German. The same names as `en.zig`; a message missing here
//! is shown in English. Conventions for translators: `docs/plans/translations.md`.

// ---- Words shared by several windows ----

/// A switch that is on (buttons, summaries).
pub const toggle_on = "an";
/// A switch that is off, or a corner that is not set.
pub const toggle_off = "aus";
/// Common average reference (a button, a heading, a badge).
pub const label_car = "CAR";
/// Beside a row of a filtered panel that is drawn unfiltered.
pub const tag_raw = "roh";
/// The control window's filter choice: no filter (beside "band").
pub const btn_raw = "roh";
pub const btn_all = "alle";
pub const btn_none = "keine";
pub const slope_rising = "steigend";
pub const slope_falling = "fallend";
/// The display modes of a panel (buttons, and the first word of its summary).
pub const mode_scroll = "Rollen";
pub const mode_sweep = "Sweep";
pub const mode_triggered = "getriggert";
/// "6 presets" / "1 preset" (the control window's notes summary).
pub const presets_one = "{[count]d} Preset";
pub const presets_other = "{[count]d} Presets";
/// A filter's corners (the panel's band, the amplifier's band), beside their steppers.
pub const label_low = "unten";
pub const label_high = "oben";

// ---- The neural display: panel titles ----

/// After a title's band, when the common average reference is on.
pub const title_car = "   CAR";
/// A panel's filter in its title: both corners, only the low one, only the high one, none.
pub const title_band_range = "   {[low]d}-{[high]d} Hz{[car]s}";
pub const title_band_above = "   > {[low]d} Hz{[car]s}";
pub const title_band_below = "   < {[high]d} Hz{[car]s}";
pub const title_band_none = "   Filter: keine Grenzen{[car]s}";
/// A triggered panel's title says "raw" where a band would be.
pub const title_raw = "   roh";
pub const title_raw_car = "   roh   CAR";
/// The scale of a panel's rows in its title and in the control window's summary.
pub const title_per_row = "   {[scale]s}/Zeile";
/// "5 sweeps" after a triggered panel's title.
pub const title_sweeps_one = "   {[count]d} Sweep{[waiting]s}";
pub const title_sweeps_other = "   {[count]d} Sweeps{[waiting]s}";
pub const title_waiting_for_trigger = " (wartet auf Trigger)";
pub const title_review = "   Review";
pub const title_sweep = "   Sweep";
/// What triggers a panel's sweeps, from a row of the display: "row 5 falling 4.5 σ" (before
/// the threshold is known) and "row 5 falling -62 µV".
pub const trigger_row_sigmas = "Zeile {[row]d} {[slope]s} {[sigmas]d} σ";
pub const trigger_row_level = "Zeile {[row]d} {[slope]s} {[uv]d:.0} µV";
/// Tip over a triggered panel's filter text when it is not the detector's band.
pub const tip_band_header = "Diese Sweeps laufen durch den Filter dieses Panels: {[band]s}.";
pub const tip_band_none = "keiner (roh)";
pub const tip_band_line2 = "Spike-Erkennung und Slope-Trigger nutzen immer 300-6000 Hz,";
pub const tip_band_line3 = "daher können die Sweeps anders aussehen als die Wellenformen der Spike-Kacheln.";

// ---- The neural display: rows, banners, status ----

/// A row drawn with a threshold the row's band does not show.
pub const tag_threshold = "Schw";
/// In review with nothing to draw yet, where the traces would be.
pub const waiting_overview = "Übersicht dieses Abschnitts wird aufgebaut";
pub const waiting_reading = "Aufnahme wird gelesen";
/// The alarm bar's second line.
pub const alarm_hint = "zum Quittieren Umschalt+a drücken";
/// The review badge, top centre; `state` is one of the two messages after it, or empty.
pub const review_badge = "REVIEW   {[behind]d:.1} s hinter live   bei {[clock]s}{[state]s}   l = live";
pub const review_reading = "   (liest)";
pub const review_building = "   (Übersicht wird aufgebaut)";
/// The note being typed, bottom left.
pub const note_draft = "Notiz bei {[clock]s}:  {[text]s}_";
/// Bottom right, when the display missed blocks.
pub const readout_skipped_one = "{[ms]d:.1} ms   {[fps]d} fps   Anzeige übersprang {[blocks]d} Block";
pub const readout_skipped_other = "{[ms]d:.1} ms   {[fps]d} fps   Anzeige übersprang {[blocks]d} Blöcke";
/// The recording's clock beside it.
pub const readout_rec = "REC {[clock]s}";

// ---- The key summary (?) ----
// A text that is ASCII is drawn in the fixed-width font, any other in the ordinary one.

pub const help_title = "Tasten und Maus   (? oder Esc schließt dies)";
pub const help_heading_display = "Auf der Anzeige";
pub const help_heading_tiles = "Im Fenster der Spike-Kacheln";

pub const key_wheel = "Mausrad";
pub const key_ctrl_wheel = "Strg+Mausrad";
pub const key_shift_wheel = "Umschalt+Mausrad";
pub const key_ctrl_shift_wheel = "Strg+Umschalt+Mausrad";
pub const key_sideways_scroll = "seitliches Scrollen";
pub const key_alt_wheel = "Alt+Mausrad";
pub const key_touchpad_pinch = "Touchpad-Pinch";
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
pub const key_left_click_row = "Linksklick auf eine Zeile";
pub const key_right_click_row = "Rechtsklick auf eine Zeile";
pub const key_ctrl_right_click = "Strg+Rechtsklick";
pub const key_middle_click = "Mittelklick";
pub const key_drag_red_line = "eine rote Linie ziehen";
pub const key_n = "n";
pub const key_space = "Leertaste";
pub const key_left_right = "Links / Rechts";
pub const key_pgup_pgdn = "Bild↑ / Bild↓";
pub const key_home_end = "Pos1 / Ende";
pub const key_l = "l";
pub const key_slash = "/";
pub const key_backtick = "`";
pub const key_1_9 = "1-9";
pub const key_tilde = "~";
pub const key_shift_a = "Umschalt+a";
pub const key_question = "?";
pub const key_ctrl_q_or_esc = "Strg+Q oder Esc";
pub const key_a = "a";
pub const key_u = "u";
pub const key_shift_u = "Umschalt+u";
pub const key_left_click = "Linksklick";
pub const key_right_click = "Rechtsklick";
pub const key_drag_the_red_line = "die rote Linie ziehen";
pub const key_the_chips = "die Chips";

pub const help_y_scale_uv = "Y-Skala (µV pro Zeile)";
pub const help_y_scale_row = "Y-Skala nur dieser Zeile";
pub const help_back_forward_review = "zurück / vor in der Zeit (Review)";
pub const help_same_as_shift_wheel = "wie Umschalt+Mausrad";
pub const help_time_base_window = "Zeitbasis (getriggert: Fenster)";
pub const help_time_base = "Zeitbasis";
pub const help_y_scale = "Y-Skala";
pub const help_panel_as_configured = "das Panel wie konfiguriert";
pub const help_scrolling_sweep = "Rollen <-> Sweep";
pub const help_filter_toggle = "Anzeigefilter an / aus";
pub const help_low_corner = "untere Grenze runter / hoch";
pub const help_high_corner = "obere Grenze runter / hoch";
pub const help_triggered_toggle = "getriggerte Sweeps an / aus";
pub const help_triggered_line = "getriggert auf TTL: die Linie";
pub const help_triggered_source = "getriggert: TTL <-> Spikes, diese Zeile";
pub const help_focus_trigger = "Fokus (Spikes: dort triggern)";
pub const help_listen_alone = "nur sie abhören";
pub const help_sound_add_take = "zum Ton hinzufügen / entfernen";
pub const help_no_focus = "kein Kanal im Fokus";
pub const help_threshold_fixed_uv = "ihre Schwelle, fest (µV)";
pub const help_threshold_fixed_noise = "Schwelle: fest <-> dem Rauschen folgend";
pub const help_freeze = "einfrieren / zurück zu live";
pub const help_back_forward_tenth = "zurück / vor um 1/10 Fenster";
pub const help_back_forward_window = "zurück / vor um ein Fenster";
pub const help_start_live = "Anfang der Aufnahme / live";
pub const help_back_to_live = "zurück zu live";
pub const help_type_note = "Notiz tippen (Enter speichert)";
pub const help_stamp_draft = "ersten Entwurf stempeln";
pub const help_stamp_preset = "Preset-Notiz stempeln";
pub const help_adc_toggle = "ADC-Panels aus- / einblenden";
pub const help_acknowledge = "Alarm quittieren";
pub const help_these_keys = "diese Tasten (? oder Esc schließt)";
pub const help_quit = "beenden";
pub const help_tiles_scale_shown = "angezeigte Kacheln skalieren";
pub const help_tiles_scale_one = "nur diese Kachel skalieren";
pub const help_tiles_threshold = "Schwelle der Kachel";
pub const help_tiles_common_range = "angezeigte Kacheln: gemeinsamer Bereich";
pub const help_tiles_own_range = "angezeigte Kacheln: eigener Bereich, fest";
pub const help_undo_scale = "Skalierung rückgängig";
pub const help_redo_scale = "Skalierung wiederholen";
pub const help_focus_channel = "diesen Kanal fokussieren";
pub const help_tiles_chips = "Kacheln eines Ports, oder alle";

// ---- The spike-tile window ----

/// The chip that shows the tiles of every port.
pub const tiles_all = "Alle";
/// The range of the tiles shown, beside the chips: each tile on its own, or differing.
pub const tiles_range_auto = "auto";
pub const tiles_range_mixed = "gemischt";

// ---- The control window: the title, status and recording ----

pub const btn_acknowledge = "Quittieren";
pub const quit_heading = "Seit dem letzten Speichern geänderte Einstellungen:";
pub const quit_recording_heading = "Eine Aufnahme läuft. Beenden stoppt sie; das bisher Aufgenommene bleibt erhalten.";
pub const btn_stop_recording_and_quit = "Aufnahme stoppen und beenden";
pub const btn_keep_recording = "Weiter aufnehmen";
pub const notice_quit_recording = "Eine Aufnahme läuft";
pub const notice_quit_recording_how = "Strg+Q noch einmal, solange dies zu sehen ist, stoppt sie und beendet";
pub const quit_panel_views = "Panel-Ansichten (gespeichert in views.toml)";
pub const btn_save_and_quit = "Als Standard speichern und beenden";
pub const btn_quit_without_saving = "Beenden ohne Speichern";
pub const btn_cancel = "Abbrechen";
pub const status_display = "Anzeige {[ms]d:.1} ms   {[fps]d} fps   läuft seit {[seconds]d:.0} s";
pub const status_starting = "startet";
pub const status_display_skipped_one = "Anzeige übersprang {[blocks]d} Block";
pub const status_display_skipped_other = "Anzeige übersprang {[blocks]d} Blöcke";
pub const status_ring_overflow = "ÜBERLAUF DES AKQUISITIONSRINGS {[count]d}";
pub const btn_save_view = "Ansicht speichern";
pub const btn_quit = "Beenden";
pub const btn_record = "Aufnehmen";
pub const btn_stop_recording = "Aufnahme stoppen";
pub const rec_finishing = "Aufnahme wird abgeschlossen";
pub const rec_status = "REC {[clock]s}   {[gb]d:.2} GB   {[msamples]d:.1} M Samples";
pub const rec_disk_behind = "Platte {[behind]d:.1} s im Rückstand";
pub const rec_gaps_one = "{[gaps]d} Lücke";
pub const rec_gaps_other = "{[gaps]d} Lücken";
pub const rec_failed = "AUFNAHME FEHLGESCHLAGEN";
pub const rec_idle = "keine Aufnahme";
pub const rec_disk_free = "Platte: {[gb]d:.1} GB frei, {[left]s} bei diesem Layout";
pub const rec_disk_too_full = "Platte: {[gb]d:.1} GB frei, mindestens {[need]d:.0} GB zum Aufnehmen nötig";
/// The line about the source, at the top.
pub const about_source = "{[source]s}   {[rate]d} Hz   Kanäle: {[channels]d}, Elektroden: {[electrodes]d}";
pub const source_simulated = "simuliertes Board";
pub const source_board = "Open Ephys Acquisition Board";
/// The display window's title bar, refreshed once a second.
pub const window_title_status = "dimna   {[panel]s}: {[span]d:.2} s  {[scale]d:.1} {[unit]s}/Zeile   Latenz {[ms]d:.1} ms   {[fps]d} fps";
/// The last line of the control window.
pub const hint_keys = "Auf der Anzeige ? drücken für ihre Tasten und Mausaktionen und die des Kachelfensters.";

// ---- The control window: notes and audio ----

pub const section_notes = "Notizen";
pub const notes_summary_empty = "{[presets]s}   noch keine Notizen";
pub const notes_summary_last = "{[presets]s}   letzte Notiz {[clock]s}  {[text]s}";
pub const notes_hint = "auf der Anzeige: / tippt eine Notiz, Enter speichert sie";
pub const notes_typing = "Notiz wird getippt";
pub const notes_drafts_one = "{[count]d} Entwurf (` stempelt ihn)";
pub const notes_drafts_other = "{[count]d} Entwürfe (` stempelt einen)";
pub const section_audio = "Audio";
pub const btn_mute = "stumm";
pub const label_volume = "Lautstärke";
pub const btn_shaped = "geformt";
pub const btn_plain = "linear";
pub const btn_recalibrate = "neu kalibrieren";
pub const audio_no_output = "kein Audioausgang";
pub const audio_listening = "Abhören: {[what]s}";
pub const audio_listening_nothing = "nichts (Zeile auf der Anzeige anklicken)";
pub const audio_noise_held = "Rauschen {[sigma]d:.1} µV, gehalten";
pub const audio_measuring = "Rauschen wird gemessen (3 s)";
pub const audio_gaps_one = "{[count]d} Lücke im Ton";
pub const audio_gaps_other = "{[count]d} Lücken im Ton";
pub const audio_muted = ", stumm";
pub const audio_summary_off = "aus{[muted]s}   {[db]d:.0} dB";
pub const audio_summary_nothing = "an{[muted]s}   {[db]d:.0} dB   hört nichts ab";
pub const audio_summary_on = "an{[muted]s}   {[db]d:.0} dB   Abhören: {[what]s}   {[ms]d:.0} ms";

// ---- The control window: spikes and headstages ----

pub const section_spikes = "Spikes";
pub const label_threshold = "Schwelle";
pub const hint_below_zero = "unter null, dann folgt sie dem Rauschen";
pub const section_headstages = "Headstages";
pub const board_restart_pending = "(Neustart ausstehend)";
pub const board_not_saved = "(nicht als Standard gespeichert)";
pub const board_summary_head = "{[rate]d} Hz   {[lower]s}–{[upper]s}   DSP ";
pub const board_summary_dsp_on = "an, {[cutoff]s}";
pub const board_summary_half = "   {[headstage]s} 16 von 32";
pub const board_these_change = "(ändert, was aufgenommen wird)";
pub const label_amplifier_band = "Verstärkerband";
pub const label_dsp_highpass = "DSP-Hochpass";
pub const label_cutoff = "Grenzfrequenz";
pub const label_sample_rate = "Abtastrate";
pub const btn_32_ch = "32 ch";
pub const btn_16_of_32 = "16 von 32";
pub const btn_apply = "Anwenden (startet Akquisition neu)";
pub const board_apply_after_stop = "Abtastrate und Kanäle lassen sich ändern, wenn die Aufnahme gestoppt ist";
pub const btn_save_default = "Als Standard speichern";
pub const board_differs = "diese Einstellungen weichen von der Konfigurationsdatei ab";

// ---- The control window: a panel's section ----

pub const btn_reset = "zurücksetzen";
pub const summary_band_range = "   Band {[low]d}–{[high]d} Hz";
pub const summary_band_below = "   Band unter {[high]d} Hz";
pub const summary_band_above = "   Band über {[low]d} Hz";
pub const summary_band_none = "   Band (keine Grenzen)";
pub const summary_on_ttl = "   auf TTL {[line]d}";
pub const summary_on_spikes = "   auf Spikes, Zeile {[row]d}";
pub const label_view = "Ansicht";
pub const label_window = "Fenster";
pub const label_time = "Zeit";
pub const label_scale = "Skala";
pub const stepper_per_row = "{[scale]s}/Zeile";
pub const label_filter = "Filter";
pub const btn_band = "Band";
pub const label_rows_shown = "Zeilen";
pub const label_filtered = "gefiltert";
pub const label_average_of = "Mittel aus";
pub const label_subtract_from = "abziehen von";
pub const label_trigger = "Trigger";
pub const btn_ttl = "TTL";
pub const btn_spikes = "Spikes";
pub const trigger_row_value = "Zeile {[row]d}";
pub const label_level = "Level";
pub const label_holdoff = "Holdoff";
pub const label_overlaid = "überlagert";
pub const stepper_sweeps_one = "{[count]d} Sweep";
pub const stepper_sweeps_other = "{[count]d} Sweeps";

// ---- Alarms across the display (until acknowledged) ----

pub const alarm_acquisition_stopped = "AKQUISITION GESTOPPT ({[err]t}): das Board wird nicht gelesen";
pub const alarm_no_data = "KEINE DATEN VOM BOARD SEIT {[seconds]d:.1} s";
pub const alarm_quiet_times_one = "DAS BOARD WAR EINMAL STUMM (0.5 s oder länger ohne Daten)";
pub const alarm_quiet_times_other = "DAS BOARD WAR {[times]d} MAL STUMM (0.5 s oder länger ohne Daten)";
pub const alarm_recording_failed = "AUFNAHME FEHLGESCHLAGEN: es wird nichts aufgenommen";
pub const alarm_blocks_lost_one = "{[blocks]d} BLOCK VERLOREN: die Platte lag 30 s zurück";
pub const alarm_blocks_lost_other = "{[blocks]d} BLÖCKE VERLOREN: die Platte lag 30 s zurück";
pub const alarm_dropped_one = "DAS BOARD HAT {[samples]d} SAMPLE VERLOREN";
pub const alarm_dropped_other = "DAS BOARD HAT {[samples]d} SAMPLES VERLOREN";
pub const alarm_gaps_one = "DIE AUFNAHME HAT {[gaps]d} LÜCKE";
pub const alarm_gaps_other = "DIE AUFNAHME HAT {[gaps]d} LÜCKEN";
pub const alarm_disk_full_in = "DIE PLATTE IST VOLL IN {[left]s}";

// ---- Warnings across the display (while their cause lasts) ----

pub const warn_acquisition_stopped = "Akquisition gestoppt ({[err]t}): es wird nichts gelesen; dimna neu starten";
pub const warn_disk_behind = "die Platte liegt {[behind]d:.0} s zurück (ab 30 s gehen Samples verloren)";
pub const warn_disk_full_in = "die Platte ist in {[left]s} voll ({[gb]d:.1} GB frei)";
/// "about 12 min", "about 40 s": the time left, in the disk messages.
pub const about_minutes = "ca. {[count]d:.0} min";
pub const about_seconds = "ca. {[count]d:.0} s";
pub const about_hours = "ca. {[hours]d} h {[minutes]d} min";

// ---- Notes under the control window's board and recording lines ----

pub const note_cannot_create = "Aufnahme unter {[dir]s} konnte nicht angelegt werden: {[err]t}";
pub const note_cannot_start = "Recorder konnte nicht gestartet werden: {[err]t}";
pub const note_disk_too_full = "keine Aufnahme: {[gb]d:.1} GB frei unter {[dir]s}, mindestens {[need]d:.0} GB nötig";
pub const note_recording_failed = "Aufnahme fehlgeschlagen: {[err]t}; bisher Geschriebenes ist intakt";
pub const note_last_recording = "letzte Aufnahme: {[length]s}   Samples: {[samples]d}   Lücken: {[gaps]d}";
pub const note_saved_to = "gespeichert in {[path]s}";
pub const note_cannot_save_to = "Speichern in {[path]s} fehlgeschlagen: {[err]t}";
pub const note_band_edges = "die untere Bandgrenze muss unter der oberen bleiben";
pub const note_not_applied = "nicht angewendet: {[err]t}";
pub const note_view_saved = "Ansicht gespeichert in {[path]s}";
pub const note_cannot_save = "{[path]s} konnte nicht gespeichert werden: {[err]t}";
pub const note_stop_recording_first = "erst die Aufnahme stoppen: das ändert die Form der Daten";
pub const note_board_refused = "das Board hat die neuen Einstellungen abgelehnt: {[err]t}";

// ---- The notice over the display at start (where the colours came from) ----

pub const notice_colours_from = "Farben aus {[name]s}";
pub const notice_colours_change = "zum Ändern scheme_image in {[where]s} bearbeiten (entfernen für die eingebauten Farben)";
pub const notice_colours_failed = "{[reason]s}; die eingebauten Farben werden verwendet";
pub const notice_colours_where = "scheme_image steht in {[where]s}";
