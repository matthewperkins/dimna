# Spike tiles, thresholds and spike audio

[Back to the README](../README.md)

## Spike tiles

A third window (class `dimna-tiles`) with one tile per electrode: the
channel's last spike waveforms on top of each other (the newest brightest), its threshold
as a red line, its noise sigma in µV and its firing rate.

*Focus and listening* are two things, in this window and on the display alike. Focus (one
channel, or none) is the channel being looked at: its tile has an amber frame and its row
on the display an amber label. Listening is marked by a note (♪) before the name.

| on a tile, or on an electrode row of the display | |
|---|---|
| left click | focus that channel |
| right click | listen to it; with Ctrl, add it to or take it out of what is listened to |
| middle click (anywhere) | no focus |

The focused channel's detection threshold is drawn on its trace on the display as a thin
red line, in that row's own scale, so the threshold can be read against the signal. It is
drawn only where the row shows about the detector's band (the row goes through the
panel's filter, with corners within 250 to 350 Hz and 5 to 7 kHz); elsewhere the row's
label says "thr" instead, because a line would not sit on what is shown. A threshold that
follows the noise is known from the tile window's detector, so with `--no-tiles` only a
fixed one is drawn.

*The tiles' vertical scale.* A tile's range is the µV from zero to its edge. At first every
tile scales itself to its own waveforms. In the tile window:

| | |
|---|---|
| wheel | all tiles shown, 5 % of the range per click. The first movement puts them on one common range, the largest of their own |
| Ctrl+wheel | the tile under the pointer alone |
| `r` | back to that first common range |
| `a` | each tile to its own waveforms, as fixed ranges |
| `u`, Shift+`u` | step back and forward through the last 16 states of all the ranges (a wheel movement counts once it has rested for 0.75 s) |

A tile with a fixed range shows it bottom left where there is room; the strip along the
bottom shows the common range, "auto" or "mixed", and chips for the ports that have a
headstage and for all of them: the tiles shown are the chosen port's (detection goes on
for every channel). The wheel, `r` and `a` act on the tiles shown. The ranges and the port
are saved by "Save view", in a `[tiles]` table of `views.toml`.

*Thresholds.* Each electrode has one detection threshold, used by its tile and by any
slope trigger on it alike (`src/thresholds.zig`). It either follows the noise, a number of
sigmas below zero that is the same for every channel (4 to 6 in halves, 4.5 at first: the
control window's "spike threshold" row), or is fixed in µV, its sign the slope: negative
is crossed falling and aligned on the trough, positive rising and aligned on the peak. The
display owns the thresholds and tells the tile window; "Save view" keeps them, in a
`[thresholds]` table of `views.toml` (`sigmas = 4.5`, `fixed_uv = [...]` per electrode,
0 = follows the noise).

A threshold is set by hand where it is drawn. On the display: the pointer becomes a hand
within 4 px of a threshold line (the focused row's, or a triggered panel's dashed one),
and dragging the line sets that channel's threshold to the µV under the pointer; across
the row's centre it changes sign. In the tile window: drag a tile's red line the same way,
or Ctrl+Shift+wheel over a tile for 5 % a click; a tile with a fixed threshold shows its
value beside sigma. In both windows `n` switches the channel under the pointer between
following the noise and fixed at its present value. A dragged threshold stops at ±5 µV
(0 means "follows the noise") and at ±5 mV.

Detection (`src/spikes.zig`) is the slope trigger's, for every electrode at once: 300 Hz
to 6 kHz, each channel's threshold with sigma from a running median (spikes hardly move
it), each crossing aligned on the extreme that follows, 1 ms dead time. It takes the
panels' common average references. A large spike can make the band-pass ring
across the threshold once more; such small waveforms are kept too. The tile window is a
thread of its own with its own reader on the acquisition ring (`src/gui/tiles.zig`), so
it never holds the display or acquisition back. `--no-tiles` or `tiles = false` leaves it
out. A Hyprland rule keeps it off the neural display's monitor:

    hl.window_rule({ name = "dimna-tiles", match = { class = "^dimna-tiles$" },
                     workspace = "1", float = true, move = "966 624", size = "938 560" })

## Spike audio

dimna plays the channels you choose through ALSA's default sound device, or through a JACK
server (below, "Where the sound goes").
Right-click an electrode row on the display, or a spike tile, to listen to it; Ctrl+right
click adds or removes a channel (up to 8, spread across the stereo field). The channels
listened to have a note (♪) before their label. The control window's Audio section has on / off, mute, volume, shaped / plain,
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

Sound runs on threads of its own (`src/gui/audio_out.zig`) with their own reader on the
acquisition ring, so it does not depend on the display. On the board, through ALSA: about
16 ms as reported, of which about 5 ms waits in dimna's queue and about 10 ms is what the
device (PipeWire at a 128-frame quantum, and the sound card) says is still to be played; a
few gaps in the first seconds while the clock servo settles, then about one in 10 s.
The queue's margin adapts: a gap raises it by 1 ms, 30 s without one lowers it by 0.5 ms,
so latency settles at what the machine's timing needs. The once-a-second log line gives
the margin, the longest wait between blocks and the oldest block the feeder met, for
finding the cause when gaps do happen.
`--no-audio` or `audio = false` turns it off; `volume_db = -6` sets the starting volume.

### Where the sound goes

`audio_output` in the config (or `--audio-output`):

| value | |
|---|---|
| `"alsa"` (the default) | ALSA's `default` device, on a thread of dimna's that writes one 128-frame period at a time (`src/gui/audio_alsa.zig`). On most desktops `default` is PipeWire. |
| `"jack"` | a running JACK server, as the client `dimna` (`src/gui/audio_jack.zig`). Without one there is no sound, and a warning in the log says why: dimna never starts a server, and does not fall back to ALSA. |
| `"auto"` | JACK if a server answers, else ALSA. |

The start-up line in the log says which was taken (`audio output: ALSA, ...` or
`audio output: JACK (client dimna), ...`, with the server's rate, period, playback latency
and the real-time priority of the client's thread).

ALSA is the default because on most distributions the JACK library is PipeWire's own
(`pipewire-jack`): a JACK client there joins PipeWire's graph with the same quantum as
ALSA's `default`, so it gains nothing. JACK lowers latency when real JACK (`jackd`, JACK2)
runs the sound card itself, with PipeWire stopped: that is what the user unit
`packaging/dimna-jack.service` does, started and stopped around dimna by its launchers
(docs/install.md, "Spike audio through JACK").

With JACK, dimna's ports `dimna:left` and `dimna:right` are connected to the first two
physical playback ports. The server's real-time thread asks for each period through a
callback, which takes the frames from the same queue the ALSA thread does (one function,
`AudioOut.render`, makes the frames for both). The server's rate is the queue's rate; its
buffer size is what the feeder keeps room for, and a change of it while running is
followed. xruns the server reports (any client's) are counted and shown at the end of the
once-a-second audio line (`xruns 0` with ALSA). If the server goes away the monitor goes
silent; dimna does not reconnect: restart dimna (or its acquisition) once a server runs
again.

**What "device" means in the latency read-out.** With ALSA it is `snd_pcm_delay`: what
ALSA (here PipeWire and the card) says is still to be played. With JACK it is the playback
latency JACK reports for dimna's ports (`jack_port_get_latency_range`, the larger of the
two): the buffering between dimna's ports and the card as the server and its ALSA driver
count it: with JACK's dummy driver at 64 frames, 128 frames (2.7 ms at 48 kHz); with its
ALSA driver, the card's buffer less the period being written, plus the one period JACK's
asynchronous mode adds, so about the same for `-p 64 -n 2` (not yet measured on the card). It cannot
include what JACK does not know: the card's own converter (its digital filter's delay) and
the analogue path after it, unless the server is told with `-O`. dimna's queue is counted
separately ("queue"), as with ALSA.
