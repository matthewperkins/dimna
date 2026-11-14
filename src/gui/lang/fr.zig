//! Every text the user sees, in French. The same names as `en.zig`; a message missing here
//! is shown in English. Conventions for translators: `docs/plans/translations.md`.

// ---- Words shared by several windows ----

/// A switch that is on (buttons, summaries).
pub const toggle_on = "on";
/// A switch that is off, or a corner that is not set.
pub const toggle_off = "off";
/// Common average reference (a button, a heading, a badge).
pub const label_car = "CAR";
/// Beside a row of a filtered panel that is drawn unfiltered.
pub const tag_raw = "brut";
/// The control window's filter choice: no filter (beside "band").
pub const btn_raw = "brut";
pub const btn_all = "tous";
pub const btn_none = "aucun";
pub const slope_rising = "montant";
pub const slope_falling = "descendant";
/// The display modes of a panel (buttons, and the first word of its summary).
pub const mode_scroll = "défilement";
pub const mode_sweep = "sweep";
pub const mode_triggered = "déclenché";
/// "6 presets" / "1 preset" (the control window's notes summary).
pub const presets_one = "{[count]d} préréglage";
pub const presets_other = "{[count]d} préréglages";
/// A filter's corners (the panel's band, the amplifier's band), beside their steppers.
pub const label_low = "basse";
pub const label_high = "haute";

// ---- The neural display: panel titles ----

/// After a title's band, when the common average reference is on.
pub const title_car = "   CAR";
/// A panel's filter in its title: both corners, only the low one, only the high one, none.
pub const title_band_range = "   {[low]d}-{[high]d} Hz{[car]s}";
pub const title_band_above = "   > {[low]d} Hz{[car]s}";
pub const title_band_below = "   < {[high]d} Hz{[car]s}";
pub const title_band_none = "   filtre : sans coupure{[car]s}";
/// A triggered panel's title says "raw" where a band would be.
pub const title_raw = "   brut";
pub const title_raw_car = "   brut   CAR";
/// The scale of a panel's rows in its title and in the control window's summary.
pub const title_per_row = "   {[scale]s}/ligne";
/// "5 sweeps" after a triggered panel's title.
pub const title_sweeps_one = "   {[count]d} sweep{[waiting]s}";
pub const title_sweeps_other = "   {[count]d} sweeps{[waiting]s}";
pub const title_waiting_for_trigger = " (en attente d'un déclenchement)";
pub const title_review = "   revue";
pub const title_sweep = "   sweep";
/// What triggers a panel's sweeps, from a row of the display: "row 5 falling 4.5 σ" (before
/// the threshold is known) and "row 5 falling -62 µV".
pub const trigger_row_sigmas = "ligne {[row]d} {[slope]s} {[sigmas]d} σ";
pub const trigger_row_level = "ligne {[row]d} {[slope]s} {[uv]d:.0} µV";
/// Tip over a triggered panel's filter text when it is not the detector's band.
pub const tip_band_header = "Ces sweeps sont tracés avec le filtre de ce panneau : {[band]s}.";
pub const tip_band_none = "aucun (brut)";
pub const tip_band_line2 = "La détection des spikes et le déclencheur sur pente utilisent toujours 300-6000 Hz,";
pub const tip_band_line3 = "donc les sweeps peuvent différer des formes d'onde des tuiles de spikes.";

// ---- The neural display: rows, banners, status ----

/// A row drawn with a threshold the row's band does not show.
pub const tag_threshold = "seuil";
/// In review with nothing to draw yet, where the traces would be.
pub const waiting_overview = "construction de l'aperçu de cette portion";
pub const waiting_reading = "lecture de l'enregistrement";
/// The alarm bar's second line.
pub const alarm_hint = "pour acquitter, appuyer sur Maj+a";
/// The review badge, top centre; `state` is one of the two messages after it, or empty.
pub const review_badge = "REVUE   {[behind]d:.1} s derrière le direct   à {[clock]s}{[state]s}   l = direct";
pub const review_reading = "   (lecture)";
pub const review_building = "   (construction de l'aperçu)";
/// The note being typed, bottom left.
pub const note_draft = "note à {[clock]s} :  {[text]s}_";
/// Bottom right, when the display missed blocks.
pub const readout_skipped_one = "{[ms]d:.1} ms   {[fps]d} fps   affichage : {[blocks]d} bloc sauté";
pub const readout_skipped_other = "{[ms]d:.1} ms   {[fps]d} fps   affichage : {[blocks]d} blocs sautés";
/// The recording's clock beside it.
pub const readout_rec = "REC {[clock]s}";

// ---- The key summary (?) ----
// A text that is ASCII is drawn in the fixed-width font, any other in the ordinary one.

pub const help_title = "Touches et souris   (? ou Échap ferme)";
pub const help_heading_display = "Sur l'affichage";
pub const help_heading_tiles = "Dans la fenêtre des tuiles de spikes";

pub const key_wheel = "molette";
pub const key_ctrl_wheel = "Ctrl+molette";
pub const key_shift_wheel = "Maj+molette";
pub const key_ctrl_shift_wheel = "Ctrl+Maj+molette";
pub const key_sideways_scroll = "défilement latéral";
pub const key_alt_wheel = "Alt+molette";
pub const key_touchpad_pinch = "pincement du pavé tactile";
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
pub const key_left_click_row = "clic gauche sur une ligne";
pub const key_right_click_row = "clic droit sur une ligne";
pub const key_ctrl_right_click = "Ctrl+clic droit";
pub const key_middle_click = "clic milieu";
pub const key_drag_red_line = "tirer une ligne rouge";
pub const key_n = "n";
pub const key_space = "Espace";
pub const key_left_right = "Gauche / Droite";
pub const key_pgup_pgdn = "Page↑ / Page↓";
pub const key_home_end = "Début / Fin";
pub const key_l = "l";
pub const key_slash = "/";
pub const key_backtick = "`";
pub const key_1_9 = "1-9";
pub const key_tilde = "~";
pub const key_shift_a = "Maj+a";
pub const key_question = "?";
pub const key_q_or_esc = "q ou Échap";
pub const key_a = "a";
pub const key_u = "u";
pub const key_shift_u = "Maj+u";
pub const key_left_click = "clic gauche";
pub const key_right_click = "clic droit";
pub const key_drag_the_red_line = "tirer la ligne rouge";
pub const key_the_chips = "les pastilles";

pub const help_y_scale_uv = "échelle Y (µV par ligne)";
pub const help_y_scale_row = "échelle Y de la ligne seule";
pub const help_back_forward_review = "reculer / avancer dans le temps (revue)";
pub const help_same_as_shift_wheel = "comme Maj+molette";
pub const help_time_base_window = "base de temps (déclenché : fenêtre)";
pub const help_time_base = "base de temps";
pub const help_y_scale = "échelle Y";
pub const help_panel_as_configured = "le panneau tel que configuré";
pub const help_scrolling_sweep = "défilement <-> sweep";
pub const help_filter_toggle = "filtre d'affichage on / off";
pub const help_low_corner = "coupure basse : baisser / monter";
pub const help_high_corner = "coupure haute : baisser / monter";
pub const help_triggered_toggle = "sweeps déclenchés on / off";
pub const help_triggered_line = "déclenché sur TTL : la ligne";
pub const help_triggered_source = "déclenché : TTL <-> spikes, cette ligne";
pub const help_focus_trigger = "focus (spikes : déclencher là)";
pub const help_listen_alone = "l'écouter seule";
pub const help_sound_add_take = "ajouter au son / retirer du son";
pub const help_no_focus = "aucun canal en focus";
pub const help_threshold_fixed_uv = "son seuil, fixe (µV)";
pub const help_threshold_fixed_noise = "seuil : fixe <-> suit le bruit";
pub const help_freeze = "figer / retour au direct";
pub const help_back_forward_tenth = "reculer / avancer d'1/10 de fenêtre";
pub const help_back_forward_window = "reculer / avancer d'une fenêtre";
pub const help_start_live = "début de l'enregistrement / direct";
pub const help_back_to_live = "retour au direct";
pub const help_type_note = "saisir une note (Entrée valide)";
pub const help_stamp_draft = "estampiller le premier brouillon";
pub const help_stamp_preset = "estampiller une note prédéfinie";
pub const help_adc_toggle = "masquer / afficher les panneaux ADC";
pub const help_acknowledge = "acquitter une alarme";
pub const help_these_keys = "ces touches (? ou Échap ferme)";
pub const help_quit = "quitter";
pub const help_tiles_scale_shown = "changer l'échelle des tuiles affichées";
pub const help_tiles_scale_one = "changer l'échelle de la tuile seule";
pub const help_tiles_threshold = "le seuil de la tuile";
pub const help_tiles_common_range = "tuiles affichées : plage commune";
pub const help_tiles_own_range = "tuiles affichées : plage propre, fixe";
pub const help_undo_scale = "annuler un changement d'échelle";
pub const help_redo_scale = "rétablir un changement d'échelle";
pub const help_focus_channel = "focus sur ce canal";
pub const help_tiles_chips = "tuiles d'un port, ou toutes";

// ---- The spike-tile window ----

/// The chip that shows the tiles of every port.
pub const tiles_all = "Tous";
/// The range of the tiles shown, beside the chips: each tile on its own, or differing.
pub const tiles_range_auto = "auto";
pub const tiles_range_mixed = "mixte";

// ---- The control window: the title, status and recording ----

pub const btn_acknowledge = "Acquitter";
pub const quit_heading = "Réglages modifiés depuis la dernière sauvegarde :";
pub const quit_panel_views = "vues des panneaux (sauvegardées dans views.toml)";
pub const btn_save_and_quit = "Sauvegarder par défaut et quitter";
pub const btn_quit_without_saving = "Quitter sans sauvegarder";
pub const btn_cancel = "Annuler";
pub const status_display = "affichage {[ms]d:.1} ms   {[fps]d} fps   actif depuis {[seconds]d:.0} s";
pub const status_starting = "démarrage";
pub const status_display_skipped_one = "affichage : {[blocks]d} bloc sauté";
pub const status_display_skipped_other = "affichage : {[blocks]d} blocs sautés";
pub const status_ring_overflow = "DÉBORDEMENT DU TAMPON D'ACQUISITION {[count]d}";
pub const btn_save_view = "Sauvegarder la vue";
pub const btn_quit = "Quitter";
pub const btn_record = "Enregistrer";
pub const btn_stop_recording = "Arrêter l'enregistrement";
pub const rec_finishing = "fin de l'enregistrement";
pub const rec_status = "REC {[clock]s}   {[gb]d:.2} GB   {[msamples]d:.1} M échantillons";
pub const rec_disk_behind = "le disque a {[behind]d:.1} s de retard";
pub const rec_gaps_one = "{[gaps]d} trou";
pub const rec_gaps_other = "{[gaps]d} trous";
pub const rec_failed = "ENREGISTREMENT ÉCHOUÉ";
pub const rec_idle = "pas d'enregistrement";
/// The line about the source, at the top.
pub const about_source = "{[source]s}   {[rate]d} Hz   canaux : {[channels]d}, électrodes : {[electrodes]d}";
pub const source_simulated = "carte simulée";
pub const source_board = "carte d'acquisition Open Ephys";
/// The display window's title bar, refreshed once a second.
pub const window_title_status = "dimna   {[panel]s} : {[span]d:.2} s  {[scale]d:.1} {[unit]s}/ligne   latence {[ms]d:.1} ms   {[fps]d} fps";
/// The last line of the control window.
pub const hint_keys = "Appuyer sur ? sur l'affichage pour ses touches et actions de souris, et celles de la fenêtre des tuiles.";

// ---- The control window: notes and audio ----

pub const section_notes = "Notes";
pub const notes_summary_empty = "{[presets]s}   pas encore de notes";
pub const notes_summary_last = "{[presets]s}   dernière note {[clock]s}  {[text]s}";
pub const notes_hint = "sur l'affichage : / saisit une note, Entrée la valide";
pub const notes_typing = "saisie d'une note";
pub const notes_drafts_one = "{[count]d} brouillon (` l'estampille)";
pub const notes_drafts_other = "{[count]d} brouillons (` en estampille un)";
pub const section_audio = "Audio";
pub const btn_mute = "muet";
pub const label_volume = "volume";
pub const btn_shaped = "modelé";
pub const btn_plain = "linéaire";
pub const btn_recalibrate = "recalibrer";
pub const audio_no_output = "pas de sortie audio";
pub const audio_listening = "écoute : {[what]s}";
pub const audio_listening_nothing = "rien (cliquer une ligne sur l'affichage)";
pub const audio_noise_held = "bruit {[sigma]d:.1} µV, mémorisé";
pub const audio_measuring = "mesure du bruit (3 s)";
pub const audio_gaps_one = "{[count]d} trou dans le son";
pub const audio_gaps_other = "{[count]d} trous dans le son";
pub const audio_muted = ", muet";
pub const audio_summary_off = "off{[muted]s}   {[db]d:.0} dB";
pub const audio_summary_nothing = "on{[muted]s}   {[db]d:.0} dB   n'écoute rien";
pub const audio_summary_on = "on{[muted]s}   {[db]d:.0} dB   écoute : {[what]s}   {[ms]d:.0} ms";

// ---- The control window: spikes and headstages ----

pub const section_spikes = "Spikes";
pub const label_threshold = "seuil";
pub const hint_below_zero = "sous zéro, il suit le bruit";
pub const section_headstages = "Headstages";
pub const board_restart_pending = "(redémarrage en attente)";
pub const board_not_saved = "(non sauvegardé par défaut)";
pub const board_summary_head = "{[rate]d} Hz   {[lower]s}–{[upper]s}   DSP ";
pub const board_summary_dsp_on = "on, {[cutoff]s}";
pub const board_summary_half = "   {[headstage]s} 16 sur 32";
pub const board_these_change = "(ces réglages changent ce qui est enregistré)";
pub const label_amplifier_band = "bande de l'ampli";
pub const label_dsp_highpass = "passe-haut DSP";
pub const label_cutoff = "coupure";
pub const label_sample_rate = "fréq. d'échantillonnage";
pub const btn_32_ch = "32 ch";
pub const btn_16_of_32 = "16 sur 32";
pub const btn_apply = "Appliquer (redémarre l'acquisition)";
pub const board_apply_after_stop = "fréquence d'échantillonnage et canaux modifiables une fois l'enregistrement arrêté";
pub const btn_save_default = "Sauvegarder par défaut";
pub const board_differs = "ces réglages diffèrent du fichier de configuration";

// ---- The control window: a panel's section ----

pub const btn_reset = "réinit.";
pub const summary_band_range = "   bande {[low]d}–{[high]d} Hz";
pub const summary_band_below = "   bande sous {[high]d} Hz";
pub const summary_band_above = "   bande au-dessus de {[low]d} Hz";
pub const summary_band_none = "   bande (sans coupure)";
pub const summary_on_ttl = "   sur TTL {[line]d}";
pub const summary_on_spikes = "   sur spikes, ligne {[row]d}";
pub const label_view = "vue";
pub const label_window = "fenêtre";
pub const label_time = "temps";
pub const label_scale = "échelle";
pub const stepper_per_row = "{[scale]s}/ligne";
pub const label_filter = "filtre";
pub const btn_band = "bande";
pub const label_rows_shown = "lignes";
pub const label_filtered = "filtrées";
pub const label_average_of = "moyenne de";
pub const label_subtract_from = "soustraire de";
pub const label_trigger = "déclencheur";
pub const btn_ttl = "TTL";
pub const btn_spikes = "spikes";
pub const trigger_row_value = "ligne {[row]d}";
pub const label_level = "niveau";
pub const label_holdoff = "holdoff";
pub const label_overlaid = "superposés";
pub const stepper_sweeps_one = "{[count]d} sweep";
pub const stepper_sweeps_other = "{[count]d} sweeps";

// ---- Alarms across the display (until acknowledged) ----

pub const alarm_acquisition_stopped = "ACQUISITION ARRÊTÉE ({[err]t}) : la carte n'est pas lue";
pub const alarm_no_data = "AUCUNE DONNÉE DE LA CARTE DEPUIS {[seconds]d:.1} s";
pub const alarm_quiet_times_one = "LA CARTE S'EST TUE UNE FOIS (0.5 s ou plus sans données)";
pub const alarm_quiet_times_other = "LA CARTE S'EST TUE {[times]d} FOIS (0.5 s ou plus sans données)";
pub const alarm_recording_failed = "ENREGISTREMENT ÉCHOUÉ : rien n'est enregistré";
pub const alarm_blocks_lost_one = "{[blocks]d} BLOC PERDU : le disque a pris 30 s de retard";
pub const alarm_blocks_lost_other = "{[blocks]d} BLOCS PERDUS : le disque a pris 30 s de retard";
pub const alarm_dropped_one = "LA CARTE A PERDU {[samples]d} ÉCHANTILLON";
pub const alarm_dropped_other = "LA CARTE A PERDU {[samples]d} ÉCHANTILLONS";
pub const alarm_gaps_one = "L'ENREGISTREMENT A {[gaps]d} TROU";
pub const alarm_gaps_other = "L'ENREGISTREMENT A {[gaps]d} TROUS";
pub const alarm_disk_full_in = "LE DISQUE SERA PLEIN DANS {[left]s}";

// ---- Warnings across the display (while their cause lasts) ----

pub const warn_acquisition_stopped = "acquisition arrêtée ({[err]t}) : rien n'est lu ; relancer dimna";
pub const warn_disk_behind = "le disque a {[behind]d:.0} s de retard (des échantillons sont perdus à 30 s)";
pub const warn_disk_full_in = "le disque sera plein dans {[left]s} ({[gb]d:.1} GB restants)";
/// "about 12 min", "about 40 s": the time left, in the disk messages.
pub const about_minutes = "environ {[count]d:.0} min";
pub const about_seconds = "environ {[count]d:.0} s";

// ---- Notes under the control window's board and recording lines ----

pub const note_cannot_create = "impossible de créer un enregistrement dans {[dir]s} : {[err]t}";
pub const note_cannot_start = "impossible de démarrer l'enregistreur : {[err]t}";
pub const note_recording_failed = "enregistrement échoué : {[err]t} ; ce qui a été écrit avant est intact";
pub const note_last_recording = "dernier enregistrement : {[length]s}   échantillons : {[samples]d}   trous : {[gaps]d}";
pub const note_saved_to = "sauvegardé dans {[path]s}";
pub const note_cannot_save_to = "impossible de sauvegarder dans {[path]s} : {[err]t}";
pub const note_band_edges = "la coupure basse doit rester sous la coupure haute";
pub const note_not_applied = "non appliqué : {[err]t}";
pub const note_view_saved = "vue sauvegardée dans {[path]s}";
pub const note_cannot_save = "impossible de sauvegarder {[path]s} : {[err]t}";
pub const note_stop_recording_first = "arrêter d'abord l'enregistrement : cela change la forme des données";
pub const note_board_refused = "la carte a refusé les nouveaux réglages : {[err]t}";

// ---- The notice over the display at start (where the colours came from) ----

pub const notice_colours_from = "couleurs prises dans {[name]s}";
pub const notice_colours_change = "pour les changer, modifier scheme_image dans {[where]s} (le retirer pour les couleurs intégrées)";
pub const notice_colours_failed = "{[reason]s} ; les couleurs intégrées sont utilisées";
pub const notice_colours_where = "scheme_image est dans {[where]s}";
