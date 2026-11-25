//! Every text the user sees, in Portuguese (Brazilian). The same names as `en.zig`; a message missing here
//! is shown in English. Conventions for translators: `docs/plans/translations.md`.

// ---- Words shared by several windows ----

/// A switch that is on (buttons, summaries).
pub const toggle_on = "on";
/// A switch that is off, or a corner that is not set.
pub const toggle_off = "off";
/// Common average reference (a button, a heading, a badge).
pub const label_car = "CAR";
/// Beside a row of a filtered panel that is drawn unfiltered.
pub const tag_raw = "bruto";
/// The control window's filter choice: no filter (beside "band").
pub const btn_raw = "bruto";
pub const btn_all = "todos";
pub const btn_none = "nenhum";
pub const slope_rising = "subida";
pub const slope_falling = "descida";
/// The display modes of a panel (buttons, and the first word of its summary).
pub const mode_scroll = "rolagem";
pub const mode_sweep = "sweep";
pub const mode_triggered = "disparado";
/// "6 presets" / "1 preset" (the control window's notes summary).
pub const presets_one = "{[count]d} preset";
pub const presets_other = "{[count]d} presets";
/// A filter's corners (the panel's band, the amplifier's band), beside their steppers.
pub const label_low = "baixa";
pub const label_high = "alta";

// ---- The neural display: panel titles ----

/// After a title's band, when the common average reference is on.
pub const title_car = "   CAR";
/// A panel's filter in its title: both corners, only the low one, only the high one, none.
pub const title_band_range = "   {[low]d}-{[high]d} Hz{[car]s}";
pub const title_band_above = "   > {[low]d} Hz{[car]s}";
pub const title_band_below = "   < {[high]d} Hz{[car]s}";
pub const title_band_none = "   filtro: sem cortes{[car]s}";
/// A triggered panel's title says "raw" where a band would be.
pub const title_raw = "   bruto";
pub const title_raw_car = "   bruto   CAR";
/// The scale of a panel's rows in its title and in the control window's summary.
pub const title_per_row = "   {[scale]s}/linha";
/// "5 sweeps" after a triggered panel's title.
pub const title_sweeps_one = "   {[count]d} sweep{[waiting]s}";
pub const title_sweeps_other = "   {[count]d} sweeps{[waiting]s}";
pub const title_waiting_for_trigger = " (aguardando disparo)";
pub const title_review = "   revisão";
pub const title_sweep = "   sweep";
/// What triggers a panel's sweeps, from a row of the display: "row 5 falling 4.5 σ" (before
/// the threshold is known) and "row 5 falling -62 µV".
pub const trigger_row_sigmas = "linha {[row]d} {[slope]s} {[sigmas]d} σ";
pub const trigger_row_level = "linha {[row]d} {[slope]s} {[uv]d:.0} µV";
/// Tip over a triggered panel's filter text when it is not the detector's band.
pub const tip_band_header = "Estes sweeps são desenhados com o filtro deste painel: {[band]s}.";
pub const tip_band_none = "nenhum (bruto)";
pub const tip_band_line2 = "A detecção de spikes e o gatilho por inclinação sempre usam 300-6000 Hz,";
pub const tip_band_line3 = "então os sweeps podem não se parecer com as formas de onda dos tiles de spikes.";

// ---- The neural display: rows, banners, status ----

/// A row drawn with a threshold the row's band does not show.
pub const tag_threshold = "lim";
/// In review with nothing to draw yet, where the traces would be.
pub const waiting_overview = "montando a visão geral deste trecho";
pub const waiting_reading = "lendo a gravação";
/// The alarm bar's second line.
pub const alarm_hint = "para confirmar, pressione Shift+a";
/// The review badge, top centre; `state` is one of the two messages after it, or empty.
pub const review_badge = "REVISÃO   {[behind]d:.1} s atrás do ao vivo   em {[clock]s}{[state]s}   l = ao vivo";
pub const review_reading = "   (lendo)";
pub const review_building = "   (montando a visão geral)";
/// The note being typed, bottom left.
pub const note_draft = "nota em {[clock]s}:  {[text]s}_";
/// Bottom right, when the display missed blocks.
pub const readout_skipped_one = "{[ms]d:.1} ms   {[fps]d} fps   display pulou {[blocks]d} bloco";
pub const readout_skipped_other = "{[ms]d:.1} ms   {[fps]d} fps   display pulou {[blocks]d} blocos";
/// The recording's clock beside it.
pub const readout_rec = "REC {[clock]s}";

// ---- The key summary (?) ----
// A text that is ASCII is drawn in the fixed-width font, any other in the ordinary one.

pub const help_title = "Teclas e mouse   (? ou Esc fecha)";
pub const help_heading_display = "No display";
pub const help_heading_tiles = "Na janela dos tiles de spikes";

pub const key_wheel = "roda";
pub const key_ctrl_wheel = "Ctrl+roda";
pub const key_shift_wheel = "Shift+roda";
pub const key_ctrl_shift_wheel = "Ctrl+Shift+roda";
pub const key_sideways_scroll = "rolagem lateral";
pub const key_alt_wheel = "Alt+roda";
pub const key_touchpad_pinch = "pinça do touchpad";
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
pub const key_left_click_row = "clique esquerdo em uma linha";
pub const key_right_click_row = "clique direito em uma linha";
pub const key_ctrl_right_click = "Ctrl+clique direito";
pub const key_middle_click = "clique do meio";
pub const key_drag_red_line = "arrastar uma linha vermelha";
pub const key_n = "n";
pub const key_space = "Espaço";
pub const key_left_right = "Esquerda / Direita";
pub const key_pgup_pgdn = "PgUp / PgDn";
pub const key_home_end = "Home / End";
pub const key_l = "l";
pub const key_slash = "/";
pub const key_backtick = "`";
pub const key_1_9 = "1-9";
pub const key_tilde = "~";
pub const key_shift_a = "Shift+a";
pub const key_question = "?";
pub const key_ctrl_q_or_esc = "Ctrl+Q ou Esc";
pub const key_a = "a";
pub const key_u = "u";
pub const key_shift_u = "Shift+u";
pub const key_left_click = "clique esquerdo";
pub const key_right_click = "clique direito";
pub const key_drag_the_red_line = "arrastar a linha vermelha";
pub const key_the_chips = "os chips";

pub const help_y_scale_uv = "escala Y (µV por linha)";
pub const help_y_scale_row = "escala Y só da linha";
pub const help_back_forward_review = "voltar / avançar no tempo (revisão)";
pub const help_same_as_shift_wheel = "o mesmo que Shift+roda";
pub const help_time_base_window = "base de tempo (disparado: janela)";
pub const help_time_base = "base de tempo";
pub const help_y_scale = "escala Y";
pub const help_panel_as_configured = "o painel como configurado";
pub const help_scrolling_sweep = "rolagem <-> sweep";
pub const help_filter_toggle = "filtro de exibição on / off";
pub const help_low_corner = "corte baixo para baixo / cima";
pub const help_high_corner = "corte alto para baixo / cima";
pub const help_triggered_toggle = "sweeps disparados on / off";
pub const help_triggered_line = "disparado por TTL: a linha";
pub const help_triggered_source = "disparado: TTL <-> spikes, esta linha";
pub const help_focus_trigger = "foco (spikes: disparar ali)";
pub const help_listen_alone = "ouvir só ela";
pub const help_sound_add_take = "somar ao / tirar do som";
pub const help_no_focus = "nenhum canal em foco";
pub const help_threshold_fixed_uv = "seu limiar, fixo (µV)";
pub const help_threshold_fixed_noise = "limiar: fixo <-> segue o ruído";
pub const help_freeze = "congelar / voltar ao vivo";
pub const help_back_forward_tenth = "voltar / avançar 1/10 de janela";
pub const help_back_forward_window = "voltar / avançar uma janela";
pub const help_start_live = "início da gravação / ao vivo";
pub const help_back_to_live = "voltar ao vivo";
pub const help_type_note = "digitar uma nota (Enter salva)";
pub const help_stamp_draft = "carimbar o primeiro rascunho";
pub const help_stamp_preset = "carimbar uma nota predefinida";
pub const help_adc_toggle = "ocultar / mostrar os painéis ADC";
pub const help_acknowledge = "confirmar um alarme";
pub const help_these_keys = "estas teclas (? ou Esc fecha)";
pub const help_quit = "sair";
pub const help_tiles_scale_shown = "mudar a escala dos tiles exibidos";
pub const help_tiles_scale_one = "mudar a escala só deste tile";
pub const help_tiles_threshold = "o limiar do tile";
pub const help_tiles_common_range = "tiles exibidos: faixa comum";
pub const help_tiles_own_range = "tiles exibidos: faixa própria, fixa";
pub const help_undo_scale = "desfazer mudança de escala";
pub const help_redo_scale = "refazer mudança de escala";
pub const help_focus_channel = "focar esse canal";
pub const help_tiles_chips = "tiles de uma porta, ou todos";

// ---- The spike-tile window ----

/// The chip that shows the tiles of every port.
pub const tiles_all = "Todos";
/// The range of the tiles shown, beside the chips: each tile on its own, or differing.
pub const tiles_range_auto = "auto";
pub const tiles_range_mixed = "misto";

// ---- The control window: the title, status and recording ----

pub const btn_acknowledge = "Confirmar";
pub const quit_heading = "Configurações alteradas desde o último salvamento:";
pub const quit_recording_heading = "Uma gravação está em andamento. Sair a interrompe; o que já foi gravado é mantido.";
pub const btn_stop_recording_and_quit = "Parar gravação e sair";
pub const btn_keep_recording = "Continuar gravando";
pub const notice_quit_recording = "Uma gravação está em andamento";
pub const notice_quit_recording_how = "Ctrl+Q de novo enquanto isto aparece a interrompe e sai";
pub const quit_panel_views = "vistas dos painéis (salvas em views.toml)";
pub const btn_save_and_quit = "Salvar como padrão e sair";
pub const btn_quit_without_saving = "Sair sem salvar";
pub const btn_cancel = "Cancelar";
pub const status_display = "display {[ms]d:.1} ms   {[fps]d} fps   rodando há {[seconds]d:.0} s";
pub const status_starting = "iniciando";
pub const status_display_skipped_one = "display pulou {[blocks]d} bloco";
pub const status_display_skipped_other = "display pulou {[blocks]d} blocos";
pub const status_ring_overflow = "ESTOURO DO ANEL DE AQUISIÇÃO {[count]d}";
pub const btn_save_view = "Salvar vista";
pub const btn_quit = "Sair";
pub const btn_record = "Gravar";
pub const btn_stop_recording = "Parar gravação";
pub const rec_finishing = "finalizando a gravação";
pub const rec_status = "REC {[clock]s}   {[gb]d:.2} GB   {[msamples]d:.1} M amostras";
pub const rec_disk_behind = "disco {[behind]d:.1} s atrasado";
pub const rec_gaps_one = "{[gaps]d} lacuna";
pub const rec_gaps_other = "{[gaps]d} lacunas";
pub const rec_failed = "FALHA NA GRAVAÇÃO";
pub const rec_idle = "sem gravação";
pub const rec_disk_free = "disco: {[gb]d:.1} GB livres, {[left]s} nesta configuração";
pub const rec_disk_too_full = "disco: {[gb]d:.1} GB livres, são necessários ao menos {[need]d:.0} GB para gravar";
/// The line about the source, at the top.
pub const about_source = "{[source]s}   {[rate]d} Hz   canais: {[channels]d}, eletrodos: {[electrodes]d}";
pub const source_simulated = "placa simulada";
pub const source_board = "placa de aquisição Open Ephys";
/// The display window's title bar, refreshed once a second.
pub const window_title_status = "dimna   {[panel]s}: {[span]d:.2} s  {[scale]d:.1} {[unit]s}/linha   latência {[ms]d:.1} ms   {[fps]d} fps";
/// The last line of the control window.
pub const hint_keys = "Pressione ? no display para ver suas teclas e ações do mouse, e as da janela de tiles.";

// ---- The control window: notes and audio ----

pub const section_notes = "Notas";
pub const notes_summary_empty = "{[presets]s}   ainda sem notas";
pub const notes_summary_last = "{[presets]s}   última nota {[clock]s}  {[text]s}";
pub const notes_hint = "no display: / digita uma nota, Enter salva";
pub const notes_typing = "digitando uma nota";
pub const notes_drafts_one = "{[count]d} rascunho (` carimba)";
pub const notes_drafts_other = "{[count]d} rascunhos (` carimba um)";
pub const section_audio = "Áudio";
pub const btn_mute = "mudo";
pub const label_volume = "volume";
pub const btn_shaped = "modelado";
pub const btn_plain = "linear";
pub const btn_recalibrate = "recalibrar";
pub const audio_no_output = "sem saída de áudio";
pub const audio_listening = "ouvindo {[what]s}";
pub const audio_listening_nothing = "nada (clique em uma linha no display)";
pub const audio_noise_held = "ruído {[sigma]d:.1} µV, mantido";
pub const audio_measuring = "medindo o ruído (3 s)";
pub const audio_gaps_one = "{[count]d} lacuna no som";
pub const audio_gaps_other = "{[count]d} lacunas no som";
pub const audio_muted = ", mudo";
pub const audio_summary_off = "off{[muted]s}   {[db]d:.0} dB";
pub const audio_summary_nothing = "on{[muted]s}   {[db]d:.0} dB   ouvindo nada";
pub const audio_summary_on = "on{[muted]s}   {[db]d:.0} dB   ouvindo {[what]s}   {[ms]d:.0} ms";

// ---- The control window: spikes and headstages ----

pub const section_spikes = "Spikes";
pub const label_threshold = "limiar";
pub const hint_below_zero = "abaixo de zero, onde segue o ruído";
pub const section_headstages = "Headstages";
pub const board_restart_pending = "(reinício pendente)";
pub const board_not_saved = "(não salvo como padrão)";
pub const board_summary_head = "{[rate]d} Hz   {[lower]s}–{[upper]s}   DSP ";
pub const board_summary_dsp_on = "on, {[cutoff]s}";
pub const board_summary_half = "   {[headstage]s} 16 de 32";
pub const board_these_change = "(estes alteram o que é gravado)";
pub const label_amplifier_band = "banda do amplificador";
pub const label_dsp_highpass = "passa-altas DSP";
pub const label_cutoff = "corte";
pub const label_sample_rate = "taxa de amostragem";
pub const btn_32_ch = "32 ch";
pub const btn_16_of_32 = "16 de 32";
pub const btn_apply = "Aplicar (reinicia a aquisição)";
pub const board_apply_after_stop = "taxa de amostragem e canais só mudam com a gravação parada";
pub const btn_save_default = "Salvar como padrão";
pub const board_differs = "estas configurações diferem do arquivo de configuração";

// ---- The control window: a panel's section ----

pub const btn_reset = "zerar";
pub const summary_band_range = "   banda {[low]d}–{[high]d} Hz";
pub const summary_band_below = "   banda abaixo de {[high]d} Hz";
pub const summary_band_above = "   banda acima de {[low]d} Hz";
pub const summary_band_none = "   banda (sem cortes)";
pub const summary_on_ttl = "   em TTL {[line]d}";
pub const summary_on_spikes = "   em spikes, linha {[row]d}";
pub const label_view = "vista";
pub const label_window = "janela";
pub const label_time = "tempo";
pub const label_scale = "escala";
pub const stepper_per_row = "{[scale]s}/linha";
pub const label_filter = "filtro";
pub const btn_band = "banda";
pub const label_rows_shown = "linhas";
pub const label_filtered = "filtradas";
pub const label_average_of = "média de";
pub const label_subtract_from = "subtrair de";
pub const label_trigger = "gatilho";
pub const btn_ttl = "TTL";
pub const btn_spikes = "spikes";
pub const trigger_row_value = "linha {[row]d}";
pub const label_level = "nível";
pub const label_holdoff = "holdoff";
pub const label_overlaid = "sobrepostos";
pub const stepper_sweeps_one = "{[count]d} sweep";
pub const stepper_sweeps_other = "{[count]d} sweeps";

// ---- Alarms across the display (until acknowledged) ----

pub const alarm_acquisition_stopped = "AQUISIÇÃO PARADA ({[err]t}): a placa não está sendo lida";
pub const alarm_no_data = "SEM DADOS DA PLACA HÁ {[seconds]d:.1} s";
pub const alarm_quiet_times_one = "A PLACA FICOU MUDA UMA VEZ (0.5 s ou mais sem dados)";
pub const alarm_quiet_times_other = "A PLACA FICOU MUDA {[times]d} VEZES (0.5 s ou mais sem dados)";
pub const alarm_recording_failed = "FALHA NA GRAVAÇÃO: nada está sendo gravado";
pub const alarm_blocks_lost_one = "{[blocks]d} BLOCO PERDIDO: o disco atrasou 30 s";
pub const alarm_blocks_lost_other = "{[blocks]d} BLOCOS PERDIDOS: o disco atrasou 30 s";
pub const alarm_dropped_one = "A PLACA PERDEU {[samples]d} AMOSTRA";
pub const alarm_dropped_other = "A PLACA PERDEU {[samples]d} AMOSTRAS";
pub const alarm_gaps_one = "A GRAVAÇÃO TEM {[gaps]d} LACUNA";
pub const alarm_gaps_other = "A GRAVAÇÃO TEM {[gaps]d} LACUNAS";
pub const alarm_disk_full_in = "O DISCO ENCHE EM {[left]s}";

// ---- Warnings across the display (while their cause lasts) ----

pub const warn_acquisition_stopped = "aquisição parada ({[err]t}): nada está sendo lido; reinicie o dimna";
pub const warn_disk_behind = "o disco está {[behind]d:.0} s atrasado (amostras se perdem aos 30 s)";
pub const warn_disk_full_in = "o disco enche em {[left]s} ({[gb]d:.1} GB livres)";
/// "about 12 min", "about 40 s": the time left, in the disk messages.
pub const about_minutes = "cerca de {[count]d:.0} min";
pub const about_seconds = "cerca de {[count]d:.0} s";
pub const about_hours = "cerca de {[hours]d} h {[minutes]d} min";

// ---- Notes under the control window's board and recording lines ----

pub const note_cannot_create = "não foi possível criar uma gravação em {[dir]s}: {[err]t}";
pub const note_cannot_start = "não foi possível iniciar o gravador: {[err]t}";
pub const note_disk_too_full = "sem gravação: {[gb]d:.1} GB livres em {[dir]s}, são necessários ao menos {[need]d:.0} GB";
pub const note_recording_failed = "falha na gravação: {[err]t}; o que foi escrito antes está intacto";
pub const note_last_recording = "última gravação: {[length]s}   amostras: {[samples]d}   lacunas: {[gaps]d}";
pub const note_saved_to = "salvo em {[path]s}";
pub const note_cannot_save_to = "não foi possível salvar em {[path]s}: {[err]t}";
pub const note_band_edges = "o corte baixo da banda deve ficar abaixo do alto";
pub const note_not_applied = "não aplicado: {[err]t}";
pub const note_view_saved = "vista salva em {[path]s}";
pub const note_cannot_save = "não foi possível salvar {[path]s}: {[err]t}";
pub const note_stop_recording_first = "pare a gravação antes: isso muda o formato dos dados";
pub const note_board_refused = "a placa recusou as novas configurações: {[err]t}";

// ---- The notice over the display at start (where the colours came from) ----

pub const notice_colours_from = "cores tiradas de {[name]s}";
pub const notice_colours_change = "para mudá-las, edite scheme_image em {[where]s} (remova para as cores internas)";
pub const notice_colours_failed = "{[reason]s}; as cores internas são usadas";
pub const notice_colours_where = "scheme_image está em {[where]s}";
