# German (de): notes for the reviewer

dimna shows its texts from `src/gui/lang/de.zig` (English: `en.zig`). The program is read
at the rig, in a dark room, with an animal in hand: texts are short, alarms are in capitals.
Written by a model, not yet read by a native speaker.

## Glossary

| English | German | Why / note |
|---|---|---|
| on / off | an / aus | |
| raw | roh | |
| band (filter) | Band | "Bandpass" is too long |
| corner (low / high) | Grenze (unten / oben); Grenzfrequenz for "cutoff" | "Eckfrequenz" felt stiff |
| threshold | Schwelle | row tag is "Schw" |
| sweep | Sweep | the field's word |
| triggered / trigger | getriggert / Trigger | |
| scroll (display mode) | Rollen | "Scrollen" is used only for the mouse action |
| panel | Panel | window of traces |
| row | Zeile | one channel's trace |
| scale | Skala | |
| review | Review | scroll-back through the recording; "Rückblick" is an option |
| live | live | |
| note / draft / preset | Notiz / Entwurf / Preset | |
| stamp (a note) | stempeln | puts the current sample number on a note |
| acknowledge (an alarm) | quittieren | |
| recording / record | Aufnahme / Aufnehmen | |
| gap | Lücke | |
| block | Block | |
| sample | Sample | |
| headstage | Headstage | |
| spike tile | Spike-Kachel | |
| focus / listen | Fokus / Abhören | "Abhören" for the audio monitor |
| board | Board | the acquisition board |
| disk | Platte | colloquial; "Festplatte" is longer |
| held (noise) | gehalten | the noise level is measured once and kept |
| shaped / plain (audio) | geformt / linear | "plain" is a linear, unprocessed reference |
| chips | Chips | the small toggle buttons |

Numbers are formatted by the program with a decimal point, so the fixed "0.5 s" in the
alarm text also uses a point (not "0,5").

## Messages I was unsure of

| name | English | German | back-translation |
|---|---|---|---|
| `btn_shaped` | shaped | geformt | shaped |
| `label_level` | level | Level | level (of a trigger) |
| `alarm_quiet_times_one/other` | THE BOARD WENT QUIET ONCE | DAS BOARD WAR EINMAL STUMM | THE BOARD WAS SILENT ONCE |
| `help_sound_add_take` | add to / take from the sound | zum Ton hinzufügen / entfernen | add to / remove from the sound |
| `help_stamp_draft` | stamp the first draft note | ersten Entwurf stempeln | stamp the first draft |
| `audio_summary_nothing` | on ... listening to nothing | an ... hört nichts ab | on ... monitors nothing |
| `board_summary_dsp_on` etc. | on, {cutoff} | an, {cutoff} | on, ... |
| `status_ring_overflow` | ACQUISITION RING OVERFLOW | ÜBERLAUF DES AKQUISITIONSRINGS | overflow of the acquisition ring |
| `tag_threshold` | thr | Schw | thr |
| `key_the_chips` | the chips | die Chips | the chips |
| `btn_reset` | reset | zurücksetzen | reset (long: 12 chars vs 5) |

## Ambiguities in the English

- "the disk" is the recording disk; "the disk fell 30 s behind" read as the writer being
  30 s behind the acquisition.
- "corner" read as filter corner frequency; "low corner down / up" as lowering / raising it.
- "plain" (audio) read as the linear reference mode, not "simple".
- "stamp" read as attaching the current sample position to a note.
- `help_scrolling_sweep` "scrolling <-> sweep" read as the two display modes.
- "Keys" use German labels: Strg, Umschalt, Pos1, Ende, Bild↑/Bild↓, Leertaste.
