#!/usr/bin/env python3
"""Compare two dimna recordings of the same headstages made at different times.

The samples cannot be equal (different moments), so this compares what should be: layout and
scales, per-channel noise profile of the electrodes, and AUX / ADC levels.

    python3 dimna_compare.py RECORDING_A RECORDING_B
"""
import sys

import numpy as np

from dimna_read import Recording


def profile(r, seconds=10.0):
    n = min(r.verified_rows, int(seconds * r.sample_rate))
    x = r.samples[:n].astype(np.float64) * r.bit_volts
    return x.mean(axis=0), x.std(axis=0)


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    a, b = Recording(argv[1]), Recording(argv[2])
    ok = True
    for r in (a, b):
        problems, tail = r.verify()
        print(f"{r.path.name}: {r.verified_rows} samples, {r.index.size} chunks, "
              f"gaps {int(np.count_nonzero(r.index['flags'] & 1))}, "
              f"{'verified OK' if not problems else problems}")
        ok &= not problems
    same_layout = (a.channel_names == b.channel_names and a.kind == b.kind
                   and np.array_equal(a.bit_volts, b.bit_volts) and a.sample_rate == b.sample_rate)
    print("layout and scales equal:", same_layout)
    if not same_layout:
        return 1
    ma, sa = profile(a)
    mb, sb = profile(b)
    kind = np.array(a.kind)
    el = kind == "electrode"
    if el.any():
        r_lin = np.corrcoef(sa[el], sb[el])[0, 1]
        r_log = np.corrcoef(np.log(sa[el]), np.log(sb[el]))[0, 1]
        ratio = sa[el] / sb[el]
        print(f"electrode noise profile: r = {r_lin:.4f} (log {r_log:.4f}); SD ratio A/B median "
              f"{np.median(ratio):.3f}, range {ratio.min():.3f}..{ratio.max():.3f}")
        ok &= r_log > 0.95
    for k in ("aux", "adc"):
        m = kind == k
        if m.any():
            d = np.abs(ma[m] - mb[m]).max()
            print(f"{k.upper()} mean (V) A: {np.round(ma[m], 4)}")
            print(f"{k.upper()} mean (V) B: {np.round(mb[m], 4)}   largest difference {d * 1e3:.2f} mV")
            ok &= d < 0.01
    print("MATCH" if ok else "DIFFERENT")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
