# oEZ

Acquisition for the Open Ephys acquisition board (ECP5 gateware, FT600 USB 3, ONI), in Zig.
Linux only. Successor to oers (Rust, `../oers`), whose driver it ports.

## Build

Zig 0.17.1 (pinned in `build.zig.zon`).

    zig build --release=safe     # zig-out/bin/oez-headless (safety checks stay on)
    zig build test               # unit tests

liboni is vendored (`vendor/liboni`, MIT) and built in. The FT600 driver
`libonidriver_ft600.so` is still FTDI's D3XX-based one, built by
`../oers/scripts/build-ft600-driver.sh` (D3XX **1.0.x** only) into `~/.local/lib`. It is found
via `$ONI_DRIVER_PATH`, next to the executable, `../lib`, `~/.local/lib` or `/usr/local/lib`.

## Run

    oez-headless --seconds 600 --16ch A1 --aux --adc --record ~/oez-test

`--16ch A1` is needed on the rig (16-channel headstage on an RHD2132). Prints one status line
per second and `CLEAN` at the end if nothing was lost (exit status 0). Record to disk, not
`/tmp`.

The acquisition thread runs SCHED_FIFO (needs rtprio, e.g. the `realtime` group) and locks
memory. It never waits on readers: the recorder and other readers take blocks from a
preallocated ring (30 s when recording).

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

`tools/oez_read.py` is a reference reader (numpy + standard library) and verifier:

    python3 tools/oez_read.py ~/oez-test/2026-11-11_11-53-24

Use explicit little-endian dtypes (`'<i2'`, `'<i8'`, `'<u2'`) in other readers.

## Hardware safety

Only volatile FPGA and Intan-chip registers are written (same sequence as oers and stock).
There are no flash, EEPROM or FTDI chip-configuration writes. Worst case: power-cycle the board.
