# oEZ

Acquisition for the Open Ephys acquisition board (ECP5 gateware, FT600 USB 3, ONI), in Zig.
Linux only. Successor to oers (Rust, `../oers`), whose driver it ports.

## Build

Zig 0.17.1 (pinned in `build.zig.zon`).

    zig build --release=safe     # zig-out/bin/oez-headless (safety checks stay on)
    zig build test               # unit tests

The display also needs the Wayland and Vulkan development files, `glslc`, and FreeType and
fontconfig (text).

liboni is vendored (`vendor/liboni`, MIT) and built in. Two patches are carried in
`onidriverloader.c`: a driver search directory (from oers) and a driver compiled into the
program (`oni_register_builtin_driver`).

## Two ways to reach the FT600

    oez-headless ...                  # --driver usb, the default: no FTDI code in the process
    oez-headless --driver d3xx ...    # fallback: liboni's ft600 driver on FTDI's closed D3XX

**`usb`** needs nothing installed beyond read/write access to the device node (the Open Ephys
udev rule). Three layers, all in this repo:

- `src/usbfs.zig`: USB through the kernel's usbdevfs, in Zig, without libusb. Bulk transfers
  are asynchronous URBs, so a read that times out still reports the bytes that arrived.
- `src/ft600.zig`: the FT600 wire protocol (documented at the top of the file). It was learned
  by logging the usbdevfs requests D3XX 1.0.14 makes for the ONI driver's calls on this board.
  Nothing is sent that D3XX does not send on every open, and the chip configuration is only
  ever read.
- `src/oni_usb.zig`: a port of liboni's `drivers/ft600/onidriver_ft600.c` onto that.

`OEZ_USB_TRACE=1` logs every command and control-channel transfer to stderr.

Measured on the rig against `d3xx` (46 channels, 30 kHz):

| | usb | d3xx |
|---|---|---|
| CPU for a 20 s recording run (user + sys) | 2.2 s | 8.7 s |
| open + port scan | about 2.5 s | about 8.6 s |
| delivery delay, avg / worst (8 KB USB blocks) | 0.76 / 2.45 ms | 0.73 / 4.58 ms |

Recordings made back to back agree: electrode noise profile r = 0.9999, AUX within 0.3 mV,
ADC within 0.03 mV. Two things make the difference:

- **Paced reads.** The chip ends a transfer whenever its FIFO runs empty, so reading as fast
  as possible (as D3XX does) fetches each block in dozens of one-sample pieces: about 12,400
  transfers a second, each with its announcement. liboni needs the whole block before it hands
  anything on, so after a read that emptied the FIFO the driver sleeps until the rest of the
  block should have been produced and fetches it in one transfer. `OEZ_USB_PACE=0` turns that
  off.
- **No idle waits.** D3XX waits 200 ms on every pipe abort; that is skipped when no transfer
  is announced (the chip then has nothing it may send).

`--usb-block BYTES` (`Settings.usb_block_bytes`) sets how much liboni fetches at a time.
Nothing reaches the pipeline before a block is complete, so it sets the delivery delay:

| usb block | delivery delay avg / worst | CPU per 10 s | transfers per s |
|---|---|---|---|
| 24576 | 2.05 / 4.21 ms | 0.40 s | 495 |
| 8192 (default) | 0.70 / 1.92 ms | 0.60 s | 1,498 |
| 4096 | 0.38 / 1.34 ms | 0.89 s | 3,531 |
| 2048 | 0.23 / 2.10 ms | 1.37 s | 8,263 |

(Delivery delay: how much later than the quickest block of the same second a block's newest
sample reached the ring; `oez-headless` prints it.) The FT600's stream mode was also tried and
is not used: see the notes at the top of `src/ft600.zig`.

**`d3xx`** needs `libonidriver_ft600.so`, built by `../oers/scripts/build-ft600-driver.sh`
(D3XX **1.0.x** only) into `~/.local/lib`. It is found via `$ONI_DRIVER_PATH`, next to the
executable, `../lib`, `~/.local/lib` or `/usr/local/lib`.

## Run

    oez-headless --seconds 600 --16ch A1 --aux --adc --record ~/oez-test

`--16ch A1` is needed on the rig (16-channel headstage on an RHD2132). Prints one status line
per second and `CLEAN` at the end if nothing was lost (exit status 0). Record to disk, not
`/tmp`.

The acquisition thread runs SCHED_FIFO (needs rtprio, e.g. the `realtime` group) and locks
memory. It never waits on readers: the recorder and other readers take blocks from a
preallocated ring (30 s when recording).

## The display (`oez`)

    oez --sim 32,16                               # simulated signals in a window
    oez --16ch A1 --adc                           # the board (config file decides the rest)

Wayland directly (zig-wayland) and Vulkan (vulkan-zig); traces are drawn on the GPU from a
ring of sample history that only new samples are written to. The display reads the
acquisition ring with a lossy reader, so it can never hold acquisition back.

Config: `~/.config/oez/config.toml` (command-line options win).

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
Shift+wheel or pinch (time base) and the keys `- = [ ] r` act on the panel under the pointer,
marked by a bar along its top; `q` quits.
Ctrl+wheel scales only the row under the pointer; that row's label then shows its own
scale in amber. The plain wheel still moves every row, keeping such a row's ratio, and `r`
clears it. (Per-row scales are not saved in the config.)

**Off scale and saturated.** A trace may reach 1.5 rows from its row's centre. Where it
is wholly beyond that, a dashed amber line near the row's own upper or lower edge shows
which way it has gone, instead of a flat line in a neighbour's row. Samples at the
converter's limits (a saturated amplifier or ADC, whatever the display's scale) are drawn
red.

Keys go by what they are labelled in your keyboard layout (so on Dvorak, `r` is the key
marked r), and reach oEZ while its window has the keyboard focus (with Hyprland's
`follow_mouse = 1`, while the pointer is over it). `OEZ_KEY_DEBUG=1` logs focus changes and
every key received.

**Triggered sweeps.** A panel in triggered mode (`mode = "triggered"`, or `t` on the
panel under the pointer) shows the signal around each rising edge of a TTL input line:
10 ms before to 40 ms after by default, the last 10 sweeps overlaid with the newest
brightest. The newest sweep is drawn as it fills in. A line marks the trigger and a tint
marks while the trigger line was high (the laser, for opto-tagging). `1`-`8` pick the
line; `[` `]`, Shift+wheel and pinch zoom the window; the panel's display filter applies
as usual. Edges are found on the display thread from the digital words of each block
(`src/sweeps.zig`). Sweeps older than the GPU's sample history (about 30 s) are dropped, so
with slow triggers fewer are overlaid. After a filter corner change, only the recent past
is refiltered, so older overlaid sweeps keep the old corners until they are replaced.

**Spike audio.** oEZ plays the channels you choose through the default sound device.
Click an electrode row on the display to listen to it; Ctrl+click adds or removes a
channel (up to 8, spread across the stereo field). The rows listened to have a bright
label. The control window's Audio section has on / off, mute, volume, shaped / plain,
and recalibrate, and shows the held noise level, the latency and any gaps.

The chain (`src/audio.zig`, carried over from oers) is built to keep what makes one
region sound unlike another, so nothing in it adapts continuously:

1. Band-limit 300 Hz to 7 kHz.
2. A gain taken from the noise, measured once for 3 s when channels are chosen (or on
   "recalibrate") and then held: the noise sigma becomes 0.02 of full scale. The estimate
   leaves spikes out, so dense firing does not change it.
3. A gentle downward expander keyed on that held sigma (floor 9 dB down by default, so
   multi-unit hash stays audible), with a 0.6 ms look-ahead.
4. +3 dB of presence around 2.8 kHz.
5. A safety limiter that is exactly linear below half of full scale.
6. A flat windowed-sinc resampler to the device's rate.

"plain" leaves out 3 and 4, for comparing by ear. Tests hold the chain to this: unit size
ratios kept, loudness independent of firing rate, hash not gated away, the limiter linear
where spikes are, the resampler flat to 10 kHz.

Sound runs on two threads of its own (`src/gui/audio_out.zig`) with their own reader on
the acquisition ring, so it does not depend on the display. On the board: about 16 ms as
reported, of which about 5 ms waits in oEZ's queue and about 10 ms is what the device
(PipeWire at a 128-frame quantum, and the sound card) says is still to be played; a few
gaps in the first seconds while the clock servo settles, then about one in 10 s.
The queue's margin adapts: a gap raises it by 1 ms, 30 s without one lowers it by 0.5 ms,
so latency settles at what the machine's timing needs. The once-a-second log line gives
the margin, the longest wait between blocks and the oldest block the feeder met, for
finding the cause when gaps do happen.
`--no-audio` or `audio = false` turns it off; `volume_db = -6` sets the starting volume.

**Slope trigger (spikes).** A triggered panel of electrodes can start its sweeps where one
of its own channels crosses a level, instead of at a TTL edge: `s` on the panel (with the
pointer over the row to listen to), the TTL / spikes buttons in the control window, or
`trigger_channel = 5` in the config. Clicking another row moves the trigger there.

- The channel is band-passed 300 Hz to 6 kHz for the detection, whatever the panel shows.
- The level follows the noise by default (4.5 sigma, sigma from the median of the
  absolute signal, so spikes hardly move it), or is fixed in µV (`level_uv`). A dashed
  line shows it on the trigger's row, in that row's scale; it sits on the trace when the
  panel shows a band near 300-6000 Hz.
- Falling (default) or rising slope; the sweep is aligned on the extreme within 0.5 ms
  after the crossing (the spike's trough or peak); 1 ms dead time plus an optional
  holdoff.
- The window is its own: -1 / +2 ms, kept apart from the TTL window (-10 / +40 ms).

After a very large spike the band-pass rings for a few ms and can trigger once more once
the dead time is over; a holdoff of a few ms stops that. Detection runs on the display
thread (`src/slope.zig`) and has nothing to do with what is recorded.

**Rows: filtered, as they are, or hidden.** Within one panel each row can be shown
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

**Common average reference (CAR).** Per electrode panel (so per port): the plain mean of
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

**TTL lanes and tint.** A panel with `source = "ttl"` shows the digital input lines as
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

**Display filter.** Each electrode panel can show its channels band-passed: a 4th-order
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

**Sweep mode.** By default traces scroll, with the newest sample at the right edge. In
sweep mode they stand still and a cursor moves left to right, overwriting the previous pass
(as oers and the stock LFP viewer draw). Set it per panel with `mode = "sweep"`, for all
panels with a top-level `mode = "sweep"` or `--sweep`, or flip the panel under the pointer
with `m`. It is the same drawing with a different choice of samples per column, so the
latency is the same. Kept simple: the time base is limited to 10 s, and changing it restarts
the pass from a new origin.

Each panel is titled with its name, time base and scale per row, and its rows are labelled
(the electrode's number on its headstage, AUXn, ADCn; thinned when rows are shorter than a
line of text). The bottom right corner shows the latency and frame rate of the last second,
and in amber how many blocks the display skipped, if any (the recording never depends on
the display). Text is drawn by oEZ itself (`src/gui/font.zig`: FreeType into one atlas,
quads in the same render pass), since nothing else may be on the monitor while tearing; it
made no measurable difference to the latency (2.6 ms with and without, same session).

**Control window.** A second, ordinary window (class `oez-control`) shows the run's
status (display latency, frame rate, blocks the display skipped, ring overflow) and, for
every panel, buttons for what the keys do: view (scroll / sweep / triggered), time base or
trigger window, scale, filter and its corners, trigger line and number of overlaid sweeps,
reset; and Quit. The wheel over a stepper steps it. `--no-control` or `control = false`
leaves it out.

It runs on its own thread with its own Wayland connection (`src/gui/control.zig`), and
shares no lock with the display: the display publishes a snapshot of its panels, the
control window queues edits, and the display applies them between frames as it does key
presses. So a slow or hidden control window cannot delay a trace, and closing it leaves the
display running. Both windows use one Vulkan instance (with two, NVIDIA's driver crashed
at exit). The control window must not open on the neural display's monitor, or tearing
stops; a Hyprland rule places it:

    hl.window_rule({ name = "oez-control", match = { class = "^oez-control$" },
                     workspace = "1", float = true, move = "966 51", size = "938 561" })

With it open on the board (tearing on DP-2): 2.4 to 2.5 ms, as without.

**Recording.** Record / Stop recording in the control window. Acquisition and the display
carry on throughout; each press of Record makes a new session (no restart of oEZ). While
recording, the control window shows the time, size, how far the disk is behind and any
gaps, and the neural display shows "REC" with the time beside its latency read-out. A
recording that fails (disk full, say) is shown as failed; acquisition is not affected and
what was written before stays valid. Quitting while recording closes the recording
properly first.

**Scroll-back review.** Look at what went by without stopping anything: acquisition, the
recording and the sound carry on, and the live display's own history keeps filling, so
going back to live is instant.

| key | |
|---|---|
| Space | freeze where the display is (again: back to live) |
| Left / Right | back and forth by a tenth of the window |
| PgUp / PgDn | by a whole window |
| Home | the start of the recording |
| End | back to live |

The control window's Review row has the same as buttons. While in review an amber badge
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

Limits for now: the window is as long as a live one (20 s at most; no overview of a whole
session yet); the newest second of TTL edges may not be in the file yet; the tint is not
drawn for stretches older than the last 512 pulses; after lost blocks (gaps in the
recording) later samples would be shown early by the length of the gap; no dragging with
the mouse yet.

**Notes.** On the neural display, `/` opens a note stamped at that moment; type, and
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
(`~/.local/state/oez/notes.log`: local time, sample, session folder, text); and onto the
traces as a line with the text beside it. The control window shows the last three, the
presets as buttons, and how many drafts wait. Notes are limited to 200 bytes; the display
font covers Latin-1, so other characters are stored as typed but drawn as "?".

Digits that have a preset no longer pick a triggered panel's TTL line (the control
window's stepper does that).

**Saving the view.** `config.toml` is the rig's setup, written by hand, and oEZ never
rewrites its panels. What you set in the control window or with keys and wheel (scale,
time base, mode, filter and corners, rows raw or hidden, per-row scales, CAR and its
rows, trigger settings, tint) is kept in a second file beside it, `views.toml`, written
by "Save view" in the control window (lit while there is something unsaved) and applied
on top of the config at launch. Panels are matched by name; a view for a panel that is
gone or has another number of rows is skipped. Delete `views.toml` to go back to the
config alone. Quitting with unsaved view changes asks, together with the board settings.

**Board settings.** They start from the config file's `[board]` table (command-line
options win over it):

```toml
[board]
sample_rate = 30000
lower_hz = 1.0             # amplifier bandwidth, set on the headstage chips
upper_hz = 7500
dsp = true                 # the chips' digital high-pass (offset removal)
dsp_cutoff_hz = 0.5
half_channels = "A1"       # RHD2132 headstages wired for 16 channels (comma separated)
aux = false
adc = true
leds = false
```

The control window's Headstages section changes them for the run:

- **Amplifier band and DSP high-pass** apply at once and without a gap, also while
  recording (the change and the sample where it took effect go into the recording's
  `events.tsv`). The window shows the values the chips really use.
- **Sample rate and half-channel mode** change the shape of the data, so they are chosen
  first and then applied together with "Apply (restarts acquisition)": acquisition stops,
  the board is reconfigured, and everything that depends on the channel count or rate is
  rebuilt (the display is blank for a moment and its history starts again). Not offered
  while recording.
- **Save as default** writes the settings in use into the config's `[board]` table (only
  that table is rewritten; the file is replaced by rename, so a config that is a symlink
  becomes a plain file).
- **On quitting** (q or Esc on the display, or Quit), if the settings differ from what the
  config gave at launch, the control window lists the differences and asks: save as
  default and quit, quit without saving, or cancel. A second q quits without saving.

Sessions go under `record_dir` (config; default `~/oez-recordings`):

    ~/oez-recordings/
      2026-11-12_14-03-22/        one session = one press of Record
        ephys/                    the recording (format below)
        video/                    by convention: what the camera recorder writes
      current -> 2026-11-12_14-03-22    link to the newest session

`current` is repointed (atomically) whenever a recording starts, so other programs can
write beside the ephys data without being told the folder's name:

    ./record.sh --out-root "$(realpath ~/oez-recordings/current)/video"

Start the oEZ recording first, so every camera trigger edge is in its TTL files.

**Latency** (sample arriving to its frame on screen, Hyprland 0.57.2, NVIDIA, 60 Hz):

| mode | latency |
|---|---|
| window, composited, drawn just before each refresh | 20.2 ms |
| fullscreen with tearing | 1.6 to 2 ms |

Tearing shows frames mid-scan, about every 3 ms, so every scan line is at most a few ms old.
Hyprland tears only when all of these hold (`hyprctl monitors` shows `activelyTearing` and
`tearingBlockedBy`):

- `general.allow_tearing = true`
- `cursor.no_hardware_cursors = 1` (no tearing while a hardware cursor is visible)
- the window is fullscreen and the only thing on that monitor: no popup, floating window,
  overlay or notification over it. So panels are laid out inside oEZ's one surface, and
  anything drawn on the neural display must be drawn by oEZ.

Other routes tried are described at the top of `src/gui/main.zig`: Hyprland's direct scanout
(3.5 ms but not dependable) and `--direct DP-2`, where oEZ drives the monitor with no
compositor (1.45 ms at a 1 ms margin from a text console; it needs the monitor to itself).

## Changing settings while acquiring

`Acquisition.applySettings` sorts a change (`acquisition.classify`):

- **Outputs and indicators** (LEDs, DAC routing and high-pass, TTL out and mode, noise slicer,
  fast TTL settle, clock divider): register writes applied by the acquisition thread between
  blocks. The data stream is untouched.
- **Amplifier bandwidth, DSP high-pass, fast settle:** gap-free. The idle AuxCmd3 bank pair
  (1/2 <-> 3/4) gets the new register-config list, then all four ports switch with one
  register write. Only the list entries that differ are written (a bandwidth change is 2-6
  writes, about 5 ms). Not done by stock or oers, which stop and restart.
- **Sample rate, AUX/ADC, 16-channel mode, cable delays, USB block size:** need a restart, and
  are refused while recording.

Each applied change goes into the recording's `events.tsv`, stamped with the estimated
sample at which it reached the board. The estimate is a lower bound: the effect shows in the
data within about 10 ms after it. `oez-headless --live-test --record DIR` runs a scheduled test
(refused restart, LEDs on/off, 300 Hz high-pass on/off, 1 kHz low-pass on/off).

## Recording format (v1)

One folder per recording, `ROOT/YYYY-MM-DD_HH-MM-SS/`. All binary files are little-endian and
append-only; `meta.toml` describes everything and is replaced atomically.

| file | contents |
|---|---|
| `samples.i16` | int16 `[n_samples][num_channels]`, raw as acquired; value × `bit_volts` = µV (electrodes) or V |
| `index.bin` | 48 B per ~100 ms chunk: `first_sample i64, n_samples u32, flags u32, byte_offset u64, wall_ns i64, board_clock u64, crc32 u32, pad u32` |
| `ttl_sample.i64` | sample number of each TTL-input change (first entry = initial state) |
| `ttl_word.u16` | the 8-line input word from that sample on (bit k = line k+1) |
| `events.tsv` | `sample<TAB>kind<TAB>text` |
| `meta.toml` | channels, scales, headstages, board, settings; `[final]` only after a clean stop |

Crash safety: once a second `samples.i16` is synced, then the index records for it are written
and synced, so every index record points at data already on disk. After a crash the indexed
data is CRC-verifiable and any tail beyond it is kept but unverified.

`tools/oez_compare.py A B` compares two recordings of the same headstages (layout, noise
profile, AUX and ADC levels). `tools/usbshim/usbshim.c` is the LD_PRELOAD logger used to learn
the FT600 protocol from D3XX.

`tools/oez_read.py` is a reference reader (numpy + standard library) and verifier:

    python3 tools/oez_read.py ~/oez-test/2026-11-11_11-53-24

Use explicit little-endian dtypes (`'<i2'`, `'<i8'`, `'<u2'`) in other readers.

## Hardware safety

Only volatile FPGA and Intan-chip registers are written (same sequence as oers and stock).
There are no flash, EEPROM or FTDI chip-configuration writes. Worst case: power-cycle the board.
The `usb` transport sends the FT600 only what D3XX sends on every open: GPIO requests (GPIO 0
is the board's FIFO reset), transfer announcements, aborts, and two read-only requests
(firmware version, chip configuration). The request that writes the chip configuration is not
implemented.
