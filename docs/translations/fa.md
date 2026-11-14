# Persian (fa): notes for a native reviewer

The texts are in `src/gui/lang/fa.zig`, beside the English in `src/gui/lang/en.zig` (same
names, same order). The reader is an electrophysiologist at the rig, often in a dark room,
glancing at the screen while handling an animal: short, plain words, the ones an Iranian
lab uses. Persian ی and ک, Latin digits (the numbers come from the program), and the
zero-width non-joiner written `\u{200C}` in the source. Units, channel names and acronyms
(µV, ms, Hz, TTL, CAR, DSP, ADC, REC) stay in Latin letters.

## Glossary

| English | Persian | Why, when not the obvious word |
|---|---|---|
| spike | اسپایک | the lab word; "پتانسیل عمل" is too long and means one action potential, not a detected event |
| spike tile | کاشی اسپایک | "tile" as in the tiles of a UI (کاشی) |
| threshold | آستانه | also the row tag for "thr", unabbreviated: Persian has no usual short form |
| sweep | سوییپ | transliterated, as in the lab; the display mode and the triggered traces |
| scroll (display mode) | اسکرول | transliterated, as in most Persian software |
| triggered | با تریگر | "with a trigger" |
| trigger | تریگر | transliterated |
| slope trigger | تریگر شیب | |
| rising / falling | صعودی / نزولی | |
| panel | پنل | |
| row | ردیف | a channel's row on the display |
| band | باند | the band-pass |
| corner (of a filter) | فرکانس قطع | "cutoff frequency": the term Persian textbooks use for a corner; also used for "cutoff" |
| low / high (corner) | پایین / بالا | |
| filter | فیلتر | |
| raw | خام | |
| scale | مقیاس | "Y scale" is مقیاس Y |
| time base | پایه زمانی | |
| review | بازبینی | looking back through the recording |
| live | زنده | the opposite of review |
| freeze | ثابت کردن | |
| note | یادداشت | |
| draft (note) | پیش‌نویس | |
| preset (note) | پیش‌تنظیم | the usual software word for a preset |
| stamp (a note) | درج | "insert": a stamp puts the note at the present sample |
| acknowledge (an alarm) | تأیید | "confirm"; the usual word on alarm buttons |
| alarm / warning | هشدار | |
| recording, to record | ثبت | the electrophysiology word (ثبت تک‌واحدی); ضبط is for audio and video |
| recorder | ثبت‌کننده | |
| acquisition | دریافت داده | "receiving data", kept apart from ثبت (recording) |
| gap (in a recording) | شکاف | |
| gap (in the sound) | وقفه | a dropout in the audio reads better as an interruption |
| block | بلوک | |
| sample | نمونه | |
| headstage | هداستیج | transliterated, as in the lab |
| board | برد | |
| port | پورت | |
| focus | فوکوس | transliterated, as in Persian software |
| listen to | گوش دادن به | |
| mute | بی‌صدا | |
| noise | نویز | |
| holdoff | مکث | "pause" after a trigger; no settled Persian term |
| overlaid | روی هم | |
| wheel (mouse) | چرخ | |
| Ctrl, Shift, Alt, Esc, Home, End, PgUp, PgDn, Space, Enter | as on the key | Iranian keyboards carry the Latin labels |

## Messages I was unsure of

| Name | English | Persian | Back-translation |
|---|---|---|---|
| `btn_shaped` | shaped | پردازش‌شده | processed (the audio chain with its expander and limiter) |
| `btn_plain` | plain | ساده | simple (the linear reference) |
| `label_holdoff` | holdoff | مکث | pause |
| `key_touchpad_pinch` | touchpad pinch | پینچ روی تاچ‌پد | pinch on the touchpad (transliterated) |
| `key_left_right` | Left / Right | چپ / راست | left / right (the arrow keys) |
| `key_the_chips` | the chips | دکمه‌ها | the buttons (chip has no Persian UI word) |
| `review_badge` | REVIEW 2.0 s behind live at 1:05 … l = live | بازبینی 2.0 s عقب‌تر از زنده در 1:05 … l = زنده | review, 2.0 s further back than live, at 1:05 … l = live |
| `help_panel_as_configured` | the panel as configured | پنل طبق تنظیمات | the panel according to the settings |
| `hint_below_zero` | below zero, where it follows the noise | زیر صفر: تابع نویز | below zero: a function of the noise |
| `audio_noise_held` | noise 3.2 µV, held | نویز 3.2 µV، ثابت | noise 3.2 µV, fixed |
| `audio_summary_nothing` | … listening to nothing | … بدون کانال | … no channel |
| `alarm_no_data` | NO DATA FROM THE BOARD FOR 2.0 s | بدون داده از برد به مدت 2.0 s | no data from the board for 2.0 s |
| `btn_apply` | Apply (restarts acquisition) | اعمال (دریافت از نو شروع می‌شود) | apply (acquisition starts again) |
| `btn_record` | Record | شروع ثبت | start recording (ثبت alone reads as "submit") |
| `rec_idle` | not recording | ثبت نمی‌شود | nothing is being recorded |
| `status_ring_overflow` | ACQUISITION RING OVERFLOW 3 | سرریز بافر دریافت 3 | overflow of the acquisition buffer 3 |
| `tag_threshold` | thr | آستانه | threshold (no abbreviation) |

## How I read the English

- Persian has no capitals: the alarms are written as plain short sentences.
- Persian nouns stay singular after a number, so the `_one` and `_other` forms are mostly
  the same text. Persian counts 0 as `_one` (the program's rule), so every `_one` form keeps
  the number, except `alarm_quiet_times_one` ("once"), which is only shown for 1.
- "> 300 Hz" and "< 6000 Hz" in panel titles became words (بالای / زیر, "above" / "below"):
  the signs would be mirrored in right-to-left text and read the wrong way round.
- "/row" after a scale is kept as "/ردیف" (µV/ردیف), short like the English.
- "stamp" a note: put the note at the present moment; read as "insert" (درج).
- "the panel as configured" (middle-click): back to the panel's configured view.
