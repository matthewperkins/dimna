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
mode = "scroll"               # optional: "scroll" (default) or "sweep"

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
