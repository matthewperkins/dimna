# French (fr): notes for the reviewer

dimna shows its texts from `src/gui/lang/fr.zig` (English: `en.zig`). The program is read
at the rig, in a dark room, with an animal in hand: texts are short, alarms are in capitals.
Written by a model, not yet read by a native speaker. French counts 0 as singular
("0 trou"), as the program's plural rule does.

## Glossary

| English | French | Why / note |
|---|---|---|
| on / off | on / off | what French lab software shows; "activé / désactivé" is too long for buttons |
| raw | brut | |
| band (filter) | bande | |
| corner (low / high) | coupure (basse / haute) | |
| threshold | seuil | |
| sweep | sweep | the field's word |
| triggered / trigger | déclenché / déclencheur | |
| scroll (display mode) | défilement | |
| panel | panneau | window of traces |
| row | ligne | one channel's trace |
| scale | échelle | |
| rising / falling | montant / descendant | read as the edge ("front"), not the slope |
| review | revue | scroll-back through the recording |
| live | direct | |
| note / draft / preset | note / brouillon / préréglage | |
| stamp (a note) | estampiller | puts the current sample number on a note |
| acknowledge (an alarm) | acquitter | |
| recording / record | enregistrement / enregistrer | |
| save | sauvegarder | to keep "enregistrer" for recording only |
| gap | trou | "lacune" is an option |
| block | bloc | |
| sample | échantillon | |
| headstage | headstage | |
| spike tile | tuile de spikes | |
| focus / listen | focus / écouter | |
| board | carte | the acquisition board |
| disk | disque | |
| held (noise) | mémorisé | the noise level is measured once and kept |
| shaped / plain (audio) | modelé / linéaire | |
| chips | pastilles | the small toggle buttons |

Numbers are formatted by the program with a decimal point, so the fixed "0.5 s" in the
alarm text also uses a point (not "0,5"). Spaces before ":" are ordinary spaces.

## Messages I was unsure of

| name | English | French | back-translation |
|---|---|---|---|
| `toggle_on/off` | on / off | on / off | on / off |
| `btn_shaped` | shaped | modelé | shaped |
| `alarm_quiet_times_one` | THE BOARD WENT QUIET ONCE | LA CARTE S'EST TUE UNE FOIS | THE BOARD WENT SILENT ONCE |
| `alarm_blocks_lost_one` | BLOCK LOST: the disk fell 30 s behind | BLOC PERDU : le disque a pris 30 s de retard | |
| `help_sound_add_take` | add to / take from the sound | ajouter au son / retirer du son | same |
| `help_low_corner` | low corner down / up | coupure basse : baisser / monter | low cutoff: lower / raise |
| `label_trigger` | trigger | déclencheur | trigger |
| `status_ring_overflow` | ACQUISITION RING OVERFLOW | DÉBORDEMENT DU TAMPON D'ACQUISITION | acquisition buffer overflow |
| `label_sample_rate` | sample rate | fréq. d'échantillonnage | sampling freq. |
| `btn_reset` | reset | réinit. | reset |

## Ambiguities in the English

- "the disk fell 30 s behind" read as the writer being 30 s behind the acquisition.
- "corner" read as filter cutoff.
- "plain" (audio) read as the linear reference mode.
- "stamp" read as attaching the current sample position to a note.
- "Keys" use French labels: Maj, Échap, Espace, Début, Fin, Page↑/Page↓.
