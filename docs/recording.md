# Recordings: where they go, the format, and how the recorder is tested

[Back to the README](../README.md)

## Sessions

Sessions go under `record_dir` (config; default `~/dimna-recordings`):

    ~/dimna-recordings/
      2026-11-12_14-03-22/        one session = one press of Record
        ephys/                    the recording (format below)
        video/                    by convention: what the camera recorder writes
      current -> 2026-11-12_14-03-22    link to the newest session

`current` is repointed (atomically) whenever a recording starts, so other programs can
write beside the ephys data without being told the folder's name:

    ./record.sh --out-root "$(realpath ~/dimna-recordings/current)/video"

Start the dimna recording first, so every camera trigger edge is in its TTL files.

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

`meta.toml` names the format `format = "dimna-recording"`, `format_version = 1`. Recordings
made before the program was renamed from oEZ say `oez-recording`, in the same version 1;
`tools/dimna_read.py` reads both.

Crash safety: once a second `samples.i16` is synced, then the index records for it are written
and synced, so every index record points at data already on disk. After a crash the indexed
data is CRC-verifiable and any tail beyond it is kept but unverified.

`tools/dimna_compare.py A B` compares two recordings of the same headstages (layout, noise
profile, AUX and ADC levels). `tools/usbshim/usbshim.c` is the LD_PRELOAD logger used to learn
the FT600 protocol from D3XX.

`tools/dimna_read.py` is a reference reader (numpy + standard library) and verifier:

    python3 tools/dimna_read.py ~/oez-test/2026-11-11_11-53-24

Use explicit little-endian dtypes (`'<i2'`, `'<i8'`, `'<u2'`) in other readers.

Display features (filters, reference, hidden rows, spike detection, slope trigger, audio) never
change what is recorded. `src/independence_test.zig` (in `zig build test`) records one
deterministic stream with and without all of them running beside the recorder and checks that
both recordings are byte for byte what was generated. `tools/display-independence-test.sh` does
the same through the GUI on the simulator; it opens windows, so never run it during an experiment.

### Testing the recorder

`zig build test` includes `src/record_test.zig`: a producer thread feeds the ring blocks whose
every value is a function of (sample number, channel), and each recording is read back and
checked (every sample, every TTL change, index offsets, CRCs and gap flags, `events.tsv`,
`[final]`). It covers a whole stream, attaching to a running stream, stopping while the
producer carries on (and the ring being let go), lost blocks, an injected write failure, and
events from both queues. `tools/crash-test.sh [SECONDS]` records from the simulator, kills
`dimna-headless` with `kill -9` after that many seconds, and checks with `dimna_read.py` that the
indexed part verifies, that the recording is marked interrupted, and that the unverified tail
is under 1.5 s. Neither touches the board. The crash test kills the process only (the page
cache survives), so it says nothing about power loss or a full disk.
