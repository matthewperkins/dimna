# Portuguese, Brazilian (pt): notes for the reviewer

dimna shows its texts from `src/gui/lang/pt.zig` (English: `en.zig`). The program is read
at the rig, in a dark room, with an animal in hand: texts are short, alarms are in capitals.
Written by a model, not yet read by a native speaker. Brazilian Portuguese counts 0 as
singular ("0 lacuna"), as the program's plural rule does.

## Glossary

| English | Portuguese | Why / note |
|---|---|---|
| on / off | on / off | short, common in lab software; "ligado / desligado" is long for buttons |
| raw | bruto | |
| band (filter) | banda | |
| corner (low / high) | corte (baixo / alto); "baixa / alta" for the label | |
| threshold | limiar | row tag is "lim" |
| sweep | sweep | the field's word |
| triggered / trigger | disparado / gatilho | |
| scroll (display mode) | rolagem | |
| panel | painel | window of traces |
| row | linha | one channel's trace |
| scale | escala | |
| rising / falling | subida / descida | the edge direction |
| review | revisão | scroll-back through the recording |
| live | ao vivo | |
| view | vista | |
| note / draft / preset | nota / rascunho / preset | |
| stamp (a note) | carimbar | puts the current sample number on a note |
| acknowledge (an alarm) | confirmar | |
| recording / record | gravação / gravar | |
| gap | lacuna | |
| block | bloco | |
| sample | amostra | |
| headstage | headstage | |
| spike tile | tile de spikes | loan word, to avoid confusion with "bloco" (block) |
| focus / listen | foco / ouvir | |
| board | placa | the acquisition board |
| disk | disco | |
| held (noise) | mantido | the noise level is measured once and kept |
| shaped / plain (audio) | modelado / linear | |
| chips | chips | the small toggle buttons |

Numbers are formatted by the program with a decimal point, so the fixed "0.5 s" in the
alarm text also uses a point (not "0,5").

## Messages I was unsure of

| name | English | Portuguese | back-translation |
|---|---|---|---|
| `toggle_on/off` | on / off | on / off | on / off |
| `btn_shaped` | shaped | modelado | shaped |
| `alarm_quiet_times_one` | THE BOARD WENT QUIET ONCE | A PLACA FICOU MUDA UMA VEZ | THE BOARD WENT MUTE ONCE |
| `review_badge` | s behind live | s atrás do ao vivo | s behind the live |
| `help_sound_add_take` | add to / take from the sound | somar ao / tirar do som | add to / take from the sound |
| `help_low_corner` | low corner down / up | corte baixo para baixo / cima | low cutoff down / up |
| `tip_band_line2` | slope trigger | gatilho por inclinação | trigger by slope |
| `status_ring_overflow` | ACQUISITION RING OVERFLOW | ESTOURO DO ANEL DE AQUISIÇÃO | overflow of the acquisition ring |
| `btn_reset` | reset | zerar | zero / reset |
| `label_view`, `btn_save_view` | view | vista | view |

## Ambiguities in the English

- "the disk fell 30 s behind" read as the writer being 30 s behind the acquisition.
- "corner" read as filter cutoff.
- "plain" (audio) read as the linear reference mode.
- "stamp" read as attaching the current sample position to a note.
- Keys keep their usual Brazilian labels (Shift, Ctrl, Esc, Home/End, PgUp/PgDn, Espaço).
