//! Every text the user sees, in Persian. The same names as `en.zig`; a message missing here
//! is shown in English. Conventions for translators: `docs/plans/translations.md`.

// ---- Words shared by several windows ----

/// A switch that is on (buttons, summaries).
pub const toggle_on = "روشن";
/// A switch that is off, or a corner that is not set.
pub const toggle_off = "خاموش";
/// Common average reference (a button, a heading, a badge).
pub const label_car = "CAR";
/// Beside a row of a filtered panel that is drawn unfiltered.
pub const tag_raw = "خام";
/// The control window's filter choice: no filter (beside "band").
pub const btn_raw = "خام";
pub const btn_all = "همه";
pub const btn_none = "هیچ";
pub const slope_rising = "صعودی";
pub const slope_falling = "نزولی";
/// The display modes of a panel (buttons, and the first word of its summary).
pub const mode_scroll = "اسکرول";
pub const mode_sweep = "سوییپ";
pub const mode_triggered = "با تریگر";
/// "6 presets" / "1 preset" (the control window's notes summary).
pub const presets_one = "{[count]d} پیش\u{200C}تنظیم";
pub const presets_other = "{[count]d} پیش\u{200C}تنظیم";
/// A filter's corners (the panel's band, the amplifier's band), beside their steppers.
pub const label_low = "پایین";
pub const label_high = "بالا";

// ---- The neural display: panel titles ----

/// After a title's band, when the common average reference is on.
pub const title_car = "   CAR";
/// A panel's filter in its title: both corners, only the low one, only the high one, none.
pub const title_band_range = "   {[low]d}-{[high]d} Hz{[car]s}";
pub const title_band_above = "   بالای {[low]d} Hz{[car]s}";
pub const title_band_below = "   زیر {[high]d} Hz{[car]s}";
pub const title_band_none = "   فیلتر: بدون فرکانس قطع{[car]s}";
/// A triggered panel's title says "raw" where a band would be.
pub const title_raw = "   خام";
pub const title_raw_car = "   خام   CAR";
/// The scale of a panel's rows in its title and in the control window's summary.
pub const title_per_row = "   {[scale]s}/ردیف";
/// "5 sweeps" after a triggered panel's title.
pub const title_sweeps_one = "   {[count]d} سوییپ{[waiting]s}";
pub const title_sweeps_other = "   {[count]d} سوییپ{[waiting]s}";
pub const title_waiting_for_trigger = " (در انتظار تریگر)";
pub const title_review = "   بازبینی";
pub const title_sweep = "   سوییپ";
/// What triggers a panel's sweeps, from a row of the display: "row 5 falling 4.5 σ" (before
/// the threshold is known) and "row 5 falling -62 µV".
pub const trigger_row_sigmas = "ردیف {[row]d} {[slope]s} {[sigmas]d} σ";
pub const trigger_row_level = "ردیف {[row]d} {[slope]s} {[uv]d:.0} µV";
/// Tip over a triggered panel's filter text when it is not the detector's band.
pub const tip_band_header = "این سوییپ\u{200C}ها با فیلتر این پنل رسم می\u{200C}شوند: {[band]s}.";
pub const tip_band_none = "هیچ (خام)";
pub const tip_band_line2 = "تشخیص اسپایک و تریگر شیب همیشه از 300-6000 Hz استفاده می\u{200C}کنند،";
pub const tip_band_line3 = "پس ممکن است سوییپ\u{200C}ها شبیه شکل موج کاشی\u{200C}های اسپایک نباشند.";

// ---- The neural display: rows, banners, status ----

/// A row drawn with a threshold the row's band does not show.
pub const tag_threshold = "آستانه";
/// In review with nothing to draw yet, where the traces would be.
pub const waiting_overview = "در حال ساخت نمای کلی این بازه";
pub const waiting_reading = "در حال خواندن ثبت";
/// The alarm bar's second line.
pub const alarm_hint = "برای تأیید Shift+a را بزنید";
/// The review badge, top centre; `state` is one of the two messages after it, or empty.
pub const review_badge = "بازبینی   {[behind]d:.1} s عقب\u{200C}تر از زنده   در {[clock]s}{[state]s}   l = زنده";
pub const review_reading = "   (در حال خواندن)";
pub const review_building = "   (در حال ساخت نمای کلی)";
/// The note being typed, bottom left.
pub const note_draft = "یادداشت در {[clock]s}:  {[text]s}_";
/// Bottom right, when the display missed blocks.
pub const readout_skipped_one = "{[ms]d:.1} ms   {[fps]d} fps   نمایش {[blocks]d} بلوک را جا انداخت";
pub const readout_skipped_other = "{[ms]d:.1} ms   {[fps]d} fps   نمایش {[blocks]d} بلوک را جا انداخت";
/// The recording's clock beside it.
pub const readout_rec = "REC {[clock]s}";

// ---- The key summary (?) ----
// A text that is ASCII is drawn in the fixed-width font, any other in the ordinary one.

pub const help_title = "کلیدها و ماوس   (? یا Esc این را می\u{200C}بندد)";
pub const help_heading_display = "روی نمایشگر";
pub const help_heading_tiles = "در پنجره کاشی\u{200C}های اسپایک";

pub const key_wheel = "چرخ";
pub const key_ctrl_wheel = "Ctrl+چرخ";
pub const key_shift_wheel = "Shift+چرخ";
pub const key_ctrl_shift_wheel = "Ctrl+Shift+چرخ";
pub const key_sideways_scroll = "اسکرول افقی";
pub const key_alt_wheel = "Alt+چرخ";
pub const key_touchpad_pinch = "پینچ روی تاچ\u{200C}پد";
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
pub const key_left_click_row = "کلیک چپ روی ردیف";
pub const key_right_click_row = "کلیک راست روی ردیف";
pub const key_ctrl_right_click = "Ctrl+کلیک راست";
pub const key_middle_click = "کلیک وسط";
pub const key_drag_red_line = "کشیدن یک خط قرمز";
pub const key_n = "n";
pub const key_space = "Space";
pub const key_left_right = "چپ / راست";
pub const key_pgup_pgdn = "PgUp / PgDn";
pub const key_home_end = "Home / End";
pub const key_l = "l";
pub const key_slash = "/";
pub const key_backtick = "`";
pub const key_1_9 = "1-9";
pub const key_tilde = "~";
pub const key_shift_a = "Shift+a";
pub const key_question = "?";
pub const key_q_or_esc = "q یا Esc";
pub const key_a = "a";
pub const key_u = "u";
pub const key_shift_u = "Shift+u";
pub const key_left_click = "کلیک چپ";
pub const key_right_click = "کلیک راست";
pub const key_drag_the_red_line = "کشیدن خط قرمز";
pub const key_the_chips = "دکمه\u{200C}ها";

pub const help_y_scale_uv = "مقیاس Y (µV در هر ردیف)";
pub const help_y_scale_row = "مقیاس Y فقط همین ردیف";
pub const help_back_forward_review = "عقب / جلو در زمان (بازبینی)";
pub const help_same_as_shift_wheel = "همانند Shift+چرخ";
pub const help_time_base_window = "پایه زمانی (با تریگر: پنجره)";
pub const help_time_base = "پایه زمانی";
pub const help_y_scale = "مقیاس Y";
pub const help_panel_as_configured = "پنل طبق تنظیمات";
pub const help_scrolling_sweep = "اسکرول <-> سوییپ";
pub const help_filter_toggle = "فیلتر نمایش روشن / خاموش";
pub const help_low_corner = "فرکانس قطع پایین کم / زیاد";
pub const help_high_corner = "فرکانس قطع بالا کم / زیاد";
pub const help_triggered_toggle = "سوییپ با تریگر روشن / خاموش";
pub const help_triggered_line = "تریگر با TTL: شماره خط";
pub const help_triggered_source = "تریگر: TTL <-> اسپایک، این ردیف";
pub const help_focus_trigger = "فوکوس (اسپایک: تریگر همان\u{200C}جا)";
pub const help_listen_alone = "فقط به آن گوش دادن";
pub const help_sound_add_take = "افزودن به صدا / حذف از صدا";
pub const help_no_focus = "هیچ کانالی در فوکوس نباشد";
pub const help_threshold_fixed_uv = "آستانه آن، ثابت (µV)";
pub const help_threshold_fixed_noise = "آستانه: ثابت <-> تابع نویز";
pub const help_freeze = "ثابت کردن / بازگشت به زنده";
pub const help_back_forward_tenth = "عقب / جلو 1/10 پنجره";
pub const help_back_forward_window = "عقب / جلو یک پنجره";
pub const help_start_live = "شروع ثبت / زنده";
pub const help_back_to_live = "بازگشت به زنده";
pub const help_type_note = "نوشتن یادداشت (Enter ذخیره می\u{200C}کند)";
pub const help_stamp_draft = "درج اولین یادداشت پیش\u{200C}نویس";
pub const help_stamp_preset = "درج یک یادداشت پیش\u{200C}تنظیم";
pub const help_adc_toggle = "پنهان / نمایش پنل\u{200C}های ADC";
pub const help_acknowledge = "تأیید یک هشدار";
pub const help_these_keys = "همین کلیدها (? یا Esc می\u{200C}بندد)";
pub const help_quit = "خروج";
pub const help_tiles_scale_shown = "مقیاس کاشی\u{200C}های نمایان";
pub const help_tiles_scale_one = "مقیاس فقط همین کاشی";
pub const help_tiles_threshold = "آستانه کاشی";
pub const help_tiles_common_range = "کاشی\u{200C}های نمایان: محدوده مشترک";
pub const help_tiles_own_range = "کاشی\u{200C}های نمایان: محدوده خود، ثابت";
pub const help_undo_scale = "واگرد تغییر مقیاس";
pub const help_redo_scale = "انجام دوباره تغییر مقیاس";
pub const help_focus_channel = "فوکوس روی آن کانال";
pub const help_tiles_chips = "کاشی\u{200C}های یک پورت، یا همه";

// ---- The spike-tile window ----

/// The chip that shows the tiles of every port.
pub const tiles_all = "همه";
/// The range of the tiles shown, beside the chips: each tile on its own, or differing.
pub const tiles_range_auto = "خودکار";
pub const tiles_range_mixed = "متفاوت";

// ---- The control window: the title, status and recording ----

pub const btn_acknowledge = "تأیید";
pub const quit_heading = "تنظیماتی که از آخرین ذخیره تغییر کرده\u{200C}اند:";
pub const quit_panel_views = "نمای پنل\u{200C}ها (ذخیره در views.toml)";
pub const btn_save_and_quit = "ذخیره به\u{200C}عنوان پیش\u{200C}فرض و خروج";
pub const btn_quit_without_saving = "خروج بدون ذخیره";
pub const btn_cancel = "لغو";
pub const status_display = "نمایش {[ms]d:.1} ms   {[fps]d} fps   در حال اجرا {[seconds]d:.0} s";
pub const status_starting = "در حال شروع";
pub const status_display_skipped_one = "نمایش {[blocks]d} بلوک را جا انداخت";
pub const status_display_skipped_other = "نمایش {[blocks]d} بلوک را جا انداخت";
pub const status_ring_overflow = "سرریز بافر دریافت {[count]d}";
pub const btn_save_view = "ذخیره نما";
pub const btn_quit = "خروج";
pub const btn_record = "شروع ثبت";
pub const btn_stop_recording = "توقف ثبت";
pub const rec_finishing = "در حال پایان دادن به ثبت";
pub const rec_status = "REC {[clock]s}   {[gb]d:.2} GB   {[msamples]d:.1} میلیون نمونه";
pub const rec_disk_behind = "دیسک {[behind]d:.1} s عقب است";
pub const rec_gaps_one = "{[gaps]d} شکاف";
pub const rec_gaps_other = "{[gaps]d} شکاف";
pub const rec_failed = "ثبت ناموفق";
pub const rec_idle = "ثبت نمی\u{200C}شود";
/// The line about the source, at the top.
pub const about_source = "{[source]s}   {[rate]d} Hz   کانال: {[channels]d}، الکترود: {[electrodes]d}";
pub const source_simulated = "برد شبیه\u{200C}سازی\u{200C}شده";
pub const source_board = "برد دریافت داده Open Ephys";
/// The display window's title bar, refreshed once a second.
pub const window_title_status = "dimna   {[panel]s}: {[span]d:.2} s  {[scale]d:.1} {[unit]s}/ردیف   تأخیر {[ms]d:.1} ms   {[fps]d} fps";
/// The last line of the control window.
pub const hint_keys = "برای کلیدها و کارهای ماوس نمایشگر و پنجره کاشی\u{200C}ها، روی نمایشگر ? را بزنید.";

// ---- The control window: notes and audio ----

pub const section_notes = "یادداشت\u{200C}ها";
pub const notes_summary_empty = "{[presets]s}   هنوز یادداشتی نیست";
pub const notes_summary_last = "{[presets]s}   آخرین یادداشت {[clock]s}  {[text]s}";
pub const notes_hint = "روی نمایشگر: / برای نوشتن یادداشت، Enter برای ذخیره";
pub const notes_typing = "در حال نوشتن یادداشت";
pub const notes_drafts_one = "{[count]d} پیش\u{200C}نویس (` آن را درج می\u{200C}کند)";
pub const notes_drafts_other = "{[count]d} پیش\u{200C}نویس (` یکی را درج می\u{200C}کند)";
pub const section_audio = "صدا";
pub const btn_mute = "بی\u{200C}صدا";
pub const label_volume = "بلندی";
pub const btn_shaped = "پردازش\u{200C}شده";
pub const btn_plain = "ساده";
pub const btn_recalibrate = "کالیبره دوباره";
pub const audio_no_output = "بدون خروجی صدا";
pub const audio_listening = "گوش دادن به {[what]s}";
pub const audio_listening_nothing = "هیچ (روی یک ردیف نمایشگر کلیک کنید)";
pub const audio_noise_held = "نویز {[sigma]d:.1} µV، ثابت";
pub const audio_measuring = "در حال اندازه\u{200C}گیری نویز (3 s)";
pub const audio_gaps_one = "{[count]d} وقفه در صدا";
pub const audio_gaps_other = "{[count]d} وقفه در صدا";
pub const audio_muted = "، بی\u{200C}صدا";
pub const audio_summary_off = "خاموش{[muted]s}   {[db]d:.0} dB";
pub const audio_summary_nothing = "روشن{[muted]s}   {[db]d:.0} dB   بدون کانال";
pub const audio_summary_on = "روشن{[muted]s}   {[db]d:.0} dB   گوش دادن به {[what]s}   {[ms]d:.0} ms";

// ---- The control window: spikes and headstages ----

pub const section_spikes = "اسپایک\u{200C}ها";
pub const label_threshold = "آستانه";
pub const hint_below_zero = "زیر صفر: تابع نویز";
pub const section_headstages = "هداستیج\u{200C}ها";
pub const board_restart_pending = "(در انتظار راه\u{200C}اندازی دوباره)";
pub const board_not_saved = "(به\u{200C}عنوان پیش\u{200C}فرض ذخیره نشده)";
pub const board_summary_head = "{[rate]d} Hz   {[lower]s}–{[upper]s}   DSP ";
pub const board_summary_dsp_on = "روشن، {[cutoff]s}";
pub const board_summary_half = "   {[headstage]s} 16 از 32";
pub const board_these_change = "(این\u{200C}ها آنچه ثبت می\u{200C}شود را تغییر می\u{200C}دهند)";
pub const label_amplifier_band = "باند تقویت\u{200C}کننده";
pub const label_dsp_highpass = "بالاگذر DSP";
pub const label_cutoff = "فرکانس قطع";
pub const label_sample_rate = "نرخ نمونه\u{200C}برداری";
pub const btn_32_ch = "32 کانال";
pub const btn_16_of_32 = "16 از 32";
pub const btn_apply = "اعمال (دریافت از نو شروع می\u{200C}شود)";
pub const board_apply_after_stop = "نرخ نمونه\u{200C}برداری و کانال\u{200C}ها پس از توقف ثبت قابل تغییرند";
pub const btn_save_default = "ذخیره به\u{200C}عنوان پیش\u{200C}فرض";
pub const board_differs = "این تنظیمات با فایل پیکربندی فرق دارند";

// ---- The control window: a panel's section ----

pub const btn_reset = "بازنشانی";
pub const summary_band_range = "   باند {[low]d}–{[high]d} Hz";
pub const summary_band_below = "   باند زیر {[high]d} Hz";
pub const summary_band_above = "   باند بالای {[low]d} Hz";
pub const summary_band_none = "   باند (بدون فرکانس قطع)";
pub const summary_on_ttl = "   با TTL {[line]d}";
pub const summary_on_spikes = "   با اسپایک، ردیف {[row]d}";
pub const label_view = "نما";
pub const label_window = "پنجره";
pub const label_time = "زمان";
pub const label_scale = "مقیاس";
pub const stepper_per_row = "{[scale]s}/ردیف";
pub const label_filter = "فیلتر";
pub const btn_band = "باند";
pub const label_rows_shown = "ردیف\u{200C}های نمایان";
pub const label_filtered = "فیلترشده";
pub const label_average_of = "میانگین از";
pub const label_subtract_from = "کسر از";
pub const label_trigger = "تریگر";
pub const btn_ttl = "TTL";
pub const btn_spikes = "اسپایک";
pub const trigger_row_value = "ردیف {[row]d}";
pub const label_level = "سطح";
pub const label_holdoff = "مکث";
pub const label_overlaid = "روی هم";
pub const stepper_sweeps_one = "{[count]d} سوییپ";
pub const stepper_sweeps_other = "{[count]d} سوییپ";

// ---- Alarms across the display (until acknowledged) ----

pub const alarm_acquisition_stopped = "دریافت داده متوقف شد ({[err]t}): برد خوانده نمی\u{200C}شود";
pub const alarm_no_data = "بدون داده از برد به مدت {[seconds]d:.1} s";
pub const alarm_quiet_times_one = "برد یک بار ساکت ماند (0.5 s یا بیشتر بدون داده)";
pub const alarm_quiet_times_other = "برد {[times]d} بار ساکت ماند (0.5 s یا بیشتر بدون داده)";
pub const alarm_recording_failed = "ثبت ناموفق: هیچ چیز ثبت نمی\u{200C}شود";
pub const alarm_blocks_lost_one = "{[blocks]d} بلوک از دست رفت: دیسک 30 s عقب افتاد";
pub const alarm_blocks_lost_other = "{[blocks]d} بلوک از دست رفت: دیسک 30 s عقب افتاد";
pub const alarm_dropped_one = "برد {[samples]d} نمونه را از دست داد";
pub const alarm_dropped_other = "برد {[samples]d} نمونه را از دست داد";
pub const alarm_gaps_one = "ثبت {[gaps]d} شکاف دارد";
pub const alarm_gaps_other = "ثبت {[gaps]d} شکاف دارد";
pub const alarm_disk_full_in = "دیسک تا {[left]s} دیگر پر می\u{200C}شود";

// ---- Warnings across the display (while their cause lasts) ----

pub const warn_acquisition_stopped = "دریافت داده متوقف شد ({[err]t}): چیزی خوانده نمی\u{200C}شود؛ dimna را دوباره اجرا کنید";
pub const warn_disk_behind = "دیسک {[behind]d:.0} s عقب است (در 30 s نمونه\u{200C}ها از دست می\u{200C}روند)";
pub const warn_disk_full_in = "دیسک تا {[left]s} دیگر پر می\u{200C}شود ({[gb]d:.1} GB باقی\u{200C}مانده)";
/// "about 12 min", "about 40 s": the time left, in the disk messages.
pub const about_minutes = "حدود {[count]d:.0} min";
pub const about_seconds = "حدود {[count]d:.0} s";

// ---- Notes under the control window's board and recording lines ----

pub const note_cannot_create = "ایجاد ثبت در {[dir]s} ممکن نشد: {[err]t}";
pub const note_cannot_start = "راه\u{200C}اندازی ثبت\u{200C}کننده ممکن نشد: {[err]t}";
pub const note_recording_failed = "ثبت ناموفق: {[err]t}؛ آنچه پیش از این نوشته شده سالم است";
pub const note_last_recording = "آخرین ثبت: {[length]s}   نمونه\u{200C}ها: {[samples]d}   شکاف\u{200C}ها: {[gaps]d}";
pub const note_saved_to = "در {[path]s} ذخیره شد";
pub const note_cannot_save_to = "ذخیره در {[path]s} ممکن نشد: {[err]t}";
pub const note_band_edges = "لبه پایین باند باید زیر لبه بالای آن بماند";
pub const note_not_applied = "اعمال نشد: {[err]t}";
pub const note_view_saved = "نما در {[path]s} ذخیره شد";
pub const note_cannot_save = "ذخیره {[path]s} ممکن نشد: {[err]t}";
pub const note_stop_recording_first = "اول ثبت را متوقف کنید: این تغییر، شکل داده\u{200C}ها را عوض می\u{200C}کند";
pub const note_board_refused = "برد تنظیمات جدید را نپذیرفت: {[err]t}";

// ---- The notice over the display at start (where the colours came from) ----

pub const notice_colours_from = "رنگ\u{200C}ها از {[name]s} گرفته شده\u{200C}اند";
pub const notice_colours_change = "برای تغییر آن\u{200C}ها، scheme_image را در {[where]s} ویرایش کنید (برای رنگ\u{200C}های داخلی حذفش کنید)";
pub const notice_colours_failed = "{[reason]s}؛ رنگ\u{200C}های داخلی به کار می\u{200C}روند";
pub const notice_colours_where = "scheme_image در {[where]s} است";
// notice_language_missing and notice_language_where are always in English (the fallback).
