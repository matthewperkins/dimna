//! Every text the user sees, in Chinese (Simplified). The same names as `en.zig`; a message missing here
//! is shown in English. Conventions for translators: `docs/plans/translations.md`.
//! Notes for a reviewer: `docs/translations/zh.md`. Counted messages have only `_other`:
//! Chinese does not change a word for its number.

// ---- Words shared by several windows ----

/// A switch that is on (buttons, summaries).
pub const toggle_on = "开";
/// A switch that is off, or a corner that is not set.
pub const toggle_off = "关";
/// Common average reference (a button, a heading, a badge).
pub const label_car = "CAR";
/// Beside a row of a filtered panel that is drawn unfiltered.
pub const tag_raw = "原始";
/// The control window's filter choice: no filter (beside "band").
pub const btn_raw = "原始";
pub const btn_all = "全部";
pub const btn_none = "无";
pub const slope_rising = "上升";
pub const slope_falling = "下降";
/// The display modes of a panel (buttons, and the first word of its summary).
pub const mode_scroll = "滚动";
pub const mode_sweep = "扫描";
pub const mode_triggered = "触发";
/// "6 presets" / "1 preset" (the control window's notes summary).
pub const presets_other = "{[count]d} 个预设";
/// A filter's corners (the panel's band, the amplifier's band), beside their steppers.
pub const label_low = "下限";
pub const label_high = "上限";

// ---- The neural display: panel titles ----

/// After a title's band, when the common average reference is on.
pub const title_car = "   CAR";
/// A panel's filter in its title: both corners, only the low one, only the high one, none.
pub const title_band_range = "   {[low]d}-{[high]d} Hz{[car]s}";
pub const title_band_above = "   > {[low]d} Hz{[car]s}";
pub const title_band_below = "   < {[high]d} Hz{[car]s}";
pub const title_band_none = "   滤波：无截止频率{[car]s}";
/// A triggered panel's title says "raw" where a band would be.
pub const title_raw = "   原始";
pub const title_raw_car = "   原始   CAR";
/// The scale of a panel's rows in its title and in the control window's summary.
pub const title_per_row = "   {[scale]s}/行";
/// "5 sweeps" after a triggered panel's title.
pub const title_sweeps_other = "   {[count]d} 次扫描{[waiting]s}";
pub const title_waiting_for_trigger = " （等待触发）";
pub const title_review = "   回看";
pub const title_sweep = "   扫描";
/// What triggers a panel's sweeps, from a row of the display: "row 5 falling 4.5 σ" (before
/// the threshold is known) and "row 5 falling -62 µV".
pub const trigger_row_sigmas = "第 {[row]d} 行 {[slope]s} {[sigmas]d} σ";
pub const trigger_row_level = "第 {[row]d} 行 {[slope]s} {[uv]d:.0} µV";
/// Tip over a triggered panel's filter text when it is not the detector's band.
pub const tip_band_header = "这些扫描经过本面板的滤波：{[band]s}。";
pub const tip_band_none = "无（原始）";
pub const tip_band_line2 = "spike 检测和斜率触发始终使用 300-6000 Hz，";
pub const tip_band_line3 = "因此扫描可能与 spike 图块中的波形不同。";

// ---- The neural display: rows, banners, status ----

/// A row drawn with a threshold the row's band does not show.
pub const tag_threshold = "阈值";
/// In review with nothing to draw yet, where the traces would be.
pub const waiting_overview = "正在生成这一段的概览";
pub const waiting_reading = "正在读取记录";
/// The alarm bar's second line.
pub const alarm_hint = "按 Shift+a 确认";
/// The review badge, top centre; `state` is one of the two messages after it, or empty.
pub const review_badge = "回看   落后实时 {[behind]d:.1} s   位于 {[clock]s}{[state]s}   l = 实时";
pub const review_reading = "   （读取中）";
pub const review_building = "   （生成概览中）";
/// The note being typed, bottom left.
pub const note_draft = "备注 {[clock]s}：  {[text]s}_";
/// Bottom right, when the display missed blocks.
pub const readout_skipped_other = "{[ms]d:.1} ms   {[fps]d} fps   显示跳过 {[blocks]d} 个数据块";
/// The recording's clock beside it.
pub const readout_rec = "REC {[clock]s}";

// ---- The key summary (?) ----
// A text that is ASCII is drawn in the fixed-width font, any other in the ordinary one.

pub const help_title = "按键与鼠标   （? 或 Esc 关闭）";
pub const help_heading_display = "显示窗口中";
pub const help_heading_tiles = "spike 图块窗口中";

pub const key_wheel = "滚轮";
pub const key_ctrl_wheel = "Ctrl+滚轮";
pub const key_shift_wheel = "Shift+滚轮";
pub const key_ctrl_shift_wheel = "Ctrl+Shift+滚轮";
pub const key_sideways_scroll = "横向滚动";
pub const key_alt_wheel = "Alt+滚轮";
pub const key_touchpad_pinch = "触控板双指缩放";
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
pub const key_left_click_row = "左键点击某行";
pub const key_right_click_row = "右键点击某行";
pub const key_ctrl_right_click = "Ctrl+右键点击";
pub const key_middle_click = "中键点击";
pub const key_drag_red_line = "拖动红线";
pub const key_n = "n";
pub const key_space = "空格";
pub const key_left_right = "左 / 右方向键";
pub const key_pgup_pgdn = "PgUp / PgDn";
pub const key_home_end = "Home / End";
pub const key_l = "l";
pub const key_slash = "/";
pub const key_backtick = "`";
pub const key_1_9 = "1-9";
pub const key_tilde = "~";
pub const key_shift_a = "Shift+a";
pub const key_question = "?";
pub const key_ctrl_q_or_esc = "Ctrl+Q 或 Esc";
pub const key_a = "a";
pub const key_u = "u";
pub const key_shift_u = "Shift+u";
pub const key_left_click = "左键点击";
pub const key_right_click = "右键点击";
pub const key_drag_the_red_line = "拖动红线";
pub const key_the_chips = "端口按钮";

pub const help_y_scale_uv = "Y 轴缩放（每行 µV）";
pub const help_y_scale_row = "仅缩放该行的 Y 轴";
pub const help_back_forward_review = "时间后退 / 前进（回看）";
pub const help_same_as_shift_wheel = "同 Shift+滚轮";
pub const help_time_base_window = "时基（触发模式：窗口）";
pub const help_time_base = "时基";
pub const help_y_scale = "Y 轴缩放";
pub const help_panel_as_configured = "面板恢复为配置";
pub const help_scrolling_sweep = "滚动 <-> 扫描";
pub const help_filter_toggle = "显示滤波 开 / 关";
pub const help_low_corner = "下限截止频率 降 / 升";
pub const help_high_corner = "上限截止频率 降 / 升";
pub const help_triggered_toggle = "触发扫描 开 / 关";
pub const help_triggered_line = "TTL 触发：选择线路";
pub const help_triggered_source = "触发源：TTL <-> spike（本行）";
pub const help_focus_trigger = "选中（spike：在此触发）";
pub const help_listen_alone = "单独监听";
pub const help_sound_add_take = "加入 / 移出监听";
pub const help_no_focus = "取消选中通道";
pub const help_threshold_fixed_uv = "其阈值，固定（µV）";
pub const help_threshold_fixed_noise = "阈值：固定 <-> 跟随噪声";
pub const help_freeze = "冻结 / 回到实时";
pub const help_back_forward_tenth = "后退 / 前进 1/10 窗口";
pub const help_back_forward_window = "后退 / 前进一个窗口";
pub const help_start_live = "记录开头 / 实时";
pub const help_back_to_live = "回到实时";
pub const help_type_note = "输入备注（Enter 保存）";
pub const help_stamp_draft = "打上第一条草稿备注";
pub const help_stamp_preset = "打上一条预设备注";
pub const help_adc_toggle = "隐藏 / 显示 ADC 面板";
pub const help_acknowledge = "确认警报";
pub const help_these_keys = "本按键说明（? 或 Esc 关闭）";
pub const help_quit = "退出";
pub const help_tiles_scale_shown = "缩放显示的图块";
pub const help_tiles_scale_one = "仅缩放该图块";
pub const help_tiles_threshold = "该图块的阈值";
pub const help_tiles_common_range = "显示的图块：共同范围";
pub const help_tiles_own_range = "显示的图块：各自范围，固定";
pub const help_undo_scale = "撤销缩放更改";
pub const help_redo_scale = "重做缩放更改";
pub const help_focus_channel = "选中该通道";
pub const help_tiles_chips = "单个端口的图块，或全部";

// ---- The spike-tile window ----

/// The chip that shows the tiles of every port.
pub const tiles_all = "全部";
/// The range of the tiles shown, beside the chips: each tile on its own, or differing.
pub const tiles_range_auto = "自动";
pub const tiles_range_mixed = "不一";

// ---- The control window: the title, status and recording ----

pub const btn_acknowledge = "确认";
pub const quit_heading = "自上次保存以来更改的设置：";
pub const quit_recording_heading = "正在记录。退出会停止记录；已记录的内容会保留。";
pub const btn_stop_recording_and_quit = "停止记录并退出";
pub const btn_keep_recording = "继续记录";
pub const notice_quit_recording = "正在记录";
pub const notice_quit_recording_how = "在此提示显示期间再按 Ctrl+Q 将停止记录并退出";
pub const quit_panel_views = "面板视图（保存到 views.toml）";
pub const btn_save_and_quit = "保存为默认并退出";
pub const btn_quit_without_saving = "不保存并退出";
pub const btn_cancel = "取消";
pub const status_display = "显示 {[ms]d:.1} ms   {[fps]d} fps   已运行 {[seconds]d:.0} s";
pub const status_starting = "正在启动";
pub const status_display_skipped_other = "显示跳过 {[blocks]d} 个数据块";
pub const status_ring_overflow = "采集缓冲区溢出 {[count]d}";
pub const btn_save_view = "保存视图";
pub const btn_quit = "退出";
pub const btn_record = "记录";
pub const btn_stop_recording = "停止记录";
pub const rec_finishing = "正在完成记录";
pub const rec_status = "REC {[clock]s}   {[gb]d:.2} GB   {[msamples]d:.1} M 样本";
pub const rec_disk_behind = "磁盘落后 {[behind]d:.1} s";
pub const rec_gaps_other = "{[gaps]d} 个间隙";
pub const rec_failed = "记录失败";
pub const rec_idle = "未在记录";
pub const rec_disk_free = "磁盘：剩余 {[gb]d:.1} GB，按当前布局可录{[left]s}";
pub const rec_disk_too_full = "磁盘：剩余 {[gb]d:.1} GB，至少需要 {[need]d:.0} GB 才能记录";
/// The line about the source, at the top.
pub const about_source = "{[source]s}   {[rate]d} Hz   通道：{[channels]d}，电极：{[electrodes]d}";
pub const source_simulated = "模拟采集板";
pub const source_board = "Open Ephys 采集板";
/// The display window's title bar, refreshed once a second.
pub const window_title_status = "dimna   {[panel]s}：{[span]d:.2} s  {[scale]d:.1} {[unit]s}/行   延迟 {[ms]d:.1} ms   {[fps]d} fps";
/// The last line of the control window.
pub const hint_keys = "在显示窗口按 ?，可查看它和图块窗口的按键与鼠标操作。";

// ---- The control window: notes and audio ----

pub const section_notes = "备注";
pub const notes_summary_empty = "{[presets]s}   尚无备注";
pub const notes_summary_last = "{[presets]s}   最近备注 {[clock]s}  {[text]s}";
pub const notes_hint = "在显示窗口：/ 输入备注，Enter 保存";
pub const notes_typing = "正在输入备注";
pub const notes_drafts_other = "{[count]d} 条草稿（` 打上一条）";
pub const section_audio = "音频";
pub const btn_mute = "静音";
pub const label_volume = "音量";
pub const btn_shaped = "整形";
pub const btn_plain = "原样";
pub const btn_recalibrate = "重新校准";
pub const audio_no_output = "无音频输出";
pub const audio_listening = "监听 {[what]s}";
pub const audio_listening_nothing = "无（在显示窗口点击某行）";
pub const audio_noise_held = "噪声 {[sigma]d:.1} µV，已固定";
pub const audio_measuring = "正在测量噪声（3 s）";
pub const audio_gaps_other = "声音中有 {[count]d} 个间隙";
pub const audio_muted = "，已静音";
pub const audio_summary_off = "关{[muted]s}   {[db]d:.0} dB";
pub const audio_summary_nothing = "开{[muted]s}   {[db]d:.0} dB   未监听";
pub const audio_summary_on = "开{[muted]s}   {[db]d:.0} dB   监听 {[what]s}   {[ms]d:.0} ms";

// ---- The control window: spikes and headstages ----

pub const section_spikes = "Spike";
pub const label_threshold = "阈值";
pub const hint_below_zero = "低于零时跟随噪声";
pub const section_headstages = "前置放大器";
pub const board_restart_pending = "（待重启）";
pub const board_not_saved = "（未保存为默认）";
pub const board_summary_head = "{[rate]d} Hz   {[lower]s}–{[upper]s}   DSP ";
pub const board_summary_dsp_on = "开，{[cutoff]s}";
pub const board_summary_half = "   {[headstage]s} 32 选 16";
pub const board_these_change = "（这些会改变记录的内容）";
pub const label_amplifier_band = "放大器频带";
pub const label_dsp_highpass = "DSP 高通";
pub const label_cutoff = "截止频率";
pub const label_sample_rate = "采样率";
pub const btn_32_ch = "32 通道";
pub const btn_16_of_32 = "32 选 16";
pub const btn_apply = "应用（重启采集）";
pub const board_apply_after_stop = "停止记录后才能更改采样率和通道";
pub const btn_save_default = "保存为默认";
pub const board_differs = "这些设置与配置文件不同";

// ---- The control window: a panel's section ----

pub const btn_reset = "重置";
pub const summary_band_range = "   频带 {[low]d}–{[high]d} Hz";
pub const summary_band_below = "   频带低于 {[high]d} Hz";
pub const summary_band_above = "   频带高于 {[low]d} Hz";
pub const summary_band_none = "   频带（无截止频率）";
pub const summary_on_ttl = "   TTL {[line]d} 触发";
pub const summary_on_spikes = "   spike 触发，第 {[row]d} 行";
pub const label_view = "视图";
pub const label_window = "窗口";
pub const label_time = "时间";
pub const label_scale = "缩放";
pub const stepper_per_row = "{[scale]s}/行";
pub const label_filter = "滤波";
pub const btn_band = "带通";
pub const label_rows_shown = "显示的行";
pub const label_filtered = "滤波的行";
pub const label_average_of = "参与平均";
pub const label_subtract_from = "减去平均";
pub const label_trigger = "触发";
pub const btn_ttl = "TTL";
pub const btn_spikes = "spike";
pub const trigger_row_value = "第 {[row]d} 行";
pub const label_level = "电平";
pub const label_holdoff = "释抑";
pub const label_overlaid = "叠加";
pub const stepper_sweeps_other = "{[count]d} 次扫描";

// ---- Alarms across the display (until acknowledged) ----

pub const alarm_acquisition_stopped = "采集已停止（{[err]t}）：未在读取采集板";
pub const alarm_no_data = "采集板已 {[seconds]d:.1} s 无数据";
pub const alarm_quiet_times_other = "采集板中断 {[times]d} 次（0.5 s 以上无数据）";
pub const alarm_recording_failed = "记录失败：什么都没有记录";
pub const alarm_blocks_lost_other = "丢失 {[blocks]d} 个数据块：磁盘落后了 30 s";
pub const alarm_dropped_other = "采集板丢失 {[samples]d} 个样本";
pub const alarm_gaps_other = "记录有 {[gaps]d} 个间隙";
pub const alarm_disk_full_in = "磁盘即将写满：剩余{[left]s}";

// ---- Warnings across the display (while their cause lasts) ----

pub const warn_acquisition_stopped = "采集已停止（{[err]t}）：未读取任何数据；请重启 dimna";
pub const warn_disk_behind = "磁盘落后 {[behind]d:.0} s（落后 30 s 时会丢失样本）";
pub const warn_disk_full_in = "磁盘即将写满：剩余{[left]s}（还剩 {[gb]d:.1} GB）";
/// "about 12 min", "about 40 s": the time left, in the disk messages.
pub const about_minutes = "约 {[count]d:.0} min";
pub const about_seconds = "约 {[count]d:.0} s";
pub const about_hours = "约 {[hours]d} h {[minutes]d} min";

// ---- Notes under the control window's board and recording lines ----

pub const note_cannot_create = "无法在 {[dir]s} 下创建记录：{[err]t}";
pub const note_cannot_start = "无法启动记录器：{[err]t}";
pub const note_disk_too_full = "未记录：{[dir]s} 下剩余 {[gb]d:.1} GB，至少需要 {[need]d:.0} GB";
pub const note_recording_failed = "记录失败：{[err]t}；之前写入的数据完好";
pub const note_last_recording = "上次记录：{[length]s}   样本：{[samples]d}   间隙：{[gaps]d}";
pub const note_saved_to = "已保存到 {[path]s}";
pub const note_cannot_save_to = "无法保存到 {[path]s}：{[err]t}";
pub const note_band_edges = "频带的下限必须低于上限";
pub const note_not_applied = "未应用：{[err]t}";
pub const note_view_saved = "视图已保存到 {[path]s}";
pub const note_cannot_save = "无法保存 {[path]s}：{[err]t}";
pub const note_stop_recording_first = "请先停止记录：这会改变数据的结构";
pub const note_board_refused = "采集板拒绝了新设置：{[err]t}";

// ---- The notice over the display at start (where the colours came from) ----

pub const notice_colours_from = "颜色取自 {[name]s}";
pub const notice_colours_change = "如需更改，请编辑 {[where]s} 中的 scheme_image（删除它则使用内置颜色）";
pub const notice_colours_failed = "{[reason]s}；使用内置颜色";
pub const notice_colours_where = "scheme_image 位于 {[where]s}";
