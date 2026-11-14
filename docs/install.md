# Building dimna, reaching the board, and the headless tool

[Back to the README](../README.md)

## Build

Zig 0.17.1 (pinned in `build.zig.zon`).

    zig build --release=safe     # zig-out/bin/dimna-headless (safety checks stay on)
    zig build test               # unit tests: the core (src/root.zig) and the GUI (src/gui/tests.zig)

The GUI's tests cover its pure logic only (typed notes, the tile grid, the widget layout, the
control window's queue and snapshot); none opens a window, connects to Wayland, creates a
Vulkan instance or opens a sound device, so they pass without a display. A GUI file's tests
run only if the file is listed in `src/gui/tests.zig`.

The display also needs the development files of the Wayland client library, the Vulkan
loader, FreeType, fontconfig, xkbcommon and ALSA. It needs no wayland-protocols,
wayland-scanner or vulkan-headers package (the protocol XMLs and `vk.xml` are in `vendor/`;
`-Dvk-registry=<path>` substitutes another `vk.xml`), and no `glslc`: the compiled shaders
are checked in as `src/gui/shaders/*.spv`. Only someone who changes a shader needs `glslc`
(shaderc): when it is installed, a shader whose source is newer than its `.spv` is compiled
during the build and that result is embedded; `zig build shaders` rewrites the checked-in
`.spv` files, and `zig build test` fails while one differs from what glslc makes of its
source (skipped when glslc is absent). Commit the `.spv` with the source.

liboni is vendored (`vendor/liboni`, MIT) and built in. Two patches are carried in
`onidriverloader.c`: a driver search directory (from oers) and a driver compiled into the
program (`oni_register_builtin_driver`).

## Two ways to reach the FT600

    dimna-headless ...                # --driver usb, the default: no FTDI code in the process
    dimna-headless --driver d3xx ...  # fallback: liboni's ft600 driver on FTDI's closed D3XX

**`usb`** needs nothing installed beyond read/write access to the device node (the Open Ephys
udev rule). Three layers, all in this repo:

- `src/usbfs.zig`: USB through the kernel's usbdevfs, in Zig, without libusb. Bulk transfers
  are asynchronous URBs, so a read that times out still reports the bytes that arrived.
- `src/ft600.zig`: the FT600 wire protocol (documented at the top of the file). It was learned
  by logging the usbdevfs requests D3XX 1.0.14 makes for the ONI driver's calls on this board.
  Nothing is sent that D3XX does not send on every open, and the chip configuration is only
  ever read.
- `src/oni_usb.zig`: a port of liboni's `drivers/ft600/onidriver_ft600.c` onto that.

`DIMNA_USB_TRACE=1` logs every command and control-channel transfer to stderr.

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
  block should have been produced and fetches it in one transfer. `DIMNA_USB_PACE=0` turns that
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
sample reached the ring; `dimna-headless` prints it.) The FT600's stream mode was also tried and
is not used: see the notes at the top of `src/ft600.zig`.

**`d3xx`** needs `libonidriver_ft600.so`, built by `../oers/scripts/build-ft600-driver.sh`
(D3XX **1.0.x** only) into `~/.local/lib`. It is found via `$ONI_DRIVER_PATH`, next to the
executable, `../lib`, `~/.local/lib` or `/usr/local/lib`.

## Run

    dimna-headless --seconds 600 --16ch A1 --aux --adc --record ~/oez-test

`--16ch A1` is needed on the rig (16-channel headstage on an RHD2132). Prints one status line
per second and `CLEAN` at the end if nothing was lost (exit status 0). Record to disk, not
`/tmp`.

The acquisition thread runs SCHED_FIFO (needs rtprio, e.g. the `realtime` group) and locks
memory. It never waits on readers: the recorder and other readers take blocks from a
preallocated ring (30 s when recording).
