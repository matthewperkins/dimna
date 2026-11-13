#!/usr/bin/env python3
"""Low- and high-frequency signal per headstage in oEZ recordings.

    python3 -I tools/band_power.py RECORDING [RECORDING ...]

For each recording it prints, per headstage, the median over its electrodes of the rms in
2-100 Hz and in 1-5 kHz (µV), from seconds 3 to 13 of the recording. It was written to
see whether an amplifier band setting took effect: a 300 Hz lower corner takes most of
the 2-100 Hz content away (mains pickup above all), a 1 Hz or 0.1 Hz corner leaves it.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from oez_read import Recording  # noqa: E402


def main(paths):
    for path in paths:
        r = Recording(path)
        fs = r.sample_rate
        names = r.channel_names
        x = np.asarray(r.samples[int(3 * fs):int(13 * fs)], dtype=np.float64)
        if x.shape[0] < fs:
            print(f"{path}: too short (needs 13 s)")
            continue
        x -= x.mean(axis=0)
        f = np.fft.rfftfreq(x.shape[0], 1 / fs)
        p = np.abs(np.fft.rfft(x, axis=0)) ** 2

        def band(lo, hi):
            m = (f >= lo) & (f < hi)
            return np.sqrt(p[m].sum(axis=0)) / x.shape[0] * np.sqrt(2) * 0.195

        low, high = band(2, 100), band(1000, 5000)
        print(Path(path).resolve().name)
        groups = {}
        for i, name in enumerate(names):
            if "-" in name:  # electrodes are named "A1-5"
                groups.setdefault(name.split("-")[0], []).append(i)
        for hs, idx in groups.items():
            print(f"  {hs}: 2-100 Hz rms median {np.median(low[idx]):9.2f} uV   "
                  f"1-5 kHz rms median {np.median(high[idx]):6.2f} uV")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
