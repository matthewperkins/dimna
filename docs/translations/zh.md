# Chinese, Simplified (`src/gui/lang/zh.zig`): notes for a reviewer

dimna is acquisition and display software for extracellular electrophysiology (single units,
an Open Ephys acquisition board). The reader is at the rig, often in a dark room, glancing at
the screen while handling an animal: texts should be short and plain, in the words a Chinese
lab uses. English shows alarms in capitals; in Chinese they are simply short.

Conventions used: full-width punctuation in Chinese text (，：（）；。), half-width inside numbers
and units; a space between a Chinese character and a Latin word or number ("3 个间隙",
"spike 检测"), none between Chinese characters. Units stay as symbols (ms, s, min, Hz, µV, GB).

## Glossary

| English | Chinese | Why, when not obvious |
|---|---|---|
| threshold | 阈值 | |
| sweep (one trace of a triggered display) | 扫描 (N 次扫描) | as on an oscilloscope |
| sweep / scroll / triggered (display modes) | 扫描 / 滚动 / 触发 | |
| trigger | 触发 | |
| panel | 面板 | |
| row | 行 (第 5 行) | one channel's trace |
| band | 频带; the filter choice button: 带通 | |
| corner (a filter's) | 截止频率; stepper labels 下限 / 上限 | |
| filter | 滤波 | |
| raw | 原始 | |
| scale | 缩放 | |
| time base | 时基 | oscilloscope term |
| review (scrolling back through the recording) | 回看 | |
| live | 实时 | |
| note | 备注 | |
| preset (a ready-made note) | 预设 | |
| draft (a note written in advance) | 草稿 | |
| stamp (a note at the current sample) | 打上 | |
| acknowledge (an alarm) | 确认 | |
| recording / record | 记录 | the usual word in electrophysiology (not 录制) |
| gap | 间隙 | |
| block | 数据块 | |
| sample | 样本 | 采样点 is also common |
| board (the acquisition board) | 采集板 | |
| headstage | 前置放大器 | many labs just say "headstage" |
| spike | spike | the field's lab word; 锋电位 is the written term and could replace it throughout |
| spike tile | spike 图块 | |
| focus (a channel) | 选中 | |
| listen (audio monitor) | 监听 | |
| holdoff | 释抑 | Chinese oscilloscope term |
| level (trigger) | 电平 | |
| overlaid | 叠加 | |
| on / off | 开 / 关 | |
| display (the trace window) | 显示窗口 | |
| CAR (common average reference) | CAR; 参与平均 / 减去平均 | the two channel sets: those averaged, those the average is subtracted from |

## Messages I was unsure of

| name | English | Chinese | back-translation |
|---|---|---|---|
| `alarm_quiet_times_other` | THE BOARD WENT QUIET 3 TIMES (0.5 s or more without data) | 采集板中断 3 次（0.5 s 以上无数据） | the board was interrupted 3 times (0.5 s or more without data) |
| `alarm_disk_full_in` | THE DISK IS FULL IN about 12 min | 磁盘即将写满：剩余约 12 min | the disk will soon be full: about 12 min left |
| `alarm_recording_failed` | RECORDING FAILED: nothing is being recorded | 记录失败：什么都没有记录 | recording failed: nothing is recorded |
| `audio_noise_held` | noise 1.5 µV, held | 噪声 1.5 µV，已固定 | noise 1.5 µV, fixed |
| `btn_shaped` / `btn_plain` | shaped / plain (the audio chain) | 整形 / 原样 | shaped / as-is |
| `btn_16_of_32`, `board_summary_half` | 16 of 32 (channels of a 32-channel chip) | 32 选 16 | 16 chosen of 32 |
| `tiles_range_mixed` | mixed (the tiles' ranges differ) | 不一 | not uniform |
| `label_average_of` / `label_subtract_from` | average of / subtract from | 参与平均 / 减去平均 | take part in the average / subtract the average |
| `review_badge` | REVIEW   12.3 s behind live   at 1:05   l = live | 回看   落后实时 12.3 s   位于 1:05   l = 实时 | review, 12.3 s behind live, at 1:05 |
| `note_draft` | note at 1:05:  text_ | 备注 1:05：  text_ | note 1:05: text |
| `key_the_chips` | the chips | 端口按钮 | the port buttons |

## English that was ambiguous

- `mode_sweep` (the mode) and the counted "sweeps" (overlaid traces) are the same word in
  English; both are 扫描 here.
- `label_rows_shown` / `label_filtered` are the two lines of row chips (which rows are shown,
  which are filtered): 显示的行 / 滤波的行.
- `toggle_off` is also shown where a filter corner is not set; 关 reads acceptably there.
