# Hardware: what is written to the board, and changing settings while acquiring

[Back to the README](../README.md)

## Hardware safety

Only volatile FPGA and Intan-chip registers are written (same sequence as oers and stock).
There are no flash, EEPROM or FTDI chip-configuration writes. Worst case: power-cycle the board.
The `usb` transport sends the FT600 only what D3XX sends on every open: GPIO requests (GPIO 0
is the board's FIFO reset), transfer announcements, aborts, and two read-only requests
(firmware version, chip configuration). The request that writes the chip configuration is not
implemented. `src/ft600.zig` enforces this: every control transfer goes through one function
that refuses any request outside a fixed list (in particular 0x40 0xcf) before it reaches the
kernel, and its tests fail if the list or that rule is broken.

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
data within about 10 ms after it. `dimna-headless --live-test --record DIR` runs a scheduled test
(refused restart, LEDs on/off, 300 Hz high-pass on/off, 1 kHz low-pass on/off).
