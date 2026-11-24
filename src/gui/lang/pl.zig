//! Every text the user sees, in Polish. The same names as `en.zig`; a message missing here
//! is shown in English. Conventions for translators: `docs/plans/translations.md`.
//! Notes for a reviewer: `docs/translations/pl.md`. Counted messages have Polish's three
//! forms: `_one` (1), `_few` (2-4, 22-24, ...) and `_many` (0, 5-21, 25-31, ...).

// ---- Words shared by several windows ----

/// A switch that is on (buttons, summaries).
pub const toggle_on = "wł.";
/// A switch that is off, or a corner that is not set.
pub const toggle_off = "wył.";
/// Common average reference (a button, a heading, a badge).
pub const label_car = "CAR";
/// Beside a row of a filtered panel that is drawn unfiltered.
pub const tag_raw = "surowy";
/// The control window's filter choice: no filter (beside "band").
pub const btn_raw = "surowy";
pub const btn_all = "wszystkie";
pub const btn_none = "żadne";
pub const slope_rising = "rosnące";
pub const slope_falling = "opadające";
/// The display modes of a panel (buttons, and the first word of its summary).
pub const mode_scroll = "przesuw";
pub const mode_sweep = "przebieg";
pub const mode_triggered = "wyzwalany";
/// "6 presets" / "1 preset" (the control window's notes summary).
pub const presets_one = "{[count]d} szablon";
pub const presets_few = "{[count]d} szablony";
pub const presets_many = "{[count]d} szablonów";
/// A filter's corners (the panel's band, the amplifier's band), beside their steppers.
pub const label_low = "dolna";
pub const label_high = "górna";

// ---- The neural display: panel titles ----

/// After a title's band, when the common average reference is on.
pub const title_car = "   CAR";
/// A panel's filter in its title: both corners, only the low one, only the high one, none.
pub const title_band_range = "   {[low]d}-{[high]d} Hz{[car]s}";
pub const title_band_above = "   > {[low]d} Hz{[car]s}";
pub const title_band_below = "   < {[high]d} Hz{[car]s}";
pub const title_band_none = "   filtr: bez granic{[car]s}";
/// A triggered panel's title says "raw" where a band would be.
pub const title_raw = "   surowy";
pub const title_raw_car = "   surowy   CAR";
/// The scale of a panel's rows in its title and in the control window's summary.
pub const title_per_row = "   {[scale]s}/wiersz";
/// "5 sweeps" after a triggered panel's title.
pub const title_sweeps_one = "   {[count]d} przebieg{[waiting]s}";
pub const title_sweeps_few = "   {[count]d} przebiegi{[waiting]s}";
pub const title_sweeps_many = "   {[count]d} przebiegów{[waiting]s}";
pub const title_waiting_for_trigger = " (czeka na wyzwolenie)";
pub const title_review = "   przegląd";
pub const title_sweep = "   przebieg";
/// What triggers a panel's sweeps, from a row of the display: "row 5 falling 4.5 σ" (before
/// the threshold is known) and "row 5 falling -62 µV".
pub const trigger_row_sigmas = "wiersz {[row]d} {[slope]s} {[sigmas]d} σ";
pub const trigger_row_level = "wiersz {[row]d} {[slope]s} {[uv]d:.0} µV";
/// Tip over a triggered panel's filter text when it is not the detector's band.
pub const tip_band_header = "Te przebiegi są rysowane przez filtr tego panelu: {[band]s}.";
pub const tip_band_none = "brak (surowy)";
pub const tip_band_line2 = "Detekcja spike'ów i wyzwalanie zboczem zawsze używają 300-6000 Hz,";
pub const tip_band_line3 = "więc przebiegi mogą wyglądać inaczej niż w kafelkach spike'ów.";

// ---- The neural display: rows, banners, status ----

/// A row drawn with a threshold the row's band does not show.
pub const tag_threshold = "próg";
/// In review with nothing to draw yet, where the traces would be.
pub const waiting_overview = "budowanie przeglądu tego odcinka";
pub const waiting_reading = "odczyt nagrania";
/// The alarm bar's second line.
pub const alarm_hint = "Shift+a potwierdza alarm";
/// The review badge, top centre; `state` is one of the two messages after it, or empty.
pub const review_badge = "PRZEGLĄD   {[behind]d:.1} s wstecz   czas {[clock]s}{[state]s}   l = na żywo";
pub const review_reading = "   (odczyt)";
pub const review_building = "   (budowanie przeglądu)";
/// The note being typed, bottom left.
pub const note_draft = "notatka o {[clock]s}:  {[text]s}_";
/// Bottom right, when the display missed blocks.
pub const readout_skipped_one = "{[ms]d:.1} ms   {[fps]d} fps   ekran pominął {[blocks]d} blok";
pub const readout_skipped_few = "{[ms]d:.1} ms   {[fps]d} fps   ekran pominął {[blocks]d} bloki";
pub const readout_skipped_many = "{[ms]d:.1} ms   {[fps]d} fps   ekran pominął {[blocks]d} bloków";
/// The recording's clock beside it.
pub const readout_rec = "REC {[clock]s}";

// ---- The key summary (?) ----
// A text that is ASCII is drawn in the fixed-width font, any other in the ordinary one.

pub const help_title = "Klawisze i mysz   (? lub Esc zamyka)";
pub const help_heading_display = "Na ekranie";
pub const help_heading_tiles = "W oknie kafelków spike'ów";

pub const key_wheel = "kółko";
pub const key_ctrl_wheel = "Ctrl+kółko";
pub const key_shift_wheel = "Shift+kółko";
pub const key_ctrl_shift_wheel = "Ctrl+Shift+kółko";
pub const key_sideways_scroll = "przewijanie w bok";
pub const key_alt_wheel = "Alt+kółko";
pub const key_touchpad_pinch = "szczypanie touchpada";
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
pub const key_left_click_row = "lewy klik na wierszu";
pub const key_right_click_row = "prawy klik na wierszu";
pub const key_ctrl_right_click = "Ctrl+prawy klik";
pub const key_middle_click = "środkowy klik";
pub const key_drag_red_line = "przeciągnąć czerwoną linię";
pub const key_n = "n";
pub const key_space = "Spacja";
pub const key_left_right = "Lewo / Prawo";
pub const key_pgup_pgdn = "PgUp / PgDn";
pub const key_home_end = "Home / End";
pub const key_l = "l";
pub const key_slash = "/";
pub const key_backtick = "`";
pub const key_1_9 = "1-9";
pub const key_tilde = "~";
pub const key_shift_a = "Shift+a";
pub const key_question = "?";
pub const key_ctrl_q_or_esc = "Ctrl+Q lub Esc";
pub const key_a = "a";
pub const key_u = "u";
pub const key_shift_u = "Shift+u";
pub const key_left_click = "lewy klik";
pub const key_right_click = "prawy klik";
pub const key_drag_the_red_line = "przeciągnąć czerwoną linię";
pub const key_the_chips = "przyciski";

pub const help_y_scale_uv = "skala Y (µV na wiersz)";
pub const help_y_scale_row = "skala Y tylko tego wiersza";
pub const help_back_forward_review = "wstecz / naprzód w czasie (przegląd)";
pub const help_same_as_shift_wheel = "to samo co Shift+kółko";
pub const help_time_base_window = "podstawa czasu (wyzwalany: okno)";
pub const help_time_base = "podstawa czasu";
pub const help_y_scale = "skala Y";
pub const help_panel_as_configured = "panel jak w konfiguracji";
pub const help_scrolling_sweep = "przesuw <-> przebieg";
pub const help_filter_toggle = "filtr ekranu wł. / wył.";
pub const help_low_corner = "dolna granica niżej / wyżej";
pub const help_high_corner = "górna granica niżej / wyżej";
pub const help_triggered_toggle = "przebiegi wyzwalane wł. / wył.";
pub const help_triggered_line = "wyzwalanie z TTL: linia";
pub const help_triggered_source = "wyzwalanie: TTL <-> spike'i, ten wiersz";
pub const help_focus_trigger = "wybór (spike'i: tam wyzwalanie)";
pub const help_listen_alone = "odsłuch tylko tego";
pub const help_sound_add_take = "dodanie do / usunięcie z odsłuchu";
pub const help_no_focus = "brak wybranego kanału";
pub const help_threshold_fixed_uv = "jego próg, stały (µV)";
pub const help_threshold_fixed_noise = "próg: stały <-> wg szumu";
pub const help_freeze = "zamrożenie / powrót na żywo";
pub const help_back_forward_tenth = "wstecz / naprzód o 1/10 okna";
pub const help_back_forward_window = "wstecz / naprzód o okno";
pub const help_start_live = "początek nagrania / na żywo";
pub const help_back_to_live = "powrót na żywo";
pub const help_type_note = "pisanie notatki (Enter zapisuje)";
pub const help_stamp_draft = "wstawienie pierwszego szkicu";
pub const help_stamp_preset = "wstawienie szablonu";
pub const help_adc_toggle = "ukrycie / pokazanie paneli ADC";
pub const help_acknowledge = "potwierdzenie alarmu";
pub const help_these_keys = "te klawisze (? lub Esc zamyka)";
pub const help_quit = "wyjście";
pub const help_tiles_scale_shown = "skala pokazanych kafelków";
pub const help_tiles_scale_one = "skala tylko tego kafelka";
pub const help_tiles_threshold = "próg kafelka";
pub const help_tiles_common_range = "pokazane kafelki: wspólny zakres";
pub const help_tiles_own_range = "pokazane kafelki: własny zakres, stały";
pub const help_undo_scale = "cofnięcie zmiany skali";
pub const help_redo_scale = "ponowienie zmiany skali";
pub const help_focus_channel = "wybór tego kanału";
pub const help_tiles_chips = "kafelki jednego portu lub wszystkie";

// ---- The spike-tile window ----

/// The chip that shows the tiles of every port.
pub const tiles_all = "Wszystkie";
/// The range of the tiles shown, beside the chips: each tile on its own, or differing.
pub const tiles_range_auto = "auto";
pub const tiles_range_mixed = "różne";

// ---- The control window: the title, status and recording ----

pub const btn_acknowledge = "Potwierdź";
pub const quit_heading = "Ustawienia zmienione od ostatniego zapisu:";
pub const quit_recording_heading = "Trwa nagrywanie. Wyjście je zatrzyma; to, co już nagrano, zostanie zachowane.";
pub const btn_stop_recording_and_quit = "Zatrzymaj nagrywanie i wyjdź";
pub const btn_keep_recording = "Nagrywaj dalej";
pub const notice_quit_recording = "Trwa nagrywanie";
pub const notice_quit_recording_how = "Ponowne Ctrl+Q, póki to widać, zatrzyma je i zakończy program";
pub const quit_panel_views = "widoki paneli (zapis do views.toml)";
pub const btn_save_and_quit = "Zapisz jako domyślne i wyjdź";
pub const btn_quit_without_saving = "Wyjdź bez zapisywania";
pub const btn_cancel = "Anuluj";
pub const status_display = "ekran {[ms]d:.1} ms   {[fps]d} fps   działa {[seconds]d:.0} s";
pub const status_starting = "uruchamianie";
pub const status_display_skipped_one = "ekran pominął {[blocks]d} blok";
pub const status_display_skipped_few = "ekran pominął {[blocks]d} bloki";
pub const status_display_skipped_many = "ekran pominął {[blocks]d} bloków";
pub const status_ring_overflow = "PRZEPEŁNIENIE BUFORA AKWIZYCJI {[count]d}";
pub const btn_save_view = "Zapisz widok";
pub const btn_quit = "Wyjdź";
pub const btn_record = "Nagrywaj";
pub const btn_stop_recording = "Zatrzymaj nagrywanie";
pub const rec_finishing = "kończenie nagrania";
pub const rec_status = "REC {[clock]s}   {[gb]d:.2} GB   {[msamples]d:.1} M próbek";
pub const rec_disk_behind = "dysk {[behind]d:.1} s w tyle";
pub const rec_gaps_one = "{[gaps]d} przerwa";
pub const rec_gaps_few = "{[gaps]d} przerwy";
pub const rec_gaps_many = "{[gaps]d} przerw";
pub const rec_failed = "NAGRYWANIE NIEUDANE";
pub const rec_idle = "nie nagrywa";
/// The line about the source, at the top.
pub const about_source = "{[source]s}   {[rate]d} Hz   kanały: {[channels]d}, elektrody: {[electrodes]d}";
pub const source_simulated = "symulowana płytka";
pub const source_board = "płytka akwizycyjna Open Ephys";
/// The display window's title bar, refreshed once a second.
pub const window_title_status = "dimna   {[panel]s}: {[span]d:.2} s  {[scale]d:.1} {[unit]s}/wiersz   opóźnienie {[ms]d:.1} ms   {[fps]d} fps";
/// The last line of the control window.
pub const hint_keys = "? na ekranie pokazuje jego klawisze i obsługę myszy, także okna kafelków.";

// ---- The control window: notes and audio ----

pub const section_notes = "Notatki";
pub const notes_summary_empty = "{[presets]s}   brak notatek";
pub const notes_summary_last = "{[presets]s}   ostatnia notatka {[clock]s}  {[text]s}";
pub const notes_hint = "na ekranie: / otwiera notatkę, Enter ją zapisuje";
pub const notes_typing = "pisanie notatki";
pub const notes_drafts_one = "{[count]d} szkic (` go wstawia)";
pub const notes_drafts_few = "{[count]d} szkice (` wstawia jeden)";
pub const notes_drafts_many = "{[count]d} szkiców (` wstawia jeden)";
pub const section_audio = "Dźwięk";
pub const btn_mute = "wycisz";
pub const label_volume = "głośność";
pub const btn_shaped = "kształtowany";
pub const btn_plain = "zwykły";
pub const btn_recalibrate = "rekalibruj";
pub const audio_no_output = "brak wyjścia audio";
pub const audio_listening = "odsłuch: {[what]s}";
pub const audio_listening_nothing = "nic (klik na wierszu ekranu)";
pub const audio_noise_held = "szum {[sigma]d:.1} µV, ustalony";
pub const audio_measuring = "pomiar szumu (3 s)";
pub const audio_gaps_one = "{[count]d} przerwa w dźwięku";
pub const audio_gaps_few = "{[count]d} przerwy w dźwięku";
pub const audio_gaps_many = "{[count]d} przerw w dźwięku";
pub const audio_muted = ", wyciszony";
pub const audio_summary_off = "wył.{[muted]s}   {[db]d:.0} dB";
pub const audio_summary_nothing = "wł.{[muted]s}   {[db]d:.0} dB   odsłuch: nic";
pub const audio_summary_on = "wł.{[muted]s}   {[db]d:.0} dB   odsłuch: {[what]s}   {[ms]d:.0} ms";

// ---- The control window: spikes and headstages ----

pub const section_spikes = "Spike'i";
pub const label_threshold = "próg";
pub const hint_below_zero = "poniżej zera, gdzie podąża za szumem";
pub const section_headstages = "Przedwzmacniacze";
pub const board_restart_pending = "(czeka na restart)";
pub const board_not_saved = "(niezapisane jako domyślne)";
pub const board_summary_head = "{[rate]d} Hz   {[lower]s}–{[upper]s}   DSP ";
pub const board_summary_dsp_on = "wł., {[cutoff]s}";
pub const board_summary_half = "   {[headstage]s} 16 z 32";
pub const board_these_change = "(zmieniają to, co jest nagrywane)";
pub const label_amplifier_band = "pasmo wzmacniacza";
pub const label_dsp_highpass = "górnoprzepustowy DSP";
pub const label_cutoff = "odcięcie";
pub const label_sample_rate = "próbkowanie";
pub const btn_32_ch = "32 kan.";
pub const btn_16_of_32 = "16 z 32";
pub const btn_apply = "Zastosuj (restart akwizycji)";
pub const board_apply_after_stop = "próbkowanie i kanały można zmienić po zatrzymaniu nagrywania";
pub const btn_save_default = "Zapisz jako domyślne";
pub const board_differs = "te ustawienia różnią się od pliku konfiguracji";

// ---- The control window: a panel's section ----

pub const btn_reset = "reset";
pub const summary_band_range = "   pasmo {[low]d}–{[high]d} Hz";
pub const summary_band_below = "   pasmo poniżej {[high]d} Hz";
pub const summary_band_above = "   pasmo powyżej {[low]d} Hz";
pub const summary_band_none = "   pasmo (bez granic)";
pub const summary_on_ttl = "   na TTL {[line]d}";
pub const summary_on_spikes = "   na spike'ach, wiersz {[row]d}";
pub const label_view = "widok";
pub const label_window = "okno";
pub const label_time = "czas";
pub const label_scale = "skala";
pub const stepper_per_row = "{[scale]s}/wiersz";
pub const label_filter = "filtr";
pub const btn_band = "pasmo";
pub const label_rows_shown = "widoczne";
pub const label_filtered = "filtrowane";
pub const label_average_of = "średnia z";
pub const label_subtract_from = "odjęta od";
pub const label_trigger = "wyzwalacz";
pub const btn_ttl = "TTL";
pub const btn_spikes = "spike'i";
pub const trigger_row_value = "wiersz {[row]d}";
pub const label_level = "poziom";
pub const label_holdoff = "holdoff";
pub const label_overlaid = "nałożone";
pub const stepper_sweeps_one = "{[count]d} przebieg";
pub const stepper_sweeps_few = "{[count]d} przebiegi";
pub const stepper_sweeps_many = "{[count]d} przebiegów";

// ---- Alarms across the display (until acknowledged) ----

pub const alarm_acquisition_stopped = "AKWIZYCJA ZATRZYMANA ({[err]t}): płytka nie jest odczytywana";
pub const alarm_no_data = "BRAK DANYCH Z PŁYTKI OD {[seconds]d:.1} s";
pub const alarm_quiet_times_one = "PŁYTKA UCICHŁA RAZ (0.5 s lub dłużej bez danych)";
pub const alarm_quiet_times_few = "PŁYTKA UCICHŁA {[times]d} RAZY (0.5 s lub dłużej bez danych)";
pub const alarm_quiet_times_many = "PŁYTKA UCICHŁA {[times]d} RAZY (0.5 s lub dłużej bez danych)";
pub const alarm_recording_failed = "NAGRYWANIE NIEUDANE: nic nie jest nagrywane";
pub const alarm_blocks_lost_one = "UTRACONO {[blocks]d} BLOK: dysk został 30 s w tyle";
pub const alarm_blocks_lost_few = "UTRACONO {[blocks]d} BLOKI: dysk został 30 s w tyle";
pub const alarm_blocks_lost_many = "UTRACONO {[blocks]d} BLOKÓW: dysk został 30 s w tyle";
pub const alarm_dropped_one = "PŁYTKA ZGUBIŁA {[samples]d} PRÓBKĘ";
pub const alarm_dropped_few = "PŁYTKA ZGUBIŁA {[samples]d} PRÓBKI";
pub const alarm_dropped_many = "PŁYTKA ZGUBIŁA {[samples]d} PRÓBEK";
pub const alarm_gaps_one = "NAGRANIE MA {[gaps]d} PRZERWĘ";
pub const alarm_gaps_few = "NAGRANIE MA {[gaps]d} PRZERWY";
pub const alarm_gaps_many = "NAGRANIE MA {[gaps]d} PRZERW";
pub const alarm_disk_full_in = "DYSK ZAPEŁNI SIĘ ZA {[left]s}";

// ---- Warnings across the display (while their cause lasts) ----

pub const warn_acquisition_stopped = "akwizycja zatrzymana ({[err]t}): nic nie jest odczytywane; potrzebny restart dimna";
pub const warn_disk_behind = "dysk jest {[behind]d:.0} s w tyle (przy 30 s próbki są tracone)";
pub const warn_disk_full_in = "dysk zapełni się za {[left]s} (zostało {[gb]d:.1} GB)";
/// "about 12 min", "about 40 s": the time left, in the disk messages.
pub const about_minutes = "ok. {[count]d:.0} min";
pub const about_seconds = "ok. {[count]d:.0} s";

// ---- Notes under the control window's board and recording lines ----

pub const note_cannot_create = "nie udało się utworzyć nagrania w {[dir]s}: {[err]t}";
pub const note_cannot_start = "nie udało się uruchomić rejestratora: {[err]t}";
pub const note_recording_failed = "nagrywanie nieudane: {[err]t}; to, co zapisano wcześniej, jest nienaruszone";
pub const note_last_recording = "ostatnie nagranie: {[length]s}   próbki: {[samples]d}   przerwy: {[gaps]d}";
pub const note_saved_to = "zapisano w {[path]s}";
pub const note_cannot_save_to = "nie udało się zapisać w {[path]s}: {[err]t}";
pub const note_band_edges = "dolna granica pasma musi być poniżej górnej";
pub const note_not_applied = "nie zastosowano: {[err]t}";
pub const note_view_saved = "widok zapisano w {[path]s}";
pub const note_cannot_save = "nie udało się zapisać {[path]s}: {[err]t}";
pub const note_stop_recording_first = "wymaga zatrzymania nagrywania: to zmienia kształt danych";
pub const note_board_refused = "płytka odrzuciła nowe ustawienia: {[err]t}";

// ---- The notice over the display at start (where the colours came from) ----

pub const notice_colours_from = "kolory pobrane z {[name]s}";
pub const notice_colours_change = "aby je zmienić, należy edytować scheme_image w {[where]s} (usunięcie przywraca kolory wbudowane)";
pub const notice_colours_failed = "{[reason]s}; używane są kolory wbudowane";
pub const notice_colours_where = "scheme_image jest w {[where]s}";
