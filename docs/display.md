# The neural display

[Back to the README](../README.md)

    dimna --sim 32,16                             # simulated signals in a window
    dimna --16ch A1 --adc                         # the board (config file decides the rest)

Wayland directly (zig-wayland) and Vulkan (vulkan-zig); traces are drawn on the GPU from a
ring of sample history that only new samples are written to. The display reads the
acquisition ring with a lossy reader, so it can never hold acquisition back.

Config: `~/.config/dimna/config.toml` (command-line options win).

```toml
monitor = "DP-2"      # fullscreen on this monitor: the neural display
tearing = true        # show each frame at once (see below)
font = "sans-serif"   # optional: a fontconfig name
font_px = 14          # optional: text size in pixels

[[panel]]
name = "Port B"
source = "B1"                 # a headstage, "electrodes", "aux" or "adc"
rect = [0.0, 0.0, 0.5, 0.75]  # x, y, width, height as fractions of the display
span_s = 2.0                  # optional
scale = 400                   # optional: µV per row (V per row for aux and adc)
mode = "scroll"               # optional: "scroll" (default), "sweep" or "triggered"
trigger = 2                   # triggered mode: TTL input line; pre_ms = 10, post_ms = 40,
                              # sweeps = 10 (how many are overlaid) are optional too
band = [300, 6000]            # optional: show band-passed (Hz; 0 leaves a side out)

[[panel]]
source = "A1"
rect = [0.5, 0.0, 0.5, 0.75]

[[panel]]
source = "adc"                # needs --adc
rect = [0.0, 0.75, 1.0, 0.25]
```

Without `[[panel]]` tables there is one panel per headstage, side by side. Wheel (Y scale),
Alt+wheel or pinch (time base) and the keys `- = [ ] r` act on the panel under the pointer,
marked by a bar along its top; `q` quits. **`?` shows every key and mouse action** of the
display and of the tile window in a panel over the display (Esc or `?` closes it);
`dimna --help` prints the display's.
Ctrl+wheel scales only the row under the pointer; that row's label then shows its own
scale in amber. The plain wheel still moves every row, keeping such a row's ratio, and `r`
clears it. (Per-row scales are not saved in the config.)

## Off scale and saturated

A trace may reach 1.5 rows from its row's centre. Where it
is wholly beyond that, a dashed amber line near the row's own upper or lower edge shows
which way it has gone, instead of a flat line in a neighbour's row. Samples at the
converter's limits (a saturated amplifier or ADC, whatever the display's scale) are drawn
red.

Keys go by what they are labelled in your keyboard layout (so on Dvorak, `r` is the key
marked r), and reach dimna while its window has the keyboard focus (with Hyprland's
`follow_mouse = 1`, while the pointer is over it). `DIMNA_KEY_DEBUG=1` logs focus changes and
every key received.

## Triggered sweeps

A panel in triggered mode (`mode = "triggered"`, or `t` on the
panel under the pointer) shows the signal around each rising edge of a TTL input line:
10 ms before to 40 ms after by default, the last 10 sweeps overlaid with the newest
brightest. The newest sweep is drawn as it fills in. A line marks the trigger and a tint
marks while the trigger line was high (the laser, for opto-tagging). `1`-`8` pick the
line; `[` `]`, Alt+wheel and pinch zoom the window; the panel's display filter applies
as usual. Edges are found on the display thread from the digital words of each block
(`src/sweeps.zig`). Sweeps older than the GPU's sample history (about 30 s) are dropped, so
with slow triggers fewer are overlaid. After a filter corner change, only the recent past
is refiltered, so older overlaid sweeps keep the old corners until they are replaced.

## Slope trigger (spikes)

A triggered panel of electrodes can start its sweeps where one
of its own channels crosses a level, instead of at a TTL edge: `s` on the panel (with the
pointer over the row to listen to), the TTL / spikes buttons in the control window, or
`trigger_channel = 5` in the config. Clicking another row moves the trigger there.

- The channel is band-passed 300 Hz to 6 kHz for the detection, whatever the panel shows.
- The level and slope are the channel's threshold (above). When a panel starts triggering
  on a channel whose threshold follows the noise, the threshold is fixed where it is at
  that moment (as the tile window reports it, or without one after the trigger's first
  second of signal), once: `n` puts it back to following the noise, and the trigger then
  follows it too, until triggering is started on a channel anew. In the control
  window the level's − / + scales it by 15 % and falling / rising flips its sign. A dashed
  line shows it on the trigger's row, in that row's scale; it sits on the trace when the
  panel shows a band near 300-6000 Hz. (`level_uv`, `level_auto` and `slope` are no longer
  panel settings: a config or view file with them is read without them.)
- The sweep is aligned on the extreme within 0.5 ms after the crossing (the spike's
  trough or peak); 1 ms dead time plus an optional holdoff.
- The window is its own: -1 / +2 ms, kept apart from the TTL window (-10 / +40 ms).

After a very large spike the band-pass rings for a few ms and can trigger once more once
the dead time is over; a holdoff of a few ms stops that. Detection runs on the display
thread (`src/slope.zig`) and has nothing to do with what is recorded.

## Rows: filtered, as they are, or hidden

Within one panel each row can be shown
through the display filter or as it is, and rows can be left out: fast and slow signals
from one headstage side by side, without the dead channels.

```toml
[[panel]]
name = "Port B"
source = "B1"
rect = [0.0, 0.0, 0.5, 0.75]
band = [300, 6000]              # rows 1 to 8: skeletal muscle, filtered
raw_rows = [9, 10, 11, 12]      # smooth muscle: shown as acquired
raw_scale = 1000                # µV per row for those rows (the others: scale)
hide = [13, 14, 15, 16]         # not shown
```

In the control window each electrode panel has a row of numbered toggles "rows shown" and,
while its filter is on, "filtered". Rows shown as they are in a filtered panel are marked
"raw", with their own scale beside the label; Ctrl+wheel scales one row. Hidden rows are
still recorded, still take part in a common average reference if chosen for it, and keep
their numbers: row 9 stays row 9. Changing any of this redoes the panel's recent past.

## Common average reference (CAR)

Per electrode panel (so per port): the plain mean of
the rows you choose, sample by sample, is subtracted from the rows you choose. Turn it on
in the control window (CAR on, then the two rows of numbered buttons: "average of" and
"subtract from"; all / none), or in the config:

```toml
[[panel]]
source = "A1"
rect = [0.5, 0.0, 0.5, 0.75]
car_ref = [1, 2, 3, 5, 6, 7, 8]      # rows averaged (default: all); leave dead ones out
car_subtract = [1, 2, 3, 4, 5, 6, 7, 8]   # rows it is subtracted from (default: all)
```

The mean is uniform (sum divided by the number of reference rows) and is taken from the
samples as acquired, then subtracted before a channel's filter. For these filters that is
exactly the same as filtering all channels alike and then referencing, whichever band the
panel shows, because filtering and averaging are both linear; nothing has to be padded or
run ahead. A row that is in both sets loses 1/N of itself with the average, as in any CAR.

It applies to what the panel displays (raw or band), to a slope trigger on one of the
panel's subtract rows, and to the sound when a channel listened to is one of them (the
Audio section's CAR button turns that off; the noise is measured again when it changes).
Like the display filter, it never touches what is recorded. The panel's title says CAR.
Changing either set redoes the panel's recent past, so the whole window changes at once.

## TTL lanes and tint

A panel with `source = "ttl"` shows the digital input lines as
square-wave lanes, one row per line (`lines = [1, 2]` picks them; all 8 otherwise). It is
drawn from the same sample history as the traces, so it scrolls, sweeps and zooms with
them. Lines can be named in the config; the names label the lanes and are written to each
recording's `meta.toml` (`[ttl] line_names`):

```toml
[ttl]
line1 = "camera"
line2 = "laser"

[[panel]]
name = "TTL"
source = "ttl"
lines = [1, 2]
rect = [0.0, 0.9, 1.0, 0.1]
```

Any panel can also be shaded while one line is high: `tint = 2` in its `[[panel]]` table.
It is off unless asked for, and meant for a slow line such as the laser (a 60 Hz camera
trigger would stripe the whole panel). Up to 512 pulses are kept per panel.

## Display filter

Each electrode panel can show its channels band-passed: a 4th-order
Butterworth high-pass and low-pass with the panel's own corners (`band = [low, high]`; a 0
leaves that side out, so `[10, 0]` is a 10 Hz high-pass). `f` switches the panel under the
pointer between raw and filtered, `,` `.` step the low corner and `;` `'` the high corner;
the title shows the band. Two panels on the same headstage can have different bands. AUX
and ADC are always drawn as they are.

The filter is for the display only: recordings hold the samples as acquired. It runs on
the display's thread as blocks arrive (`src/feed.zig`, `src/dsp.zig`; about 4 % of a core
for 48 channels) and writes what each electrode panel shows of its channels beside the
acquired ones in the GPU's sample history. When the filter is switched or its corners
change, the panel's recent past (its window plus a second) is made again, so the whole
trace changes at once. Latency is unchanged (board,
tearing: 2.6 ms). The sample history is wider for it: 218 MB of GPU memory for 56 channels
with 48 filtered, and a 117 MB copy of the raw samples in RAM for refiltering.

## Sweep mode

By default traces scroll, with the newest sample at the right edge. In
sweep mode they stand still and a cursor moves left to right, overwriting the previous pass
(as oers and the stock LFP viewer draw). Set it per panel with `mode = "sweep"`, for all
panels with a top-level `mode = "sweep"` or `--sweep`, or flip the panel under the pointer
with `m`. It is the same drawing with a different choice of samples per column, so the
latency is the same. Kept simple: changing the time base restarts the pass from a new
origin.

The time base goes up to 30 s in both modes. A panel whose pixel columns hold 64 samples or
more (about 4 s across the full width of a 1920-pixel monitor) is drawn from a second,
decimated history: the minimum and maximum of every 16 samples (`src/decimate.zig`), so a
long time base costs the graphics card no more than a short one. Changing a display filter
at a long time base makes the whole stretch again; at a 30 s sweep (a minute of signal) the
picture stands still for most of a second while it does. Recording is not affected.

Each panel is titled with its name, time base and scale per row, and its rows are labelled
(the electrode's number on its headstage, AUXn, ADCn; thinned when rows are shorter than a
line of text). The bottom right corner shows the latency and frame rate of the last second,
and in amber how many blocks the display skipped, if any (the recording never depends on
the display). Text is drawn by dimna itself (`src/gui/font.zig`: FreeType into one atlas,
quads in the same render pass), since nothing else may be on the monitor while tearing; it
made no measurable difference to the latency (2.6 ms with and without, same session).

## Scroll-back review

Look at what went by without stopping anything: acquisition, the
recording and the sound carry on, and the live display's own history keeps filling, so
going back to live is instant.

| | |
|---|---|
| Shift+wheel, sideways scroll | back and forth in time, a tenth of the window per click; back from live enters review, forward to the live edge leaves it |
| Space | freeze where the display is (again: back to live) |
| Left / Right | back and forth by a tenth of the window |
| PgUp / PgDn | by a whole window |
| Home | the start of the recording |
| `l`, End | back to live |

While in review an amber badge
across the top says so, how far behind live the view is, and where in the run it is;
each panel's title says "review" too. Triggered panels stay live.

- **While recording**, review reads the recording's own `samples.i16` and TTL edge files
  back (`src/review.zig`), through a feed set up exactly as the live one, into a second
  history on the GPU (as large as the live one, made on first use). So the whole session
  is there, filtered, referenced and laid out as the live display would show it, with
  the TTL lanes and note markers. Only what a move newly exposes is read; a filter or
  row change redoes the stretch.
- **Without a recording** it is a freeze of the last half minute that the live history
  still holds; it ends by itself when that has scrolled away.

Limits for now: the window is as long as a live one (30 s at most; no overview of a whole
session yet); the newest second of TTL edges may not be in the file yet; the tint is not
drawn for stretches older than the last 512 pulses; after lost blocks (gaps in the
recording) later samples would be shown early by the length of the gap; no dragging with
the mouse yet.

## Notes

On the neural display, `/` opens a note stamped at that moment; type, and
Enter (or `\`) saves it, Esc drops it. While a note is open every key is its text, so no
shortcut fires (q does not quit). Tab keeps the text as a draft instead, and `` ` `` stamps
the oldest draft at the moment it is pressed: type what you are about to do, stamp it
when you do it. `1` to `9` stamp preset notes from the config, where there is one:

```toml
[notes]
preset1 = "lick"
preset2 = "laser on"
```

The stamp is the newest sample acquired plus the time since it was acquired (so the
display's latency is not in it; keys are read once per frame, so it can be a few ms
late). A saved note goes into the recording's `events.tsv` as kind `note`, if one is
running; into a log of every note, recorded or not
(`~/.local/state/dimna/notes.log`: local time, sample, session folder, text); and onto the
traces as a line with the text beside it. The control window shows the last three, the
presets as buttons, and how many drafts wait. Notes are limited to 200 bytes; the display
font covers Latin-1, so other characters are stored as typed but drawn as "?".

Digits that have a preset no longer pick a triggered panel's TTL line (the control
window's stepper does that).
