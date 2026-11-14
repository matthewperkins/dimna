# Polish (`src/gui/lang/pl.zig`): notes for a reviewer

dimna is acquisition and display software for extracellular electrophysiology (single units,
an Open Ephys acquisition board). The reader is at the rig, often in a dark room, glancing at
the screen while handling an animal: texts should be short and plain, in the words a Polish
lab uses. Alarms are in capitals on purpose. Numbers come from the program with a decimal
point ("0.5 s"), so the texts use a point too, not a comma.

## Glossary

| English | Polish | Why, when not obvious |
|---|---|---|
| threshold | próg | |
| sweep (one trace of a triggered display) | przebieg (1 przebieg, 2 przebiegi, 5 przebiegów) | as on an oscilloscope |
| sweep (display mode) | przebieg | the mode where the trace sweeps over a fixed window; short, matches the counted word |
| scroll (display mode) | przesuw | short; "przewijanie" is the action of scrolling, used for the touchpad |
| triggered | wyzwalany | |
| trigger | wyzwalacz (label), wyzwalanie (the act) | |
| panel | panel | |
| row | wiersz | one channel's trace |
| band | pasmo | |
| corner (a filter's) | granica; dolna / górna | "częstotliwość graniczna" is too long for a stepper |
| filter | filtr | |
| raw | surowy | the unfiltered signal |
| scale | skala | |
| time base | podstawa czasu | oscilloscope term |
| review (scrolling back through the recording) | przegląd | |
| live | na żywo | |
| note | notatka | |
| preset (a ready-made note) | szablon | |
| draft (a note written in advance) | szkic | |
| stamp (a note at the current sample) | wstawić | "stemplować" sounded odd |
| acknowledge (an alarm) | potwierdzić | |
| recording / record | nagranie, nagrywanie / Nagrywaj | "rejestracja" is also used in labs; "nagranie" is shorter in buttons |
| gap | przerwa | |
| block | blok | |
| board (the acquisition board) | płytka (płytka akwizycyjna) | |
| headstage | przedwzmacniacz | the heading is "Przedwzmacniacze" (long); many labs just say "headstage" |
| spike | spike (spike'i, spike'ów, spike'ach) | the field's word; "potencjał czynnościowy" is too long |
| spike tile | kafelek (kafelki spike'ów) | |
| focus (a channel) | wybór, wybrany kanał | |
| listen (audio monitor) | odsłuch | |
| holdoff | holdoff | as in Polish oscilloscope manuals |
| overlaid | nałożone | |
| on / off | wł. / wył. | the usual abbreviations on switches |
| display (the trace window) | ekran | short; "okno sygnałów" would be clearer but longer |
| CAR (common average reference) | CAR; "średnia z" / "odjęta od" | the two channel sets: those averaged, those the average is subtracted from |

## Messages I was unsure of

| name | English | Polish | back-translation |
|---|---|---|---|
| `review_badge` | REVIEW   12.3 s behind live   at 1:05 | PRZEGLĄD   12.3 s wstecz   czas 1:05 | REVIEW 12.3 s back, time 1:05 |
| `alarm_hint` | press Shift+a to acknowledge | Shift+a potwierdza alarm | Shift+a acknowledges the alarm (avoids addressing the user) |
| `alarm_quiet_times_one` | THE BOARD WENT QUIET ONCE | PŁYTKA UCICHŁA RAZ | the board fell silent once |
| `alarm_blocks_lost_*` | N BLOCKS LOST: the disk fell 30 s behind | UTRACONO N BLOKÓW: dysk został 30 s w tyle | N blocks were lost: the disk stayed 30 s behind |
| `audio_noise_held` | noise 1.5 µV, held | szum 1.5 µV, ustalony | noise 1.5 µV, fixed |
| `btn_shaped` / `btn_plain` | shaped / plain (the audio chain) | kształtowany / zwykły | shaped / ordinary |
| `rec_idle` | not recording | nie nagrywa | (it) is not recording |
| `note_stop_recording_first` | stop the recording first: this changes the shape of the data | wymaga zatrzymania nagrywania: to zmienia kształt danych | requires stopping the recording: this changes the shape of the data |
| `warn_acquisition_stopped` | ...; restart dimna | ...; potrzebny restart dimna | ...; a restart of dimna is needed |
| `help_*` (key summary) | imperatives ("listen to it alone") | verbal nouns ("odsłuch tylko tego", "wstawienie szablonu") | the usual style of Polish key lists; `key_drag_*` uses an infinitive ("przeciągnąć czerwoną linię") |
| `key_left_right` | Left / Right | Lewo / Prawo | arrow keys; "← / →" would be clearer if the font has the arrows |
| `label_dsp_highpass` | DSP high-pass | górnoprzepustowy DSP | could be shortened to "DSP HP" if it does not fit |

## English that was ambiguous

- `mode_sweep` / `title_sweep` (the mode) and the counted "sweeps" (overlaid traces) are the
  same word in English; in Polish both are "przebieg", which reads naturally in each place.
- `label_rows_shown` / `label_filtered` are the two lines of row chips (which rows are shown,
  which are filtered); I wrote "widoczne" / "filtrowane" (shown / filtered), the noun implied.
- `label_subtract_from`: read as "the channels the average is subtracted from", hence the
  participle "odjęta od" agreeing with "średnia z" above it.
- `toggle_off` is also shown where a filter corner is not set; "wył." works for both.
