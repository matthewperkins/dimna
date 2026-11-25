#!/usr/bin/env python3
"""Reference reader for dimna recordings (format v1). Needs only numpy and the standard library.

    from dimna_read import Recording
    r = Recording("~/oez-test/2026-11-11_11-49-54")
    uv = r.samples[:, :32] * r.bit_volts[:32]      # electrodes in µV (memory-mapped)

Run as a script to verify a recording: every index record's CRC against samples.i16, chunk
contiguity, file sizes, TTL edges, and the [final] counts (of settings changes too, against
events.tsv). It warns when settings changed during the recording: [settings] in meta.toml
holds the values at the start, and each change is a line of events.tsv. It says when the
recording continues another after a restart on a read error ([start] continues), and why it
was stopped when that was not the user's request ([final] reason).

    python3 dimna_read.py RECORDING_DIR
"""
import sys
import tomllib
import zlib
from pathlib import Path

import numpy as np

INDEX_DTYPE = np.dtype([
    ("first_sample", "<i8"), ("n_samples", "<u4"), ("flags", "<u4"), ("byte_offset", "<u8"),
    ("wall_ns", "<i8"), ("board_clock", "<u8"), ("crc32", "<u4"), ("pad", "<u4"),
])
FLAG_GAP = 1
# The format's name; recordings made before the program was renamed from oez say "oez-recording".
FORMAT_NAMES = ("dimna-recording", "oez-recording")
# events.tsv kinds that change a value of [settings] during the recording, and the [final]
# key that counts each (the keys are absent in recordings made before they were added).
SETTINGS_EVENTS = {
    "amplifier": "amplifier_events",
    "amplifier_failed": "amplifier_failed_events",
    "leds": "leds_events",
}


class Recording:
    def __init__(self, path):
        self.path = Path(path).expanduser()
        with open(self.path / "meta.toml", "rb") as f:
            self.meta = tomllib.load(f)
        m = self.meta
        if m.get("format") not in FORMAT_NAMES or m.get("format_version") != 1:
            raise ValueError(f"not a dimna v1 recording: {self.path}")
        if m.get("byte_order") != "little":
            raise ValueError("unsupported byte order")
        self.num_channels = m["num_channels"]
        self.sample_rate = m["sample_rate"]
        ch = m["channels"]
        self.channel_names = ch["name"]
        self.kind = ch["kind"]
        self.units = ch["units"]
        self.bit_volts = np.asarray(ch["bit_volts"], dtype=np.float64)
        self.index = np.fromfile(self.path / "index.bin", dtype=INDEX_DTYPE)
        raw = np.memmap(self.path / "samples.i16", dtype="<i2", mode="r")
        self.total_rows = raw.size // self.num_channels
        # Rows covered by the index are verified-able; anything after is an unverified tail.
        self.verified_rows = int(self.index["n_samples"].sum()) if self.index.size else 0
        self.samples = raw[: self.verified_rows * self.num_channels].reshape(-1, self.num_channels)
        self.ttl_sample = np.fromfile(self.path / "ttl_sample.i64", dtype="<i8")
        self.ttl_word = np.fromfile(self.path / "ttl_word.u16", dtype="<u2")
        n = min(self.ttl_sample.size, self.ttl_word.size)
        self.ttl_sample, self.ttl_word = self.ttl_sample[:n], self.ttl_word[:n]
        self.first_sample = m.get("start", {}).get("first_sample",
                                                   int(self.index["first_sample"][0]) if self.index.size else 0)
        self.complete = "final" in m
        self.events = read_events(self.path / "events.tsv")
        # The events.tsv lines after which [settings] no longer holds: (sample, kind, text).
        self.settings_changes = [e for e in self.events if e[1] in SETTINGS_EVENTS]

    def sample_numbers(self):
        """Board sample number of every verified row (handles gaps via the index)."""
        out = np.empty(self.verified_rows, dtype=np.int64)
        row = 0
        for rec in self.index:
            n = int(rec["n_samples"])
            out[row:row + n] = rec["first_sample"] + np.arange(n)
            row += n
        return out

    def ttl_line(self, line):
        """(sample, level) at each change of TTL input `line` (1..8)."""
        bit = (self.ttl_word >> (line - 1)) & 1
        keep = np.r_[True, bit[1:] != bit[:-1]]
        return self.ttl_sample[keep], bit[keep]

    def verify(self):
        problems = []
        nch = self.num_channels
        expected_offset = 0
        prev_end = None
        raw = np.memmap(self.path / "samples.i16", dtype=np.uint8, mode="r")
        for k, rec in enumerate(self.index):
            n, off = int(rec["n_samples"]), int(rec["byte_offset"])
            if off != expected_offset:
                problems.append(f"chunk {k}: byte_offset {off} != {expected_offset}")
            nbytes = n * nch * 2
            if zlib.crc32(raw[off:off + nbytes]) != int(rec["crc32"]):
                problems.append(f"chunk {k}: CRC mismatch")
            gap = prev_end is not None and int(rec["first_sample"]) != prev_end
            if gap != bool(rec["flags"] & FLAG_GAP):
                problems.append(f"chunk {k}: gap flag {bool(rec['flags'] & FLAG_GAP)} but gap={gap}")
            prev_end = int(rec["first_sample"]) + n
            expected_offset = off + nbytes
        tail = raw.size - expected_offset
        if self.ttl_sample.size and np.any(np.diff(self.ttl_sample) <= 0):
            problems.append("TTL edge samples not strictly increasing")
        if self.complete:
            f = self.meta["final"]
            if f["samples"] != self.verified_rows:
                problems.append(f"[final] samples {f['samples']} != indexed {self.verified_rows}")
            if f["chunks"] != self.index.size:
                problems.append(f"[final] chunks {f['chunks']} != {self.index.size}")
            if tail:
                problems.append(f"{tail} bytes past the last index record in a complete recording")
            if "settings_changed" in f:
                for kind, key in SETTINGS_EVENTS.items():
                    n = sum(1 for e in self.settings_changes if e[1] == kind)
                    if f.get(key) != n:
                        problems.append(f"[final] {key} {f.get(key)} != {n} '{kind}' lines in events.tsv")
                if f["settings_changed"] != bool(self.settings_changes):
                    problems.append(f"[final] settings_changed {f['settings_changed']} but "
                                    f"{len(self.settings_changes)} change(s) in events.tsv")
        return problems, tail


def read_events(path):
    """events.tsv as a list of (sample, kind, text); [] if the file is missing."""
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        return []
    out = []
    for line in lines[1:]:
        f = line.split("\t", 2)
        if len(f) >= 2:
            out.append((int(f[0]), f[1], f[2] if len(f) > 2 else ""))
    return out


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    r = Recording(argv[1])
    problems, tail = r.verify()
    secs = r.verified_rows / r.sample_rate
    print(f"{r.path}")
    print(f"  {r.num_channels} channels at {r.sample_rate:g} Hz, {r.verified_rows} samples ({secs:.3f} s) "
          f"in {r.index.size} chunks, first sample {r.first_sample}, "
          f"{'complete' if r.complete else 'INTERRUPTED (no [final])'}")
    gaps = int(np.count_nonzero(r.index["flags"] & FLAG_GAP))
    print(f"  gaps: {gaps}, TTL edges: {r.ttl_sample.size}, unverified tail: {tail} bytes")
    if r.index.size > 1:
        dclk = np.diff(r.index["board_clock"].astype(np.int64)) / np.diff(r.index["first_sample"])
        print(f"  board clock per sample: {dclk.mean():.4f} ticks "
              f"(nominal {r.meta['board_clock_hz'] / r.sample_rate:.4f})")
    el = [i for i, k in enumerate(r.kind) if k == "electrode"]
    if el and r.verified_rows:
        x = r.samples[: min(r.verified_rows, int(10 * r.sample_rate)), el].astype(np.float64) * r.bit_volts[el]
        x -= x.mean(axis=0)
        sd = x.std(axis=0)
        print(f"  electrode SD over the first {x.shape[0] / r.sample_rate:.1f} s (uV): "
              f"min {sd.min():.2f}, median {np.median(sd):.2f}, max {sd.max():.2f}")
    start = r.meta.get("start", {})
    if "continues" in start:
        gap = start.get("gap_estimate_s")
        print(f"  continues {start['continues']} (which ends at its sample {start.get('continues_end_sample', '?')}) "
              f"after acquisition was restarted on a read error; "
              f"{'about %.3f s' % gap if gap is not None else 'an unknown time'} not acquired between them "
              f"(host clock estimate); this recording numbers its samples from 0 again")
    reason = r.meta.get("final", {}).get("reason")
    if reason:
        print(f"  stopped: {reason}")
    if r.settings_changes:
        print(f"  WARNING: settings changed during the recording ({len(r.settings_changes)} change(s) in "
              f"events.tsv); [settings] holds the values at the start only:")
        for sample, kind, text in r.settings_changes[:10]:
            print(f"    sample {sample}: {kind} {text}")
        if len(r.settings_changes) > 10:
            print(f"    ... and {len(r.settings_changes) - 10} more")
    for p in problems:
        print("  PROBLEM:", p)
    print("  OK" if not problems else f"  {len(problems)} problem(s)")
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
